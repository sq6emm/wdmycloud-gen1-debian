# Nightly rsync snapshots from a Linux client

The NAS runs an rsync daemon (TCP 873, no SSH) with one module, `backup`, rooted at `/srv/data/backup`. A client
writes a snapshot into `backup/<host>/<stamp>.incomplete/` with `--link-dest=../latest`, then uploads an empty
`.complete` marker. The daemon's post-transfer hook (`/usr/local/sbin/rsync-finalize.sh`) renames the directory,
points `<host>/latest` at it and prunes: every snapshot from the last 14 days is kept, plus the first snapshot of
each month for 186 days. Unchanged files are hard links, so each snapshot costs only the changed data.

Why rsync and not NFS: on this CPU the per-file work of a nightly run is 3–5x faster when the comparison happens
locally on the NAS (measured on 97k files: 25 s vs 117 s to compare an unchanged tree, 123 s vs 444 s for a
`--link-dest` snapshot). Bulk transfers are a bit slower (15 vs 22 MB/s), which only matters for the first run.

## Client setup (Debian/Ubuntu, as root)

The `client/` directory holds `rsync-backup.sh` (backs up `/data` and `/etc`; edit the paths and excludes near
the top), a systemd service and a timer (01:00 UTC daily, catches up after downtime), and a `needrestart`
exclusion so an unattended upgrade does not kill a run in progress:

```sh
sudo NAS=<nas-ip-or-name> bash client/install-client.sh
sudo systemctl start --no-block rsync-data.service      # first full run; journalctl -u rsync-data.service -f
```

An interrupted run is resumed: the script reuses the newest `<stamp>.incomplete` on the NAS instead of
starting over. Expect roughly 15–25 MB/s for the first full copy and minutes for the nightly deltas; the nightly
comparison of a few million files takes about 20 minutes plus 20 minutes per million files for the hard links.

## Restoring

Snapshots are plain directories. From any machine on the LAN:

```sh
rsync -a rsync://<nas>/backup/<host>/latest/data/some/dir/ ./restored/
```

or on the NAS itself under `/srv/data/backup/<host>/`.

## Other clients

Anything that speaks the rsync protocol works (Windows: cwRsync; macOS: rsync from Homebrew). The finalize hook
works for any `<host>` directory name. Access is limited to private networks (`hosts allow` in
`/etc/rsyncd.conf`, and the firewall).
