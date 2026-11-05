#!/usr/bin/env python3
"""Tiny NAS status page: one process, no dependencies. Serves / (HTML), /api (JSON) and /api/history on port 80.
Fast sampler: /proc and /sys every 5 s (10 min in RAM). Slow sampler: once a minute (disk power state, chrony,
systemd, ext4/md counters, kernel warnings) + one row appended to a 7-day history file. SMART every 10 min."""
import json, os, re, socket, subprocess, threading, time
from collections import deque
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

DISK, NET, ROOT, DATA = "sda", "eth0", "/", "/srv/data"
STATE_DIR = "/srv/data/.nas-status"
STEP, HIST, SLOW_EVERY, SMART_EVERY, KEEP_DAYS = 5, 120, 60, 600, 7
PORT = int(os.environ.get("PORT", "80"))
NFS4_OPS = {3: "ACCESS", 4: "CLOSE", 5: "COMMIT", 6: "CREATE", 9: "GETATTR", 11: "LINK", 15: "LOOKUP", 22: "OPEN", 25: "READ",
            26: "READDIR", 28: "REMOVE", 29: "RENAME", 34: "SETATTR", 38: "WRITE"}
HIST_FIELDS = ["t", "temp", "data_pct", "cpu", "wr", "rd", "rx", "tx", "nfs_w", "nfs_r"]

def read(p):
    try:
        with open(p) as f: return f.read()
    except OSError: return ""

def sh(cmd, timeout=20):
    try: return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception: return ""

# ---------- fast counters ----------
def cpu_times():
    v = [int(x) for x in read("/proc/stat").split("\n")[0].split()[1:]]
    return sum(v), v[3] + v[4], v[6]

def disk_counters():
    for l in read("/proc/diskstats").splitlines():
        f = l.split()
        if len(f) > 12 and f[2] == DISK:
            return int(f[5]) * 512, int(f[9]) * 512, int(f[12])
    return 0, 0, 0

def net_counters():
    b = "/sys/class/net/%s/statistics/" % NET
    g = lambda n: int(read(b + n).strip() or 0)
    return {k: g(k) for k in ("rx_bytes", "tx_bytes", "rx_packets", "tx_packets", "rx_errors", "tx_errors", "rx_dropped", "tx_dropped")}

def nfsd_counters():
    io, ops = (0, 0), {}
    for l in read("/proc/net/rpc/nfsd").splitlines():
        f = l.split()
        if f and f[0] == "io": io = (int(f[1]), int(f[2]))
        elif f and f[0] == "proc4ops":
            for n, name in NFS4_OPS.items():
                if n + 2 < len(f): ops[name] = int(f[n + 2])
    return io, ops

def proc_cpu():
    out = {}
    for d in os.listdir("/proc"):
        if not d.isdigit(): continue
        s = read("/proc/%s/stat" % d)
        if not s: continue
        try:
            comm = s[s.index("(") + 1:s.rindex(")")]; f = s[s.rindex(")") + 2:].split()
            out[int(d)] = (comm, int(f[11]) + int(f[12]))
        except (ValueError, IndexError): pass
    return out

# ---------- slow readers ----------
def df(path):
    try:
        s = os.statvfs(path); tot = s.f_blocks * s.f_frsize; used = tot - s.f_bfree * s.f_frsize
        return {"total": tot, "used": used, "free": s.f_bavail * s.f_frsize, "pct": round(100 * used / tot, 1) if tot else 0,
                "inodes_used": s.f_files - s.f_ffree, "inodes_total": s.f_files}
    except OSError: return None

