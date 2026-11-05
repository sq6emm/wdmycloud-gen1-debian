# Building a release

Everything is built inside one Docker image (`Dockerfile`: Debian 13 with the ARM cross toolchain, debootstrap,
qemu-user-static, u-boot-tools). The host needs Docker and, for the root filesystem stage, qemu-user binfmt
registration for ARM:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm
./build.sh all            # or: kernel | bootscr | installer | recovery | rootfs | release
```

Stages and outputs (all under `out/`):

| stage | script | output | notes |
|---|---|---|---|
| kernel | `kernel/build-kernel.sh` | `uImage`, `modules.tar.xz`, `kernel.release` | clones symops/MCG1-6.18 at `KERNEL_REF`, applies `kernel/config.fragment`, appended DTB, barebox uImage header |
| bootscr | `boot/build-bootscr.sh` | `boot.scr`, `boot-install.scr` | packed with barebox's own `bareboxenv` tool from the kernel tree, padded to the 1 MiB partition |
| installer | `installer/build-installer.sh` | `installer.uRamdisk` | the port's rescue initramfs with `installer/init` as PID 1 |
| recovery | `recovery/build-recovery.sh` | `recovery`, `startup.sh` | second kernel build (`O=`) with the rescue initramfs embedded |
| rootfs | `rootfs/build-rootfs.sh` | `rootfs.img.xz` | debootstrap minbase + `rootfs/packages.txt` + `rootfs/overlay/`, ext3 image sized to md0 (1999808 KiB) |
| release | `tools/make-release.sh` | `out/release/<version>/` | everything above + `install.sh`, `recover.sh`, `SHA256SUMS` |

A full build takes about 30 minutes on a 32-core machine (two kernel builds and a debootstrap under qemu).

## Kernel configuration

`ls1024a_defconfig` from the port, plus `kernel/config.fragment`: the SerDes PHY built in (root on SATA cannot
wait for a module), `PREEMPT_NONE`, no memory/blkio cgroups (measurably faster page-cache writes on this CPU),
IRQ time accounting. Change `KERNEL_REF` in `kernel/build-kernel.sh` to move to a newer upstream commit.

## Root filesystem

`rootfs/build-rootfs.sh` is the whole recipe: package list, overlay, services, default password (`ROOTPW`,
default `mycloud`, expired so the first login must change it), hostname (`HOSTNAME_`, default `wdmycloud`). SSH
host keys and `machine-id` are not in the image; they are generated on first boot. `/etc/wdmycloud-release`
records the version.

## Limits to keep in mind

- barebox reads a fixed window from partition 5: 16 MiB with this project's `boot.scr`, 10 MiB with the stock
  one. `install.sh` writes the kernel before the new boot script, so a first install must still fit in 10 MiB;
  the XZ-compressed kernel is about 5.5 MiB.
- `mkimage -n` names are cut at 32 characters.
- The rootfs image must be exactly the size of `md0`; the installer warns if the array has a different size.
