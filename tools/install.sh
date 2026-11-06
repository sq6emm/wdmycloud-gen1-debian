#!/bin/bash
# Run this ON THE STOCK WD MY CLOUD (gen1) as root over SSH, from a directory that holds a release:
#   uImage  installer.uRamdisk  boot-install.scr  boot.scr  rootfs.img.xz  SHA256SUMS
# It stages the release on the data partition, backs up the stock kernel/boot script there, writes the installer
# into partitions 5/6/7 and reboots. The installer then writes the Debian root filesystem and reboots again.
# Your files in /DataVolume (shares) are not touched. The stock firmware is replaced. See docs/INSTALL.md.
set -euo pipefail
cd "$(dirname "$0")"
DATA=/DataVolume; [ -d /srv/data ] && [ ! -d /DataVolume ] && DATA=/srv/data
for f in uImage installer.uRamdisk boot-install.scr boot.scr rootfs.img.xz SHA256SUMS; do [ -f "$f" ] || { echo "missing $f"; exit 1; }; done
echo "== checking the box"
grep -q "sq" /proc/cmdline 2>/dev/null && echo "model=sq (My Cloud gen1): OK" || { echo "this does not look like a WD My Cloud gen1 (model=sq not in /proc/cmdline)"; exit 1; }
for p in 1 2 3 4 5 6 7 8; do [ -b /dev/sda$p ] || { echo "/dev/sda$p missing: unexpected partition layout"; exit 1; }; done
grep -q "^md0 " /proc/mdstat || { echo "no md0: unexpected RAID layout"; exit 1; }
mountpoint -q "$DATA" || { echo "$DATA is not mounted"; exit 1; }
echo "== verifying checksums"; grep -E " (uImage|installer\.uRamdisk|boot-install\.scr|boot\.scr|rootfs\.img\.xz)$" SHA256SUMS | sha256sum -c -
echo "== staging on $DATA/wdmycloud-install"
D="$DATA/wdmycloud-install"; rm -rf "$D"; mkdir -p "$D/stock-backup"
cp rootfs.img.xz boot.scr SHA256SUMS "$D/"
dd if=/dev/sda5 of="$D/stock-backup/sda5.img" bs=1M count=10 2>/dev/null
dd if=/dev/sda6 of="$D/stock-backup/sda6.img" bs=1M count=10 2>/dev/null
dd if=/dev/sda7 of="$D/stock-backup/sda7.img" bs=1M count=1  2>/dev/null
dd if=/dev/sda8 of="$D/stock-backup/sda8.img" bs=1M count=2  2>/dev/null
sync
echo "== writing kernel (sda5), installer (sda6), installer boot script (sda7)"
dd if=uImage of=/dev/sda5 bs=1M conv=fsync 2>/dev/null; cmp -n "$(stat -c %s uImage)" uImage /dev/sda5
dd if=installer.uRamdisk of=/dev/sda6 bs=1M conv=fsync 2>/dev/null; cmp -n "$(stat -c %s installer.uRamdisk)" installer.uRamdisk /dev/sda6
dd if=boot-install.scr of=/dev/sda7 bs=1M conv=fsync 2>/dev/null; cmp -n "$(stat -c %s boot-install.scr)" boot-install.scr /dev/sda7
sync
echo "== done. Rebooting into the installer; the box is back on the network as Debian in about 5 minutes."
echo "   Then: ssh root@<ip>  (password: mycloud, you will be asked to change it)."
sleep 3
reboot
