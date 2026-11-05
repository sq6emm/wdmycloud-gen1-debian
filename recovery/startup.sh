#!/bin/sh
addpart /dev/mem 16M@0x3008000(uImage)
tftp recovery /dev/mem.uImage
bootargs="console=ttyS0,115200n8, init=/init raid=autodetect"
bootargs="$bootargs root=/dev/ram0 rootfstype=ramfs"
bootargs="$bootargs mac_addr=$eth0.ethaddr"
bootargs="$bootargs model=$model serial=$serial board_test=$board_test"
led s y
bootm /dev/mem.uImage
