# Recovery without a serial console

The stock WD barebox has a network recovery hook that survives anything you do to the disk: during the first
seconds after power-on it listens for an ICMP echo request whose payload is `WD-ICMP-BEACON`, sent to the
board's MAC address. On receipt it runs DHCP, fetches `startup.sh` from the TFTP server named by DHCP, and that
script TFTPs and boots a recovery kernel. This project ships such a kernel (`recovery`: the same 6.18 kernel with
a rescue shell embedded) and the host-side script that serves it.

## When

- The box does not answer ping or telnet ten minutes after a reboot.
- You flashed a kernel that does not boot.
- You want the stock firmware back.

## How

On a Linux host on the same L2 segment (same switch, no VLAN in between), with Docker:

```sh
sudo ./recover.sh <iface> <nas-mac> <ip-to-give-the-nas> <this-host-ip> <dir with recovery + startup.sh>
# e.g. sudo ./recover.sh eth0 00:90:a9:12:34:56 192.168.1.50 192.168.1.10 .
```

The MAC is printed on the label under the box. The script starts dnsmasq (DHCP + TFTP) and sends the beacon
once a second. Now power-cycle the NAS. Within ~30 s the dnsmasq log shows the DHCP lease and the two TFTP
transfers; a minute later:

```sh
telnet <ip-to-give-the-nas>        # root, no password; busybox shell with mdadm, dd, xz, tar
```

Note: the board asks for `startup.sh` at the TFTP root, not inside any directory; `recover.sh` serves it there.

## Inside the recovery shell

```sh
mdadm --assemble --run /dev/md0 /dev/sda1 /dev/sda2
mkdir -p /mnt/data && mount /dev/sda4 /mnt/data          # your data partition
ls /mnt/data/wdmycloud-install.done/stock-backup/        # sda5.img sda6.img sda7.img sda8.img (from install.sh)
```

Put back a known-good kernel:

```sh
dd if=/mnt/data/sda5-known-good.img of=/dev/sda5 bs=1M
```

Re-run the installer (e.g. after a broken root filesystem): copy a release into `/mnt/data/wdmycloud-install/`
(`rootfs.img.xz`, `boot.scr`, `SHA256SUMS`), write `installer.uRamdisk` to `/dev/sda6` and `boot-install.scr` to
`/dev/sda7`, `reboot -f`.

Back to the stock firmware: the stock root filesystem on `md0` is gone, so this needs WD's own recovery image
(community mirrors of `Recovery.zip` for the gen1, telnet `root`/`mycloud`) or a WD firmware `.bin`, plus the stock
partition images from `stock-backup/` for partitions 5–8. The data partition is untouched either way.

## If the beacon does not work

Pull the disk, attach it to a PC and write partitions 5/6/7 there (`dd` to `/dev/sdX5` etc.). Barebox in the
SPI flash is never written by anything in this project, so the box always gets as far as loading whatever is on
partition 5.