def mdstat():
    out = {}
    lines = read("/proc/mdstat").splitlines()
    for i, l in enumerate(lines):
        m = re.match(r"^(md\d+)\s*:\s*(\S+)\s+(\S+)\s+(.*)", l)
        if m:
            nxt = " ".join(lines[i + 1:i + 3])
            st = re.search(r"\[([U_]+)\]", nxt); rec = re.search(r"(resync|recovery|check)\s*=\s*([\d.]+%)", nxt)
            md = "/sys/block/%s/md/" % m.group(1)
            out[m.group(1)] = {"state": m.group(2), "level": m.group(3), "members": m.group(4), "disks": st.group(1) if st else "?",
                               "sync": rec.group(1) + " " + rec.group(2) if rec else None,
                               "mismatch_cnt": int(read(md + "mismatch_cnt").strip() or 0), "sync_action": read(md + "sync_action").strip(),
                               "last_sync_action": read(md + "last_sync_action").strip()}
    return out

SMART_KEYS = {"5", "9", "12", "193", "194", "196", "197", "198", "199", "4"}
def smart():
    out = sh(["smartctl", "-H", "-A", "-i", "-l", "selftest", "/dev/" + DISK], 40)
    if not out: return {"error": "smartctl failed"}
    r = {"health": "PASSED" if "PASSED" in out else ("FAILED" if "FAILED" in out else "unknown"), "attrs": {}, "selftest": None}
    for k in ("Device Model", "Serial Number", "User Capacity", "Firmware Version"):
        m = re.search(r"^%s:\s*(.*)$" % re.escape(k), out, re.M)
        if m: r[k] = m.group(1).strip()
    for l in out.splitlines():
        m = re.match(r"^\s*(\d+)\s+(\S+)\s+0x[0-9a-f]+\s+(\d+)\s+(\d+)\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(\d+)", l)
        if m and m.group(1) in SMART_KEYS:
            r["attrs"][m.group(2)] = {"value": int(m.group(3)), "worst": int(m.group(4)), "thresh": int(m.group(5)), "raw": int(m.group(6))}
        m = re.match(r"^# 1\s+(.+?)\s{2,}(.+?)\s{2,}(\d+%)\s+(\d+)", l)
        if m and r["selftest"] is None:
            r["selftest"] = {"type": m.group(1).strip(), "status": m.group(2).strip(), "hours": int(m.group(4))}
    if "No self-tests have been logged" in out: r["selftest"] = {"type": "none", "status": "no self-tests logged", "hours": None}
    t = r["attrs"].get("Temperature_Celsius"); r["temp"] = t["raw"] if t else None
    return r

def disk_temp():
    """Temperature only (attribute 194), cheap enough to run every minute; the full SMART read stays at 10 min."""
    m = re.search(r"^\s*194\s+Temperature_Celsius\s+0x[0-9a-f]+\s+\d+\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+\s+(\d+)", sh(["smartctl", "-A", "/dev/" + DISK], 20), re.M)
    return int(m.group(1)) if m else None

def disk_power():
    m = re.search(r"drive state is:\s*(\S+)", sh(["hdparm", "-C", "/dev/" + DISK], 10))
    return m.group(1) if m else "unknown"

def chrony():
    out = sh(["chronyc", "tracking"], 10); r = {"synced": False, "offset": None, "source": None}
    m = re.search(r"System time\s*:\s*([\d.]+) seconds (fast|slow)", out)
    if m: r["offset"] = round(float(m.group(1)) * (1 if m.group(2) == "fast" else -1), 4)
    m = re.search(r"Reference ID\s*:\s*\S+\s*\((.*?)\)", out)
    if m: r["source"] = m.group(1)
    m = re.search(r"Leap status\s*:\s*(.*)", out)
    r["synced"] = bool(m) and m.group(1).strip() == "Normal"
    return r

def failed_units():
    return [l.split()[0] for l in sh(["systemctl", "--failed", "--plain", "--no-legend"], 10).splitlines() if l.strip()]

def kernel_warnings():
    out = sh(["journalctl", "-k", "-b", "-p", "warning", "-n", "8", "-o", "short-iso", "--no-pager", "-q"], 15)
    return [l[:160] for l in out.splitlines() if l.strip()][-6:]

