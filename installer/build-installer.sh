#!/bin/bash
# installer.uRamdisk: the kernel port's rescue initramfs (static busybox + mdadm) with this project's init on top,
# plus the three storage modules from our own kernel build (they must match its vermagic).
set -euo pipefail
K=/work/work/MCG1-6.18
R=/work/work/installer-root
[ -d "$K/initramfs" ] || { echo "run kernel first"; exit 1; }
rm -rf "$R" && cp -a "$K/initramfs" "$R"
install -m 755 /work/installer/init "$R/init"
REL=$(cat /work/out/kernel.release)
for m in phy-ls1024a-serdes usb-storage uas; do
  f=$(find /work/work/modinstall/lib/modules/$REL -name "$m.ko*" | head -1)
  if [ -n "$f" ]; then cp -f "$f" "$R/lib/modules/$m.ko"; else rm -f "$R/lib/modules/$m.ko"; echo "$m: built into this kernel, no module needed"; fi
done
(cd "$R" && find . | cpio -o -H newc 2>/dev/null | pigz -11 > /work/work/installer.cpio.gz)
mkimage -A arm -O linux -T ramdisk -C none -a 0x04008000 -e 0x04008000 -n "wdmycloud-installer" \
  -d /work/work/installer.cpio.gz /work/out/installer.uRamdisk
SIZE=$(stat -c %s /work/out/installer.uRamdisk); echo "installer.uRamdisk: $SIZE bytes (limit 10 MiB)"
[ "$SIZE" -lt $((10*1024*1024)) ] || exit 1
echo INSTALLER_OK
