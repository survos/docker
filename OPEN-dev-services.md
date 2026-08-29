# Open: finish moving dev services to on-demand

Follow-on to `DEV-SERVICES.md`. Everything below is decided-but-not-done, or needs
Tac's call. No urgency — the load problem itself is fixed.

## Deferred: the depot bundle (Tac is coming back to this)

`ai-tools` was stopped 2026-08-29 and needs nothing further -- ssai already surfaces it.
`Depot::$aiToolsReachable` is populated from depot's heartbeat, and
`photo_scanner_controller.js` turns that into a red `ai-tools down` badge *and* disables
Start Scanning. It blocks rather than warns on purpose: crop/deskew has no automatic
retry, and a batch scanned with ai-tools down had to be re-triggered image by image.

Restart it on the depot machine with:

    cd ~/sites/ai-tools && uv run python -m uvicorn main:app --host 127.0.0.1 --port 8884

**Small gap:** that command does not appear anywhere in the UI. The tooltip says "start it
before scanning" without saying how, so whoever hits it has to go find the incantation.
Worth putting the literal command in the badge title -- but it runs on the depot box, not
the hub showing the message, so the wording has to make that clear.

## Needs a decision: the rest of the depot bundle

These four run continuously and are only useful while actively developing depot. They
were NOT touched, because `depot-scan-worker` drives physical hardware (the FF-680W)
and disabling it silently breaks scanning.

| unit / process | what it is | cost |
|---|---|---|
| `ai-tools` uvicorn :8884 | **stopped 2026-08-29** -- ssai reports it down and blocks Start Scanning | was ~1.5 GB RSS |
| `depot-scan-worker.service` | scan_jobs consumer, drives the FF-680W | idle-ish |
| `depot-scheduler.service` | depot scheduler | idle-ish |
| `cloudflared-depot-lemur-pro.service` | tunnel for lemur-pro.scanstationai.work | idle-ish |
| `ssai-depot-events.service` | **already disabled 2026-08-29** — was crash-looping, 252 restarts/hr | was ~14% of a core |

Proposal: one `depot-dev.target` that pulls in all four, so the bundle starts and stops
as a unit:

    systemctl --user start depot-dev.target    # developing depot
    systemctl --user stop  depot-dev.target    # done

and `systemctl --user disable` each one individually so none come back at login. The
ai-tools uvicorn would need a unit file first — it has none today, which is why it is
invisible to `systemctl` and just runs until the laptop reboots.

Open question for Tac: is the scan station expected to work at any time without you
first starting it deliberately? If yes, `depot-scan-worker` and the cloudflared tunnel
stay enabled and only ai-tools moves.

## Same class, not yet done

- `mariadb` and `mercure` in `~/sites/docker/docker-compose.yaml` are already excluded
  from `dev-docker-stack.service`, but a bare `docker compose up -d` still starts them.
  They are candidates for `profiles: ["ondemand"]` the same way grist now is. mariadb
  backs the local WordPress sites (survos, ff, kpa, pgsc), so it is a real judgment call
  rather than an obvious win.
- Other long-lived stacks seen running with nothing using them: `deploy` (openfoto, 5
  containers), `depot_imgproxy`, `imgproxy_pro_local`, `civic`. Worth an audit pass with
  `dstacks` to decide which are genuinely needed at login.

## Hardening, cheap and general

Audit every `Restart=always` user unit for a start limit, so a missing dependency can
never again turn into an infinite restart loop:

    grep -L StartLimitBurst $(grep -l 'Restart=always' ~/.config/systemd/user/*.service)

Add to any that come back:

    StartLimitIntervalSec=300
    StartLimitBurst=5

This is the generalization of the `ssai-depot-events` bug: stopping Docker created CPU
load instead of freeing it, because a service that needed Redis kept rebooting a PHP
kernel every 3 seconds.
