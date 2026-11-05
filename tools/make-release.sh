#!/bin/bash
# Collect a release directory: artifacts, install.sh, checksums.
set -euo pipefail
V=${VERSION:-unknown}; D=/work/out/release/$V
mkdir -p "$D"
for f in uImage installer.uRamdisk boot-install.scr boot.scr rootfs.img.xz recovery startup.sh modules.tar.xz kernel.release; do
  [ -f /work/out/$f ] || { echo "missing out/$f"; exit 1; }; cp /work/out/$f "$D/"
done
cp /work/tools/install.sh /work/recovery/recover.sh "$D/"
(cd "$D" && sha256sum uImage installer.uRamdisk boot-install.scr boot.scr rootfs.img.xz recovery startup.sh modules.tar.xz > SHA256SUMS)
ls -la "$D"; echo RELEASE_OK
