#!/bin/bash
# "recovery": the same kernel with the port's rescue initramfs embedded (CONFIG_INITRAMFS_SOURCE), packed as a uImage
# the stock barebox can TFTP and boot through its WD-ICMP-BEACON recovery hook (see docs/RECOVERY.md).
# Built in-tree right after the main kernel (kbuild refuses O= builds in a tree that was built in-tree); the
# .config is restored afterwards so a later `kernel` stage starts from the same state.
set -euo pipefail
K=/work/work/MCG1-6.18; R=/work/work/recovery-root
[ -f "$K/.config" ] || { echo "run kernel first"; exit 1; }
rm -rf "$R" && cp -a "$K/initramfs" "$R"
REL=$(cat /work/out/kernel.release)
for m in phy-ls1024a-serdes usb-storage uas; do
  f=$(find /work/work/modinstall/lib/modules/$REL -name "$m.ko*" | head -1)
  if [ -n "$f" ]; then cp -f "$f" "$R/lib/modules/$m.ko"; else rm -f "$R/lib/modules/$m.ko"; echo "$m: built into this kernel, no module needed"; fi
done
cd "$K"; export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
cp .config .config.main
trap 'cp -f .config.main .config; rm -f .config.main' EXIT
./scripts/config --enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$R" --set-val INITRAMFS_ROOT_UID 0 --set-val INITRAMFS_ROOT_GID 0
make olddefconfig >/dev/null
make -j"$(nproc)" LOCALVERSION= zImage
cat arch/arm/boot/zImage "$(find arch/arm/boot/dts -name 'ls1024a-wdmycloud.dtb' | head -1)" > arch/arm/boot/zImage-recovery
mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 -n "wdmycloud-recovery" -d arch/arm/boot/zImage-recovery /work/out/recovery
SIZE=$(stat -c %s /work/out/recovery); echo "recovery: $SIZE bytes (limit 16 MiB, see recovery/startup.sh)"
[ "$SIZE" -lt $((16*1024*1024)) ] || exit 1
cp /work/recovery/startup.sh /work/out/startup.sh
echo RECOVERY_OK