def boot_info():
    boots = len([l for l in sh(["journalctl", "--list-boots", "--no-pager"], 120).splitlines() if re.match(r"^\s*-?\d+\s", l)])
    prev = sh(["journalctl", "-b", "-1", "-n", "60", "-o", "cat", "--no-pager", "-q"], 120)
    planned = None if not prev else bool(re.search(r"(Reached target .*(Reboot|Power-Off|Halt)|systemd-shutdown|Shutting down\.)", prev))
    return {"boots": boots, "last_planned": planned}

def ext4_errors():
    r = {}
    for dev in os.listdir("/sys/fs/ext4") if os.path.isdir("/sys/fs/ext4") else []:
        if os.path.exists("/sys/fs/ext4/%s/errors_count" % dev):
            r[dev] = int(read("/sys/fs/ext4/%s/errors_count" % dev).strip() or 0)
    return r

def nfs_clients():
    cl = []
    base = "/proc/fs/nfsd/clients"
    if os.path.isdir(base):
        for d in sorted(os.listdir(base)):
            info = read(os.path.join(base, d, "info"))
            addr = re.search(r"address:\s*\"?([\d.:a-f]+)", info); name = re.search(r"name:\s*\"?([^\"\n]*)", info); mv = re.search(r"minor version:\s*(\d+)", info)
            cl.append({"address": addr.group(1).rsplit(":", 1)[0] if addr else d, "name": (name.group(1) if name else "").strip()[:40], "minor": mv.group(1) if mv else "?"})
    return cl

FIRMWARE_REPO = "https://github.com/sq6emm/wdmycloud-gen1-debian"
FIRMWARE_BRANCH = "main"
UPSTREAM_REPO = "https://github.com/symops/MCG1-6.18"

def device_info():
    """Static identity of the box, read once at startup."""
    import struct
    d = {"model": read("/proc/device-tree/model").strip("\0"), "compatible": read("/proc/device-tree/compatible").replace("\0", " ").strip(),
         "kernel": os.uname().release, "kernel_build": os.uname().version, "os": "", "cpu": "", "soc": "", "mac": read("/sys/class/net/%s/address" % NET).strip(),
         "uimage": None, "uimage_size": None, "bootloader": None, "l2": None, "ram": None,
         "repo": FIRMWARE_REPO, "branch": FIRMWARE_BRANCH, "upstream": UPSTREAM_REPO}
    for l in read("/etc/os-release").splitlines():
        if l.startswith("PRETTY_NAME="): d["os"] = l.split("=", 1)[1].strip('"')
    for l in read("/proc/cpuinfo").splitlines():
        if l.startswith("model name") and not d["cpu"]: d["cpu"] = l.split(":", 1)[1].strip()
        if l.startswith("Hardware"): d["soc"] = l.split(":", 1)[1].strip()
    for l in read("/proc/meminfo").splitlines():
        if l.startswith("MemTotal"): d["ram"] = int(l.split()[1]) * 1024
    try:
        with open("/dev/sda5", "rb") as f: h = f.read(64)
        if struct.unpack(">I", h[:4])[0] == 0x27051956:
            d["uimage"] = h[32:64].split(b"\0")[0].decode(errors="replace"); d["uimage_size"] = struct.unpack(">I", h[12:16])[0]
    except OSError: pass
    try:
        import mmap
        fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC); m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0xfff10000)
        ctrl, aux = struct.unpack("<I", m[0x100:0x104])[0], struct.unpack("<I", m[0x104:0x108])[0]; m.close(); os.close(fd)
        ways = 16 if aux & (1 << 16) else 8; wsz = [16, 16, 32, 64, 128, 256, 512, 512][(aux >> 17) & 7]
        d["l2"] = "%d KB (%d ways x %d KB), %s" % (ways * wsz, ways, wsz, "enabled" if ctrl & 1 else "DISABLED")
    except Exception: pass
    try:
        with open("/dev/mtd0ro", "rb") as f: blob = f.read(512 * 1024)
        m = re.search(rb"barebox[ -]\d{4}\.\d{2}[.\w-]*", blob)
        if m: d["bootloader"] = m.group(0).decode(errors="replace")
    except OSError: pass
    return d

