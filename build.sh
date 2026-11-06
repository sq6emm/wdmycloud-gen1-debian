#!/bin/bash
# Build orchestrator. Everything runs inside the Docker image built from ./Dockerfile; the host only needs Docker
# and (for the rootfs stage) qemu-user binfmt for ARM:  docker run --privileged --rm tonistiigi/binfmt --install arm
#
#   ./build.sh kernel      -> out/uImage, out/modules.tar.xz, work/MCG1-6.18 (clone of the kernel port)
#   ./build.sh bootscr     -> out/boot.scr, out/boot-install.scr
#   ./build.sh installer   -> out/installer.uRamdisk           (needs kernel)
#   ./build.sh recovery    -> out/recovery                     (needs kernel)
#   ./build.sh rootfs      -> out/rootfs.img.xz                (needs kernel)
#   ./build.sh release     -> out/release/<version>/ with SHA256SUMS, install.sh and the docs
#   ./build.sh all         -> all of the above
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=wdmycloud-build
VERSION=${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)}
mkdir -p out work
docker image inspect $IMAGE >/dev/null 2>&1 || docker build -t $IMAGE .
run() { local n; n=$(basename "$1" .sh); docker run --rm --name "wdmycloud-build-$n" -v "$PWD":/work -w /work -e VERSION="$VERSION" "${@:2}" $IMAGE bash "$1"; }
stage() {
  case $1 in
    kernel)    run kernel/build-kernel.sh ;;
    bootscr)   run boot/build-bootscr.sh ;;
    installer) run installer/build-installer.sh ;;
    recovery)  run recovery/build-recovery.sh ;;
    rootfs)    run rootfs/build-rootfs.sh --privileged ;;   # debootstrap: chroot + mknod + binfmt
    release)   run tools/make-release.sh ;;
    all)       for s in kernel bootscr installer recovery rootfs release; do stage $s; done ;;
    *) echo "usage: $0 {kernel|bootscr|installer|recovery|rootfs|release|all}"; exit 1 ;;
  esac
}
stage "${1:-all}"
