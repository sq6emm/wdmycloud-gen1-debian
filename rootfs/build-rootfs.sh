#!/bin/bash
# Root filesystem: Debian 13 armhf via debootstrap (second stage under qemu-user), this project's overlay and
# service selection, modules from our kernel build, packed into an ext3 image sized exactly like the stock md0.
# Runs as root inside the build container (--privileged for chroot/mknod/binfmt).
set -euo pipefail
R=/work/work/rootfs
IMG=/work/work/rootfs.img
MD0_KIB=1999808                 # stock WD My Cloud gen1: md0 = sda1+sda2 RAID1, 1999808 KiB
ROOTPW=${ROOTPW:-mycloud}
HOSTNAME_=${HOSTNAME_:-wdmycloud}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
PKGS=$(grep -v '^#' /work/rootfs/packages.txt | grep -v '^$' | paste -sd, -)
[ -f /work/out/modules.tar.xz ] || { echo "run kernel first"; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || echo "WARNING: no qemu-arm binfmt on the host; second stage will fail"

rm -rf "$R"
debootstrap --arch=armhf --foreign --variant=minbase --include="$PKGS" trixie "$R" "$MIRROR"
cp /usr/bin/qemu-arm-static "$R/usr/bin/"
chroot "$R" /debootstrap/debootstrap --second-stage
# no service starts inside the chroot
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod 755 "$R/usr/sbin/policy-rc.d"

# --- base configuration ---
echo "$HOSTNAME_" > "$R/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$HOSTNAME_" > "$R/etc/hosts"
cat > "$R/etc/apt/sources.list" <<EOT
deb $MIRROR trixie main contrib non-free-firmware
deb $MIRROR trixie-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
EOT
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' "$R/etc/locale.gen"; chroot "$R" locale-gen >/dev/null
echo 'LANG=en_US.UTF-8' > "$R/etc/default/locale"
ln -sf /usr/share/zoneinfo/UTC "$R/etc/localtime"; echo UTC > "$R/etc/timezone"
# overlay (fstab, mdadm, network, nftables, rsyncd, smartd, status page, journald, ...)
cp -a /work/rootfs/overlay/. "$R/"
# modules from our kernel
mkdir -p "$R/lib/modules"; tar -C "$R/lib/modules" -xJf /work/out/modules.tar.xz
# sshd: root login with password allowed (the firewall limits it to private networks); no host keys in the image,
# Debian's sshd-keygen.service generates them on first boot
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$R/etc/ssh/sshd_config"
rm -f "$R"/etc/ssh/ssh_host_*
# default password, change forced at first login
echo "root:$ROOTPW" | chroot "$R" chpasswd
chroot "$R" chage -d 0 root
# machine-id is generated on first boot
: > "$R/etc/machine-id"; rm -f "$R/var/lib/dbus/machine-id"
# services
chroot "$R" systemctl enable serial-getty@ttyS0.service ssh.service chrony.service rsync.service smartmontools.service \
  nftables.service nas-status.service mdmonitor.service >/dev/null 2>&1 || true
chroot "$R" systemctl disable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
mkdir -p "$R/srv/data" "$R/var/log/journal"
# version stamp
echo "wdmycloud-gen1-debian ${VERSION:-unknown} $(date -u +%F) kernel $(cat /work/out/kernel.release)" > "$R/etc/wdmycloud-release"
# cleanup
rm -f "$R/usr/sbin/policy-rc.d" "$R/usr/bin/qemu-arm-static"
rm -rf "$R"/var/cache/apt/archives/*.deb "$R"/var/lib/apt/lists/* "$R"/var/log/*.log
du -sh "$R" | cut -f1

# --- ext3 image, exactly md0-sized ---
rm -f "$IMG"; truncate -s $((MD0_KIB*1024)) "$IMG"
mke2fs -q -F -t ext3 -L rootfs -d "$R" "$IMG"
e2fsck -fn "$IMG" >/dev/null && echo "image fsck clean"
xz -T0 -9 -f -k "$IMG"; mv -f "$IMG.xz" /work/out/rootfs.img.xz
ls -la /work/out/rootfs.img.xz
echo ROOTFS_OK