def smartd_alerts():
    lines = [l for l in read(os.path.join(STATE_DIR, "smartd-alerts.log")).splitlines() if l.strip()]
    recent = 0; now = time.time()
    for l in lines[-50:]:
        try:
            if now - time.mktime(time.strptime(l[:19], "%Y-%m-%dT%H:%M:%S")) < 7 * 86400: recent += 1
        except ValueError: pass
    sched = None
    m = re.search(r"-s\s+\(?([^\s)]+)\)?", read("/etc/smartd.conf").split("/dev/" + DISK, 1)[-1]) if "/dev/" + DISK in read("/etc/smartd.conf") else None
    if m: sched = m.group(1)
    return {"last": lines[-1][:200] if lines else None, "recent": recent, "total": len(lines), "schedule": sched,
            "running": "smartmontools" not in failed_units() and sh(["systemctl", "is-active", "smartmontools"], 10).strip() == "active"}

def rsyncd_status():
    """rsync daemon: running?, active transfers, last request, last finalize lines, snapshot names."""
    r = {"active": sh(["systemctl", "is-active", "rsync.service"], 10).strip() == "active", "transfers": [], "finalize": [], "snapshots": [], "latest": None, "last_request": None}
    try:
        out = sh(["ss", "-tnH", "state", "established", "( sport = :873 )"], 5)
        r["transfers"] = sorted({l.split()[3].rsplit(":", 1)[0] for l in out.splitlines() if l.strip()})
    except Exception: pass
    lines = read("/var/log/rsyncd.log").splitlines()[-200:]
    req = [l for l in lines if " rsync to " in l or " rsync on " in l]
    r["last_request"] = req[-1][:160] if req else None
    r["finalize"] = [l[:160] for l in read("/var/log/rsync-finalize.log").splitlines() if l.strip()][-3:]
    base = "/srv/data/backup/power"
    try:
        r["snapshots"] = sorted(e.name for e in os.scandir(base) if e.is_dir(follow_symlinks=False))
        r["latest"] = os.readlink(os.path.join(base, "latest")) if os.path.islink(os.path.join(base, "latest")) else None
    except OSError: pass
    return r

def net_link():
    b = "/sys/class/net/%s/" % NET
    return {"speed": read(b + "speed").strip(), "duplex": read(b + "duplex").strip(), "operstate": read(b + "operstate").strip(),
            "mac": read(b + "address").strip(), "mtu": read(b + "mtu").strip()}

