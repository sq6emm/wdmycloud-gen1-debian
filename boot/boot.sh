#!/bin/sh
## Button initial state
btn_status=0
get_button_status
sata 
satapart 0x3008000 5 0x8000
sata stop
# This is customized for each environment variable script
bootargs="console=ttyS0,115200n8, init=/sbin/init"
bootargs="$bootargs root=/dev/md0 raid=autodetect"
bootargs="$bootargs rootfstype=ext3 rw noinitrd panic=3"
bootargs="$bootargs mac_addr=$eth0.ethaddr"
bootargs="$bootargs model=$model serial=$serial board_test=$board_test btn_status=$btn_status"
bootm /dev/mem.uImage
