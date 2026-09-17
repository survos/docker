# RustFS on the WD Elements (local S3)

Local S3 endpoint backed by the 5 TB WD Elements (`/Volumes/WD-001`, Case-sensitive APFS since 2026-09-17; S3 keys are case-sensitive, so the disk must be too).
Native binary under launchd, not podman: the podman VM can't see `/Volumes`.

| | |
|---|---|
| S3 API | `http://127.0.0.1:9000` (path-style only) |
| Console | `http://127.0.0.1:9001` |
| Data | `/Volumes/WD-001/rustfs` (RustFS on-disk format: one directory per object, not plain files) |
| Keys | `~/.config/rustfs/{access_key,secret_key}` |
| rclone remote | `wd:` |
| Log | `~/Library/Logs/rustfs.log` |

```bash
rustfs/install.sh                                   # install/upgrade (RUSTFS_VERSION=...)
launchctl kickstart -k gui/$(id -u)/org.survos.rustfs   # restart
launchctl bootout gui/$(id -u)/org.survos.rustfs        # stop
```

The agent only runs while `/Volumes/WD-001/rustfs` exists (launchd `PathState`), so an
unplugged WD never gets its data written to the internal disk. If the log shows
`Operation not permitted`, add `~/.local/bin/rustfs` to Full Disk Access.

Symfony apps: set `S3_ENDPOINT=http://127.0.0.1:9000` plus the keys in `.env.local`; the
`Aws\S3\S3Client` service already uses `use_path_style_endpoint: true`.

## Measured (2026-09-17)

2,000 vault JPEGs, 634 MiB, `--transfers 16`: PUT 29.6 s, GET 28.3 s, about 70 objects/s
and 21 MiB/s. Sequential writes to the drive run at about 100 MB/s. Small objects are the
slow case on a spinning disk, so put an SSD cache (an rclone mount with a VFS cache) in
front of it for AI work.
