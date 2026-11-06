#!/bin/bash
# Host side of the network recovery (see docs/RECOVERY.md). Runs dnsmasq (DHCP + TFTP) and the ICMP beacon in a
# throwaway container with host networking. Needs Docker; the NAS must be on the same L2 segment as the interface.
#   sudo ./recover.sh <iface> <nas-mac> <ip-to-give-the-nas> <this-host-ip> [dir-with-recovery+startup.sh]
set -euo pipefail
IFACE=${1:?iface}; MAC=${2:?nas mac, e.g. 00:90:a9:xx:xx:xx}; NASIP=${3:?ip for the nas}; HOSTIP=${4:?this host ip}
DIR=$(cd "${5:-$(dirname "$0")/../out}" && pwd)
[ -f "$DIR/recovery" ] && [ -f "$DIR/startup.sh" ] || { echo "need recovery + startup.sh in $DIR"; exit 1; }
T=$(mktemp -d)
cat > "$T/dnsmasq.conf" <<CONF
port=0
interface=$IFACE
bind-interfaces
dhcp-range=${NASIP%.*}.0,static
dhcp-host=$MAC,$NASIP,2m
dhcp-boot=startup.sh,,$HOSTIP
enable-tftp
tftp-root=/tftp
log-dhcp
log-facility=-
CONF
cat > "$T/run.sh" <<RUN
apk add -q dnsmasq nmap nmap-nping >/dev/null
dnsmasq -d -C /etc/dnsmasq.conf &
nping -e $IFACE --dest-mac $MAC -c 900 --delay 1s --icmp --icmp-type echo --icmp-code 0 --data-string WD-ICMP-BEACON 255.255.255.255 >/dev/null &
wait
RUN
echo "Power-cycle the NAS now. Watching for DHCP/TFTP from $MAC on $IFACE (Ctrl-C to stop)"
docker run --rm -it --network host --cap-add NET_ADMIN --cap-add NET_RAW \
  -v "$DIR":/tftp:ro -v "$T/dnsmasq.conf":/etc/dnsmasq.conf:ro -v "$T/run.sh":/run.sh:ro alpine:3.20 sh /run.sh
rm -rf "$T"
