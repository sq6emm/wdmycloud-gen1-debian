# Installing on a WD My Cloud (Gen 1)

What you need: a WD My Cloud gen1 (the 2013 single-bay model; `model=sq` in its kernel command line) running the
stock firmware with SSH enabled, a release of this project, and a Linux/macOS machine on the same network.
No serial console, no opening the case. The procedure takes two reboots and about ten minutes.

**What it does**: replaces the stock kernel and root filesystem (the 2 GB RAID1 `md0` on partitions 1+2) with
Debian 13. The data partition (`/dev/sda4`, mounted as `/DataVolume` on stock, `/srv/data` afterwards) is left
alone, including your shares. The stock firmware itself is gone afterwards; the installer keeps a copy of the stock
kernel, initrd and boot scripts on the data partition (`wdmycloud-install.done/stock-backup/`), and
[RECOVERY.md](RECOVERY.md) explains the way back if you want it.

**What you lose**: the WD web UI, cloud access, Samba/AFP shares, Twonky, the WD mobile apps. What you get is a
plain Debian box with SSH, an rsync daemon, SMART monitoring and a status page. Samba or anything else is one
`apt install` away.

## 1. Enable SSH on the stock firmware

Web UI → Settings → Network → SSH: on. Log in as `root` (the stock password is `welc0me`; recent stock versions
force you to change it on first login). Old stock versions need legacy SSH options from a modern client:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1 root@<nas-ip>
```

## 2. Copy the release and run the installer

```sh
scp uImage installer.uRamdisk boot-install.scr boot.scr rootfs.img.xz SHA256SUMS install.sh root@<nas-ip>:/DataVolume/
ssh root@<nas-ip> 'cd /DataVolume && bash install.sh'
```

`install.sh` checks the model and partition layout, verifies the checksums, backs up partitions 5–8 to the data
partition, writes the kernel to partition 5, the installer initramfs to partition 6 and the installer boot script
to partition 7, then reboots.

## 3. Wait

- Reboot 1: barebox loads the new kernel and the installer. The installer assembles `md0`, writes `rootfs.img.xz`
  onto it (about three minutes), writes the final boot script to partition 7, moves the staging directory to
  `wdmycloud-install.done` and reboots.
- Reboot 2: Debian comes up and asks DHCP for an address (the MAC is unchanged, so your router most likely hands
  out the same one). About 100 s after the second reboot the box answers on port 22.

If the box does not answer after ten minutes, the installer has stopped on an error and is waiting with a
telnet shell (`telnet <nas-ip>`, user `root`, no password; `cat /tmp/install.log`). If it does not answer on
telnet either, see [RECOVERY.md](RECOVERY.md).

## 4. First login

```sh
ssh root@<nas-ip>        # password: mycloud -- you are asked to change it immediately
```

Then, in whatever order:

- `http://<nas-ip>/` – the status page (disk usage, SMART, temperature, load, network, rsync daemon, history).
- `/srv/data` is your old `/DataVolume`. The stock `shares/` directory and WD's own directories are still there;
  delete what you do not need.
- Time zone: `dpkg-reconfigure tzdata` (the image ships UTC). Hostname: `hostnamectl set-hostname ...`.
- Backups from a Linux client: [BACKUP.md](BACKUP.md). The rsync daemon listens on 873 for private networks.
- Firewall: `/etc/nftables.conf` allows 22/80/873 from RFC 1918 networks; narrow it to your subnet if you like.
- SMART: `smartd` runs a short self-test daily at 12:00 and a long one on Sundays at 09:00 (local time);
  warnings land in `/srv/data/.nas-status/smartd-alerts.log` and on the status page.
- Want Samba? `apt install samba` and open 445 in `/etc/nftables.conf`. Expect 20–30 MB/s; see the README for
  why the CPU is the limit.

## Updating later

A newer `uImage` goes to partition 5 from the running system:

```sh
dd if=/dev/sda5 of=/srv/data/sda5-known-good.img bs=1M count=16
dd if=uImage of=/dev/sda5 bs=1M conv=fsync && cmp -n "$(stat -c %s uImage)" uImage /dev/sda5 && reboot
```

Install the matching `modules.tar.xz` into `/lib/modules` first if the kernel configuration changed
(`vermagic`). A newer root filesystem means running the installer again (it does not touch `/srv/data`, but it
does replace `/etc`; copy your changes first).
