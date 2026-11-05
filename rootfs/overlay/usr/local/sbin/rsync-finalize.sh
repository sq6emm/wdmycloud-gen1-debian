#!/bin/bash
# post-xfer hook of the rsync daemon (runs as root after each transfer into the "backup" module).
# A client marks a finished snapshot by uploading <stamp>.incomplete/.complete; this turns it into <stamp>,
# points "latest" at it and prunes old snapshots: keep 14 days, plus the first snapshot of each month for 186 days.
BASE=/srv/data/backup
KEEP_DAYS=14
KEEP_MONTHLY_DAYS=186
LOG=/var/log/rsync-finalize.log
exec >>"$LOG" 2>&1
for host in "$BASE"/*/; do
  host=${host%/}; [ -d "$host" ] || continue
  for inc in "$host"/????-??-??_????.incomplete; do
    [ -f "$inc/.complete" ] || continue
    final=${inc%.incomplete}
    rm -f "$inc/.complete"
    mv "$inc" "$final" && ln -sfn "$(basename "$final")" "$host/latest"
    echo "$(date '+%F %T') finalized $final (request: ${RSYNC_REQUEST:-?}, exit ${RSYNC_EXIT_STATUS:-?})"
    now=$(date +%s)
    for d in "$host"/????-??-??_????; do
      [ -d "$d" ] || continue
      n=$(basename "$d"); day=${n%_*}
      t=$(date -d "$day" +%s 2>/dev/null) || continue
      age=$(( (now - t) / 86400 ))
      first_of_month=$(ls -d "$host/${day%-*}"-??_???? 2>/dev/null | head -1)
      if [ "$age" -gt "$KEEP_MONTHLY_DAYS" ] || { [ "$age" -gt "$KEEP_DAYS" ] && [ "$d" != "$first_of_month" ]; }; then
        echo "$(date '+%F %T') prune $n (age ${age}d)"; rm -rf "$d"
      fi
    done
    echo "$(date '+%F %T') snapshots in $host: $(ls -d "$host"/????-??-??_???? 2>/dev/null | wc -l), used: $(df -h "$BASE" | awk 'NR==2{print $3" of "$2}')"
  done
done
exit 0
