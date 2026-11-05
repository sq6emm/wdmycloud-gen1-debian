#!/bin/sh
## Button initial state
btn_status=0
get_button_status
sata
satapart 0x3008000 5 0x8000
[ -e /dev/mem.initrd ] || addpart /dev/mem 10M@0x4008000(initrd)
satapart 0x4008000 6 0x5000
sata stop
bootargs="console=ttyS0,115200n8, init=/init wdmycloud_install=1"
bootargs="$bootargs panic=10"
bootargs="$bootargs mac_addr=$eth0.ethaddr"
bootargs="$bootargs model=$model serial=$serial board_test=$board_test btn_status=$btn_status"
bootm -r /dev/mem.initrd /dev/mem.uImage
