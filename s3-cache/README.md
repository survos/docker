# Local S3 tiers on the Mac

Two bulk tiers, both reached over S3 so apps only change `S3_ENDPOINT`. No FUSE.

| Tier | What | Endpoint | Remote |
|---|---|---|---|
| **Origin, remote** | Hetzner Object Storage fsn1 (`survos-platform`, `museado`, `nabolom`, `loc-chronam`...) | `https://fsn1.your-objectstorage.com` | `hetzner:` |
| **Origin, local** | RustFS 1.0.0 on the WD Elements 5 TB (Case-sensitive APFS), same bucket/key layout as Hetzner | `http://127.0.0.1:9000` | `wd:` |
| **Cache → Hetzner** | `rclone serve s3 hetzner:`, SSD cache `~/platform/cache/s3`, 100G cap | `http://127.0.0.1:9100` | `s3cache:` |
| **Cache → WD** | `rclone serve s3 wd:`, SSD cache `~/platform/cache/s3-wd`, 60G cap | `http://127.0.0.1:9101` | `s3cache-wd:` |

Both caches download an object on its first read, serve later reads from the SSD, and evict least-recently-used
objects past their size cap or when the disk falls below 40G free. Writes pass through to the origin. AI result
sidecars must reach Hetzner, the only place mediary checks whether a task already ran.

```bash
s3-cache/install.sh     # (re)install both launchd agents + rclone remotes; keys in ~/.config/s3-cache/
rustfs/install.sh       # RustFS on the WD (see rustfs/README.md)
rustfs/vault-to-wd.sh mus/nabolom   # local vault subtree -> wd:survos-platform/vault/<path>, then rclone check
```

Symfony app: `.env.local` → `S3_ENDPOINT=http://127.0.0.1:9100` (or 9101) plus `AWS_S3_ACCESS_ID`/`SECRET` from
`~/.config/s3-cache/`. The S3 client already uses path-style addressing.

## Measured (2026-09-17)

- `survos-platform/vault/mus/fpus/ai/claims.jsonl`, 229 MB: cold through :9100 took 80 s (direct from Hetzner, 71 s);
  warm took 0.36 s. MD5 matched the local file. The cache survives a restart of the agent.
- RustFS on the WD handles about 70 small objects/s (21 MiB/s) and about 100 MB/s sequential.

## Caveats

- Size limits are checked once a minute, so a cache can briefly exceed its cap, and an open file can't be evicted.
- `serve s3` isn't a complete S3 implementation (no versioning or policies); harvest only needs read, write and list.
- Writes through a cache reach the origin shortly after, not immediately.
- RustFS keeps objects in its own format; the plain-file copies of Na Bolom are on the X10 and the T7.
