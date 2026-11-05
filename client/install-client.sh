#!/bin/bash
# Run as root on the Linux client whose /data and /etc should be backed up nightly (see docs/BACKUP.md):
#   sudo NAS=192.168.1.50 bash install-client.sh
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"; NAS=${NAS:?set NAS=<address of the My Cloud>}
command -v rsync >/dev/null || apt-get install -y rsync
sed "s/^NAS=.*/NAS=$NAS/" "$D/rsync-backup.sh" > /usr/local/sbin/rsync-backup.sh; chmod 755 /usr/local/sbin/rsync-backup.sh
install -m 644 "$D/rsync-data.service" "$D/rsync-data.timer" /etc/systemd/system/
[ -d /etc/needrestart/conf.d ] && install -m 644 "$D/needrestart-rsync-data.conf" /etc/needrestart/conf.d/rsync-data.conf
systemctl daemon-reload; systemctl enable --now rsync-data.timer
rsync --list-only "rsync://$NAS/backup/" >/dev/null && echo "NAS reachable, module 'backup' OK"
echo "INSTALL_OK; first run now:  systemctl start --no-block rsync-data.service ; journalctl -u rsync-data.service -f"
