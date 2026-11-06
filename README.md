# Debian 13 firmware for the WD My Cloud (Gen 1)

A plain Linux for the 2013 single-disk WD My Cloud ("gen1", Mindspeed Comcerto 2000 / Freescale LS1024A,
2x Cortex-A9 @ 650 MHz, 256 MB RAM): mainline-based kernel 6.18 ([symops/MCG1-6.18](https://github.com/symops/MCG1-6.18))
plus a minimal Debian 13 (trixie) armhf root filesystem. No WD web UI, no cloud, no Samba by default:
SSH, an rsync daemon as a backup target, SMART monitoring and a small status page.

| | |
|---|---|
| Kernel | 6.18.x, PFE Ethernet with checksum offload, GRO and zero-copy Rx, L2 cache enabled |
| Root filesystem | Debian 13 armhf on the stock RAID1 (`/dev/md0`, 2 GB), data partition on `/srv/data` |
| Services | sshd, rsync daemon (TCP 873), smartd (weekly long self-test), chrony, status page on port 80 |
| Firewall | nftables: 22/80/873 from private networks only |
| Login | `root` / `mycloud`, password change forced at first login |
| Measured | ~25 MB/s rsync ingest, 55 MB/s raw TCP, 70 MB/s local ext4 writes (the CPU is the limit) |

The user data partition (`/dev/sda4`, the stock `/DataVolume`) is not touched by the installer. The stock WD
firmware is gone afterwards, though; the installer keeps a copy of the stock kernel and boot script on the data
partition, see [RECOVERY.md](docs/RECOVERY.md) for the way back.

- [INSTALL.md](docs/INSTALL.md) – flashing from the stock WD firmware (two reboots, no serial console, no disk pull)
- [RECOVERY.md](docs/RECOVERY.md) – network recovery when the box does not come back
- [BACKUP.md](docs/BACKUP.md) – nightly rsync snapshots from a Linux client
- [BUILDING.md](docs/BUILDING.md) – reproducing every artifact with Docker

## Status

The kernel, root filesystem recipe and services are what the author's own My Cloud runs (installed by hand, step by
step, before this pipeline existed). The one-shot path through `install.sh` and the installer initramfs is built
from the same pieces but has not been exercised on hardware yet; treat the first release as a candidate and keep
[RECOVERY.md](docs/RECOVERY.md) at hand. The data partition is never written by the installer, only the 2 GB system
array and the boot partitions.

## What is in a release

| file | what | goes to |
|---|---|---|
| `uImage` | kernel + device tree, barebox format | partition 5 |
| `rootfs.img.xz` | Debian 13 root filesystem, ext3, exactly the size of `md0` | `/dev/md0` (written by the installer) |
| `installer.uRamdisk` | the installer initramfs | partition 6 (temporarily) |
| `boot-install.scr`, `boot.scr` | barebox boot scripts: installer stage, final | partition 7 |
| `recovery` | network recovery image (kernel with embedded rescue shell) | served over TFTP, never written to disk |
| `install.sh` | the script you run on the stock firmware | |
| `SHA256SUMS` | | |

## Credits

The kernel port is [symops/MCG1-6.18](https://github.com/symops/MCG1-6.18); the PFE driver and L2 cache work from
this project was merged there. The rescue initramfs and barebox env tooling come from the same tree. The network
recovery hook is a feature of WD's stock barebox; the procedure follows what the community (Fox_exe and others)
documented for it.

## License

Scripts and configuration in this repository: MIT. The kernel is GPL-2.0, source at the link above.
