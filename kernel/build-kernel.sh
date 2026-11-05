#!/bin/bash
# Kernel: clone the symops port at a pinned commit, apply this project's config choices, build uImage + modules.
set -euo pipefail
KERNEL_REPO=${KERNEL_REPO:-https://github.com/symops/MCG1-6.18.git}
KERNEL_REF=${KERNEL_REF:-ef2980c53}     # main after PRs #2/#3/#4 (PFE offloads, L2 cache, UPDATING.md) were merged
K=/work/work/MCG1-6.18
if [ ! -d "$K/.git" ]; then
  git clone --filter=blob:none "$KERNEL_REPO" "$K"
fi
cd "$K"; git fetch -q origin; git checkout -q "$KERNEL_REF"
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
make ls1024a_defconfig
# --- this project's config on top of the port's defconfig (see kernel/config.fragment for the why) ---
while read -r opt; do
  case $opt in ''|'#'*) continue;; esac
  ./scripts/config --file .config $opt
done < /work/kernel/config.fragment
make olddefconfig
grep -E "^CONFIG_(PHY_LS2014A_SERDES|PHY_LS2014A_USB3|PREEMPT_NONE|MEMCG|BLK_CGROUP|IRQ_TIME_ACCOUNTING|KERNEL_XZ)=" .config || true
make -j"$(nproc)" LOCALVERSION= zImage dtbs modules
REL=$(cat include/config/kernel.release)
DTB=$(find arch/arm/boot/dts -name 'ls1024a-wdmycloud.dtb' | head -1)
cat arch/arm/boot/zImage "$DTB" > arch/arm/boot/zImage-w-dtb
mkimage -A arm -O linux -T kernel -C none -a 0x00008000 -e 0x00008000 \
  -n "Linux-$REL-wdmycloud" -d arch/arm/boot/zImage-w-dtb /work/out/uImage
rm -rf /work/work/modinstall && make LOCALVERSION= INSTALL_MOD_PATH=/work/work/modinstall modules_install >/dev/null
(cd /work/work/modinstall/lib/modules && tar -cJf /work/out/modules.tar.xz .)
echo "$REL" > /work/out/kernel.release
SIZE=$(stat -c %s /work/out/uImage)
echo "uImage: $SIZE bytes (barebox reads 16 MiB with this project's boot.scr, 10 MiB with the stock one)"
[ "$SIZE" -lt $((16*1024*1024)) ] || { echo "uImage too big"; exit 1; }
echo KERNEL_OK
