#!/bin/bash
# Snapshot backup of /data and /etc (power) to the WD My Cloud over the rsync protocol (daemon on the NAS, TCP 873).
# Layout on the NAS: /srv/data/backup/power/<YYYY-MM-DD_HHMM>/{data,etc} and power/latest -> newest snapshot.
# A run writes into <stamp>.incomplete/ with --link-dest=../latest, then uploads a .complete marker; the daemon's
# post-xfer hook (rsync-finalize.sh on the NAS) renames the directory, moves "latest" and applies retention.
# An interrupted run is resumed: if an .incomplete snapshot exists on the NAS, it is reused instead of starting over.
set -uo pipefail
NAS=${NAS:-nas}            # address or name of the WD My Cloud
MOD=rsync://$NAS/backup/power
STAMP=$(date +%Y-%m-%d_%H%M)

old=$(rsync --list-only "$MOD/" 2>/dev/null | awk '{print $NF}' | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}\.incomplete$' | sort | tail -1)
if [ -n "$old" ]; then
  STAMP=${old%.incomplete}; echo "resuming interrupted snapshot $old"
fi
DEST="$MOD/$STAMP.incomplete"
echo "=== $(date '+%F %T') rsync -> $DEST (link-dest: ../latest if it exists)"
rsync -aH --mkpath --numeric-ids --delete --delete-excluded --stats --link-dest=../latest \
  --exclude /data/lost+found --exclude /data/systemvar/cache --exclude /data/systemvar/tmp \
  /data "$DEST/" 2>&1 | tail -16
rc1=${PIPESTATUS[0]}
rsync -aH --mkpath --numeric-ids --delete --stats --link-dest=../latest /etc "$DEST/" 2>&1 | tail -3
rc2=${PIPESTATUS[0]}
# rsync rc 23/24 = some files vanished or unreadable (warnings), still a usable snapshot
if [ "$rc1" -le 24 ] && [ "$rc2" -le 24 ]; then
  m=$(mktemp -d); : > "$m/.complete"
  if rsync -a "$m/.complete" "$DEST/"; then
    echo "=== $(date '+%F %T') snapshot OK: $STAMP (rc data=$rc1 etc=$rc2), finalized by the NAS"
  else
    echo "=== $(date '+%F %T') snapshot data OK but the .complete marker could not be uploaded; will be finalized next run"; rm -rf "$m"; exit 1
  fi
  rm -rf "$m"
else
  echo "=== $(date '+%F %T') snapshot FAILED (rc data=$rc1 etc=$rc2), left as $STAMP.incomplete for resume"; exit 1
fi
echo "=== $(date '+%F %T') done; snapshots on NAS:"; rsync --list-only "$MOD/" | awk '{print "  "$NF}' | grep -v '^  \.$'
