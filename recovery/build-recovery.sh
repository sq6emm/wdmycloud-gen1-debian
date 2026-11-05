#!/bin/bash
# "recovery": the same kernel with the port's rescue initramfs embedded (CONFIG_INITRAMFS_SOURCE), packed as a uImage
# the stock barebox can TFTP and boot through its WD-ICMP-BEACON recovery hook (see docs/RECOVERY.md).
# Built in a separate output directory so the main build is untouched.
set -euo pipefail
K=/work/work/MCG1-6.18; O=/work/work/kbuild-recovery; R=/work/work/recovery-root
[ -d "$K" ] || { echo "run kernel first"; exit 1; }
rm -rf "$R" && cp -a "$K/initramfs" "$R"
REL=$(cat /work/out/kernel.release)
for m in phy-ls1024a-serdes usb-storage uas; do
  cp -f "$(find /work/work/modinstall/lib/modules/$REL -name "$m.ko*" | head -1)" "$R/lib/modules/$m.ko"
done
cd "$K"; export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
mkdir -p "$O"; make O="$O" ls1024a_defconfig >/dev/null
while read -r opt; do case $opt in ''|'#'*) continue;; esac; ./scripts/config --file "$O/.config" $opt; done < /work/kernel/config.fragment
./scripts/config --file "$O/.config" --set-str INITRAMFS_SOURCE "$R" --enable BLK_DEV_INITRD --set-val INITRAMFS_ROOT_UID 0 --set-val INITRAMFS_ROOT_GID 0
make O="$O" olddefconfig >/dev/null
make O="$O" -j"$(nproc)" LOCALVERSION= zImage dtbs
cat "$O/arch/arm/boot/zImage" "$(find "$O/arch/arm/boot/dts" -name 'ls1024a-wdmycloud.dtb' | head -1)" > "$O/zImage-w-dtb"
mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 -n "wdmycloud-recovery" -d "$O/zImage-w-dtb" /work/out/recovery
SIZE=$(stat -c %s /work/out/recovery); echo "recovery: $SIZE bytes (limit 16 MiB, see recovery/startup.sh)"
[ "$SIZE" -lt $((16*1024*1024)) ] || exit 1
cp /work/recovery/startup.sh /work/out/startup.sh
echo RECOVERY_OK
