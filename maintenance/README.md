# fsn1 container log cleanup

`container-log-cleanup.py` is installed at `/usr/local/sbin/container-log-cleanup`.
`container-log-cleanup.cron` is installed at `/etc/cron.d/container-log-cleanup`.
Every 15 minutes, unlimited `json-file` container logs over 100 MiB are truncated
in place, retaining up to 10 MiB of recent complete JSON records in the root-only
`/var/log/container-log-cleanup/<container-id>.json.log`. Each container has one
retained tail, replaced on its next cleanup; archives expire after seven days.
Containers with native size rotation are skipped. Nothing restarts containers,
prunes images/volumes, or touches database files. Dry run: invoke without `--apply`.
Execution summaries are in `journalctl -t container-log-cleanup`.

This is an interim safeguard for already-running PostgreSQL and RabbitMQ containers.
Docker advises against externally manipulating its log files; the proper permanent
solution is to configure `max-size: 10m` and `max-file: 3` on their source definitions
and recreate them during planned maintenance. Truncation can race a concurrent log
write, so a few messages around cleanup may be lost. Native rotation avoids this.
