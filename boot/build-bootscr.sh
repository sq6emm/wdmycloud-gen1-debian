#!/bin/bash
# Pack the two barebox boot scripts with barebox's own env tool (vendored in the kernel port).
set -euo pipefail
K=/work/work/MCG1-6.18
[ -d "$K/tools/bareboxenv-host" ] || { echo "run kernel first (needs $K)"; exit 1; }
make -s -C "$K/tools/bareboxenv-host" >/dev/null
T="$K/tools/bareboxenv-host/bareboxenv-host"
pack() { "$T" -s "$1" "$2.scr"; ( cat "$2.scr"; head -c $((1048576 - $(stat -c %s "$2.scr"))) /dev/zero ) > "$2.img"; rm "$2.scr"; mv "$2.img" "$2.scr"; }
pack /work/boot/boot.sh /work/out/boot
pack /work/boot/boot-install.sh /work/out/boot-install
ls -la /work/out/boot.scr /work/out/boot-install.scr
echo BOOTSCR_OK
