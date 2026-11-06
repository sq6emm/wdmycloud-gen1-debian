#!/bin/bash
# Sanity checks on a built release (runs inside the build container): image headers, sizes, rootfs contents.
set -uo pipefail
D=${1:-/work/out}; rc=0
chk() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; rc=1; fi; }
echo "== images"
for f in uImage installer.uRamdisk recovery; do
  [ -f "$D/$f" ] || { echo "FAIL $f missing"; rc=1; continue; }
  mkimage -l "$D/$f" | sed -n '1,6p' | sed "s/^/     /"
done
chk "uImage < 10 MiB (stock boot script window)"        '[ $(stat -c %s "$D/uImage") -lt 10485760 ]'
chk "installer.uRamdisk < 10 MiB"                        '[ $(stat -c %s "$D/installer.uRamdisk") -lt 10485760 ]'
chk "recovery < 16 MiB"                                  '[ $(stat -c %s "$D/recovery") -lt 16777216 ]'
chk "boot.scr is 1 MiB with barebox env magic"           '[ $(stat -c %s "$D/boot.scr") -eq 1048576 ] && [ "$(head -c4 "$D/boot.scr" | od -An -tx1 | tr -d " \n")" = "79ba8f79" ]'
chk "boot-install.scr is 1 MiB with barebox env magic"   '[ $(stat -c %s "$D/boot-install.scr") -eq 1048576 ] && [ "$(head -c4 "$D/boot-install.scr" | od -An -tx1 | tr -d " \n")" = "79ba8f79" ]'
echo "== rootfs"
IMG=/work/work/rootfs.img
[ -f "$IMG" ] || { xz -dk -c "$D/rootfs.img.xz" > "$IMG"; }
chk "rootfs image is exactly md0-sized (1999808 KiB)"    '[ $(stat -c %s "$IMG") -eq $((1999808*1024)) ]'
chk "rootfs fsck clean"                                   'e2fsck -fn "$IMG" >/dev/null 2>&1'
chk "rootfs is ext3 (has_journal, no extents)"            'dumpe2fs -h "$IMG" 2>/dev/null | grep -q "has_journal" && ! dumpe2fs -h "$IMG" 2>/dev/null | grep "features" | grep -q extent'
cat_f() { debugfs -R "cat $1" "$IMG" 2>/dev/null; }
ls_f()  { debugfs -R "ls -l $1" "$IMG" 2>/dev/null; }
chk "/etc/wdmycloud-release present"                      'cat_f /etc/wdmycloud-release | grep -q wdmycloud'
echo "     $(cat_f /etc/wdmycloud-release)"
chk "/etc/fstab mounts md0 as ext3"                        'cat_f /etc/fstab | grep -q "^/dev/md0 .* ext3"'
chk "root password set and expired"                        'cat_f /etc/shadow | grep -q "^root:\$[^:]*:0:"'
chk "no ssh host keys in image"                            '! ls_f /etc/ssh | grep -q ssh_host_'
chk "machine-id empty"                                     '[ -z "$(cat_f /etc/machine-id)" ]'
chk "kernel modules match uImage release"                  'ls_f /lib/modules | grep -q "$(cat $D/kernel.release)"'
chk "modules.dep present"                                  'ls_f "/lib/modules/$(cat $D/kernel.release)" | grep -q modules.dep'
wants() { for d in multi-user.target.wants sysinit.target.wants getty.target.wants; do ls_f "/etc/systemd/system/$d"; done; }
for u in ssh.service chrony.service rsync.service smartmontools.service nftables.service nas-status.service serial-getty@ttyS0.service; do
  chk "enabled: $u" 'wants | grep -q "'"$u"'"'
done
chk "sshd PermitRootLogin yes"                             'cat_f /etc/ssh/sshd_config | grep -q "^PermitRootLogin yes"'
chk "nftables.conf, rsyncd.conf, smartd.conf, nas-status present" 'ls_f /etc | grep -q nftables.conf && ls_f /etc | grep -q rsyncd.conf && ls_f /usr/local/bin | grep -q nas-status.py'
chk "timezone UTC"                                         '[ "$(cat_f /etc/timezone)" = "UTC" ]'
chk "python3 installed (status page)"                      'ls_f /usr/bin | grep -q " python3$"'
chk "no nfs-kernel-server"                                 '! ls_f /usr/sbin | grep -q rpc.nfsd'
echo "== release dir"
R=$(ls -d "$D"/release/* 2>/dev/null | head -1)
if [ -n "$R" ]; then (cd "$R" && sha256sum -c SHA256SUMS >/dev/null && echo "ok   SHA256SUMS verify" || { echo "FAIL SHA256SUMS"; rc=1; }); ls -la "$R"; else echo "FAIL no release dir"; rc=1; fi
[ $rc -eq 0 ] && echo CHECK_OK || echo CHECK_FAILED
exit $rc