# ---------- history on disk ----------
class History:
    def __init__(self):
        self.path = os.path.join(STATE_DIR, "history.csv"); self.rows = []; self.lock = threading.Lock()
        os.makedirs(STATE_DIR, exist_ok=True)
        cutoff = time.time() - KEEP_DAYS * 86400
        for l in read(self.path).splitlines():
            f = l.split(",")
            if len(f) == len(HIST_FIELDS) and f[0].isdigit() and int(f[0]) > cutoff:
                self.rows.append([float(x) if x not in ("", "None") else None for x in f])
        self.rewrite()
    def rewrite(self):
        with open(self.path + ".tmp", "w") as f:
            for r in self.rows: f.write(",".join("" if x is None else ("%d" % x if i == 0 else "%.1f" % x) for i, x in enumerate(r)) + "\n")
        os.replace(self.path + ".tmp", self.path)
    def append(self, row):
        with self.lock:
            self.rows.append(row)
            cutoff = time.time() - KEEP_DAYS * 86400
            if self.rows and self.rows[0][0] < cutoff:
                self.rows = [r for r in self.rows if r[0] >= cutoff]; self.rewrite()
            else:
                with open(self.path, "a") as f:
                    f.write(",".join("" if x is None else ("%d" % x if i == 0 else "%.1f" % x) for i, x in enumerate(row)) + "\n")
    def query(self, seconds, bucket):
        now = time.time(); start = now - seconds
        with self.lock: rows = [r for r in self.rows if r[0] >= start]
        out = {k: [] for k in HIST_FIELDS}; acc = {}
        for r in rows:
            b = int(r[0] // bucket) * bucket
            a = acc.setdefault(b, [[] for _ in HIST_FIELDS])
            for i, v in enumerate(r):
                if v is not None: a[i].append(v)
        for b in sorted(acc):
            out["t"].append(b)
            for i, k in enumerate(HIST_FIELDS[1:], 1):
                vals = acc[b][i]; out[k].append(round(sum(vals) / len(vals), 1) if vals else None)
        return out

# ---------- sampler ----------
class Sampler(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.hist = {k: deque(maxlen=HIST) for k in ("t", "cpu", "softirq", "rd", "wr", "util", "rx", "tx", "rxp", "txp", "nfs_w", "nfs_r")}
        self.prev = None; self.prev_ops = None; self.prev_proc = None
        self.ops_rate = {}; self.top = []; self.net_err = {}
        self.smart = {}; self.smart_at = 0; self.smart_temp_at = 0; self.slow = {}; self.slow_at = 0
        self.history = History()
        self.state_path = os.path.join(STATE_DIR, "state.json")
        try: self.state = json.load(open(self.state_path))
        except Exception: self.state = {"last_nfs_write": None}
        self.boot = {"boots": None, "last_planned": None}; self.device = {}
    def run(self):
        threading.Thread(target=lambda: setattr(self, "boot", boot_info()), daemon=True).start()  # journalctl is slow here
        threading.Thread(target=lambda: setattr(self, "device", device_info()), daemon=True).start()
        while True:
            now = time.time()
            cur = (now, cpu_times(), disk_counters(), net_counters(), nfsd_counters(), proc_cpu())
            if self.prev:
                dt = now - self.prev[0]
                (pt, pi, ps), (ct, ci, cs) = self.prev[1], cur[1]; dtot = max(ct - pt, 1)
                pn, cn = self.prev[3], cur[3]
                s = {"t": int(now), "cpu": round(100 * (1 - (ci - pi) / dtot), 1), "softirq": round(100 * (cs - ps) / dtot, 1),
                     "rd": (cur[2][0] - self.prev[2][0]) / dt, "wr": (cur[2][1] - self.prev[2][1]) / dt,
                     "util": min(100.0, round(100 * (cur[2][2] - self.prev[2][2]) / (dt * 1000), 1)),
                     "rx": (cn["rx_bytes"] - pn["rx_bytes"]) / dt, "tx": (cn["tx_bytes"] - pn["tx_bytes"]) / dt,
                     "rxp": (cn["rx_packets"] - pn["rx_packets"]) / dt, "txp": (cn["tx_packets"] - pn["tx_packets"]) / dt,
                     "nfs_r": (cur[4][0][0] - self.prev[4][0][0]) / dt, "nfs_w": (cur[4][0][1] - self.prev[4][0][1]) / dt}
                ops = {k: round((v - self.prev[4][1].get(k, v)) / dt, 1) for k, v in cur[4][1].items()}
                pp, cp = self.prev[5], cur[5]
                top = sorted(((100 * (c[1] - pp[pid][1]) / dtot * (os.cpu_count() or 1), c[0], pid) for pid, c in cp.items() if pid in pp and c[0] == pp[pid][0]), reverse=True)[:5]
                errs = {k: cn[k] for k in ("rx_errors", "tx_errors", "rx_dropped", "tx_dropped")}
                errs["delta"] = sum(cn[k] - pn[k] for k in ("rx_errors", "tx_errors", "rx_dropped", "tx_dropped"))
                with self.lock:
                    for k, v in s.items(): self.hist[k].append(v)
                    self.ops_rate = ops; self.top = [{"cpu": round(c, 1), "comm": n, "pid": p} for c, n, p in top if c > 0.5]; self.net_err = errs
                if s["nfs_w"] > 0: self.state["last_nfs_write"] = int(now)
            self.prev = cur
            if now - self.smart_at > SMART_EVERY:
                sm = smart()
                with self.lock: self.smart = sm; self.smart_at = now
            if now - self.slow_at > SLOW_EVERY:
                temp = disk_temp()
                slow = {"disk_power": disk_power(), "chrony": chrony(), "failed_units": failed_units(), "kernel_warnings": kernel_warnings(),
                        "ext4_errors": ext4_errors(), "md": mdstat(), "fs": {"root": df(ROOT), "data": df(DATA)}, "clients": nfs_clients(), "link": net_link(), "smartd": smartd_alerts(), "rsyncd": rsyncd_status()}
                with self.lock:
                    self.slow = slow; self.slow_at = now
                    if temp is not None and self.smart: self.smart["temp"] = temp; self.smart_temp_at = now
                    h = self.hist; last = lambda k: h[k][-1] if h[k] else None
                    row = [int(now), self.smart.get("temp"), slow["fs"]["data"]["pct"] if slow["fs"]["data"] else None,
                           last("cpu"), last("wr"), last("rd"), last("rx"), last("tx"), last("nfs_w"), last("nfs_r")]
                try:
                    if row[3] is not None: self.history.append(row)
                    json.dump(self.state, open(self.state_path + ".tmp", "w")); os.replace(self.state_path + ".tmp", self.state_path)
                except OSError: pass
            time.sleep(STEP)

S = Sampler()

def alerts(d):
    a = []; sm = d["smart"]; A = sm.get("attrs", {}); fs = d["fs"]; md = d["md"]
    def add(level, text): a.append({"level": level, "text": text})
    if sm.get("health") not in ("PASSED", None): add("crit", "SMART health: %s" % sm.get("health"))
    for k, label in (("Reallocated_Sector_Ct", "reallocated sectors"), ("Current_Pending_Sector", "pending sectors"), ("Offline_Uncorrectable", "offline uncorrectable sectors")):
        if A.get(k, {}).get("raw", 0) > 0: add("crit", "%s: %d" % (label, A[k]["raw"]))
    if A.get("UDMA_CRC_Error_Count", {}).get("raw", 0) > 0: add("warn", "UDMA CRC errors: %d (cable/connector)" % A["UDMA_CRC_Error_Count"]["raw"])
    t = sm.get("temp")
    if t is not None and t >= 55: add("crit", "disk temperature %d°C" % t)
    elif t is not None and t >= 50: add("warn", "disk temperature %d°C" % t)
    st = sm.get("selftest")
    if st and st["type"] != "none":
        low = st["status"].lower()
        if "failure" in low or ("error" in low and "without error" not in low): add("crit", "last SMART self-test: %s" % st["status"])
        elif "interrupted" in low or "aborted" in low: add("info", "last SMART self-test was %s (%s)" % (st["status"].lower(), st["type"].lower()))
    for name, f in (("data volume", fs.get("data")), ("system volume", fs.get("root"))):
        if f and f["pct"] >= 90: add("crit", "%s %.0f%% full" % (name, f["pct"]))
        elif f and f["pct"] >= 80: add("warn", "%s %.0f%% full" % (name, f["pct"]))
    for k, v in md.items():
        if "_" in v["disks"]: add("crit", "%s degraded [%s]" % (k, v["disks"]))
        if v["sync"]: add("info", "%s %s" % (k, v["sync"]))
        if v["mismatch_cnt"] > 0: add("warn", "%s mismatch_cnt %d" % (k, v["mismatch_cnt"]))
    for dev, n in d["ext4_errors"].items():
        if n > 0: add("crit", "ext4 errors on %s: %d" % (dev, n))
    if d["failed_units"]: add("warn", "failed units: " + ", ".join(d["failed_units"]))
    rd = d.get("rsyncd") or {}
    if rd and not rd.get("active", True): add("warn", "rsync daemon (backup target) is not running")
    sd = d.get("smartd") or {}
    if sd and not sd.get("running", True): add("warn", "smartd is not running")
    if sd.get("recent"): add("crit", "smartd raised %d warning(s) in the last 7 days: %s" % (sd["recent"], sd["last"]))
    c = d["chrony"]
    if not c["synced"]: add("warn", "clock not synchronised (chrony)")
    elif c["offset"] is not None and abs(c["offset"]) > 1: add("warn", "clock offset %.2f s" % c["offset"])
    if d["net_err"].get("delta", 0) > 0: add("warn", "network errors/drops increasing")
    if d["link"]["operstate"] == "up" and d["link"]["speed"] not in ("1000", ""): add("warn", "link at %s Mb/s" % d["link"]["speed"])
    if d["boot"]["last_planned"] is False: add("info", "last reboot was not a clean shutdown (crash or power loss)")
    if d["mem"]["swap_total"] and d["mem"]["swap_used"] > 0.5 * d["mem"]["swap_total"]: add("warn", "swap more than half used")
    return a

def status():
    with S.lock:
        hist = {k: list(v) for k, v in S.hist.items()}; sm = dict(S.smart); sm_at = S.smart_at; temp_at = S.smart_temp_at; slow = dict(S.slow)
        ops = dict(S.ops_rate); top = list(S.top); net_err = dict(S.net_err); last_nfs = S.state.get("last_nfs_write")
    mem = {}
    for l in read("/proc/meminfo").splitlines():
        k, v = l.split(":"); mem[k] = int(v.split()[0]) * 1024
    d = {"host": socket.gethostname(), "kernel": os.uname().release, "time": int(time.time()), "uptime": int(float(read("/proc/uptime").split()[0] or 0)),
         "load": [float(x) for x in read("/proc/loadavg").split()[:3]], "ncpu": os.cpu_count(),
         "mem": {"total": mem.get("MemTotal", 0), "available": mem.get("MemAvailable", 0), "cached": mem.get("Cached", 0), "dirty": mem.get("Dirty", 0),
                 "swap_total": mem.get("SwapTotal", 0), "swap_used": mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)},
         "fs": slow.get("fs", {}), "md": slow.get("md", {}), "ext4_errors": slow.get("ext4_errors", {}), "disk_power": slow.get("disk_power"),
         "chrony": slow.get("chrony", {"synced": True, "offset": None}), "failed_units": slow.get("failed_units", []), "kernel_warnings": slow.get("kernel_warnings", []),
         "link": slow.get("link", {"speed": "", "duplex": "", "operstate": ""}), "smartd": slow.get("smartd", {}), "rsyncd": slow.get("rsyncd", {}), "net_err": net_err, "boot": S.boot,
         "smart": sm, "smart_age": int(time.time() - sm_at) if sm_at else None, "temp_age": int(time.time() - max(sm_at, temp_at)) if sm_at else None,
         "nfs": {"threads": read("/proc/fs/nfsd/threads").strip(), "clients": slow.get("clients", []), "ops": ops}, "last_nfs_write": last_nfs,
         "top": top, "device": S.device, "hist": hist, "now": {k: (v[-1] if v else None) for k, v in hist.items()}}
    d["alerts"] = alerts(d)
    return d

HTML = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "nas-status.html"), "rb").read() if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)), "nas-status.html")) else b"<p>missing nas-status.html</p>"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/api":
            body = json.dumps(status()).encode(); ct = "application/json"
        elif u.path == "/api/history":
            rng = parse_qs(u.query).get("range", ["24h"])[0]
            secs, bucket = (7 * 86400, 900) if rng == "7d" else (86400, 120)
            body = json.dumps(S.history.query(secs, bucket)).encode(); ct = "application/json"
        elif u.path == "/":
            body = HTML; ct = "text/html; charset=utf-8"
        else:
            self.send_error(404); return
        self.send_response(200); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)

if __name__ == "__main__":
    S.start()
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
