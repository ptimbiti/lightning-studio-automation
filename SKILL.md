---
name: lightning-ai-studio-automation
version: 1.0.0
description: "Use when automating a Lightning studio: sleep, wake, jobs."
author: priscillatimbiti
license: MIT
metadata:
  hermes:
    tags: [lightning-ai, systemd, cron, github-actions, gbrain]
    related_skills: [gstack-setup-gbrain]
---
# Lightning AI Studio Automation

Automating a hibernating cloud dev box: keep-awake windows, scheduled agent jobs, remote wake, and agent-memory (gbrain) integration. Built for Priscilla's Hermes-on-Lightning setup but the platform rules are general.

## When to Use

Keep-awake or wake-on-schedule for a Lightning cloudspace; daily agent jobs (digests, reports) that must survive auto-sleep; remote studio start via the SDK; attaching a local gbrain to jobs running on the box. Also when a scheduled job silently didn't fire - the machine was probably asleep.

## Platform facts that shape every design

- A studio auto-sleeps after 10 min of inactivity; extending or disabling that in the UI needs a paid plan. BUT background execution counts as activity: a running process keeps the studio awake.
- On the FREE tier, a machine that stays awake continuously past ~4 hours flips to a PAID machine (credit drain). Cap every keep-awake window well below that and let the machine sleep between windows.
- When asleep, NOTHING on the box runs - not Hermes, not its cron jobs, not systemd. So a scheduled job either fires during an awake window or needs (a) an external wake trigger, or (b) a catch-up-on-boot service.
- The OS user is NOT `zeus`/`root` - check `whoami` and set `User=` explicitly in every systemd unit.

## Step 1 - Keep-awake service (time-boxed window)

1. Write a script to `/usr/local/bin/<project>-keepalive`: compute the window in the user's timezone (`TZ=Europe/Copenhagen date -d "today 07:30" +%s` - machines run UTC, never compare UTC wall time to a local window), exit if outside it, otherwise start a background loop that self-terminates at window end AND at a hard max-runtime (below the 4h cliff), doing a tiny activity blip every 60s (`head -c 1M /dev/urandom | sha256sum` + touch a file). A lockfile makes re-runs idempotent.
2. Pair it with a systemd oneshot service + timer (`OnCalendar=*-*-* *:0/5`, `Persistent=true`) that runs the script every 5 min - the script itself decides whether a loop should be running. `sudo systemctl enable --now <name>.timer`.
3. Verify: `systemctl list-timers <name>.timer`, and outside the window confirm no loop process exists.

Pitfall: never run a 24/7 keepalive on a free machine - it walks straight into the paid flip. Window math belongs in the script, not in the timer, so DST is handled by the TZ-aware date math.

## Step 2 - Scheduled agent job + catch-up on boot

1. Create the Hermes cron job (`cronjob_manage` or `hermes cron create`) with a UTC cron schedule, `deliver=origin`, `attach_to_session=true` and `continuity=true` when the user should be able to reply to a delivery and refine it. Note: 1h of DST drift vs the user's local time - either schedule dual UTC fires or patch the schedule at the DST switch and tell the user.
2. The job's prompt must be fully self-contained (fresh session): absolute paths for every binary not on cron's PATH, explicit output format, and a completion marker: `touch ~/.hermes/cache/<job>-ran-$(date +%F)`.
3. Add a systemd oneshot service (`WantedBy=multi-user.target`, `User=<whoami>`) that runs on every studio boot: if today's marker file is missing, retry-loop `hermes cron run <job_id>` (every 30s, bounded) so the job fires shortly after whatever woke the machine. This is what makes morning jobs reliable despite sleep.
4. Verify end to end by running the job once on demand (`hermes cron run`) and checking: run history `hermes cron history`, marker file exists, memory artifact saved, delivery received.

Pitfall: a wrong `User=` in the unit passes `daemon-reload` and fails only at boot - check `systemctl show <unit> -p User` against `whoami` immediately.

## Step 3 - Remote wake (external trigger)

Before designing around an "always-on server" (user's VPS, partner's infra), PROBE it from the studio: `timeout 8 ssh -o BatchMode=yes -o ConnectTimeout=5 <host> true` and a `/dev/tcp/<ip>/<port>` bash probe for the service ports. Infra migrates; stale memory of a reachable box produces unbuildable plans. If nothing external is reachable, use GitHub Actions (free, no server):

1. Repo contains one workflow (see `templates/wake-workflow.yml`): scheduled UTC crons + `workflow_dispatch`, installs `lightning-sdk`, runs the wake script with a `LIGHTNING_API_KEY` secret.
2. The wake script: `Studio(name=..., org=..., teamspace=..., cloud_account=..., create_ok=False)` - `create_ok=False` so a bad identifier errors instead of silently creating a studio. Guard: only call `start()` when `status == Status.Stopped` (Running => exit 0; anything else => exit without acting).
3. Pin the SDK version in the workflow (`pip install lightning-sdk==2026.10.13`) - the API breaks between releases: the `cloud_account=` Studio kwarg existed in 2026.3.x and was REMOVED by 2026.10.x (newer versions resolve the cloud account from the teamspace default). ALWAYS pin `machine` to the studio's current free value (`start()` called from outside a studio defaults to the paid DEFAULT machine - an unguarded call can boot a billed machine). Discover current values from inside the running studio (`s = Studio(create_ok=False)`, read `s.cloud_account`; the `.machine` property may raise on non-default cloud accounts - walk the studio API object recursively for machine-like strings instead).
4. User does the secret in their own browser (repo Settings -> Actions secrets), never in chat. Test with a `workflow_dispatch` run (`gh workflow run`), then confirm from the studio (log shows status + guard decision / uptime jump).
4b. Headless GitHub auth: `gh auth login --hostname github.com --git-protocol https --web` in a background pty, `submit` Enter, relay the one-time code to the user to approve at github.com/login/device. The fnm_multishells symlink error at startup is harmless noise. SSH deploy keys (push access) canNOT create repos or secrets - API auth is required.
5. GitHub disables scheduled workflows after ~60 days without commits - include a monthly heartbeat-commit step in the workflow.
6. GH cron drifts several minutes: schedule the wake 20-25 min before the deadline task, and use TWO UTC fires (e.g. `'35 5 * * *'` + `'35 6 * * *'`) so DST needs no manual patch; the script's Running guard makes the extra fire a no-op.

## Step 4 - gbrain as the job's memory

- Install: bun >= 1.4 (`curl -fsSL https://bun.sh/install | bash`), then `bun install -g github:garrytan/gbrain`. NEVER `npm install -g gbrain` - that npm package is an unrelated squatter.
- Init keyless: `gbrain init --pglite --no-embedding` (no API key needed; search is keyword-only). Health: `gbrain doctor --json`. Round-trip test: `echo test | gbrain put slug-$$` then `gbrain search test`.
- bun's global bin may land outside `$HOME` (e.g. `/home/<user>/.cache/.bun/bin`) - resolve the absolute gbrain path and `export PATH` it inside every job prompt/systemd script; cron and systemd shells do not inherit the interactive PATH.
- Save: `cat notes.md | gbrain put "<slug>"`; retrieve: `gbrain search "<query>"`. Writes need no keys; keyless brains keep everything local.

## Job conventions for Priscilla

- Digest-style jobs: surprise with rotating topics (voice AI/TTS first as wildcard pairing), full notes to gbrain before delivering, final response IS the deliverable: <=250 words English, why-it-matters framing, source links, end with 2-3 refinement questions she answers by replying to the digest.
- She is on the free tier with near-zero credits: default to designs where the machine sleeps when not needed; never add always-on load.
- She prefers step-by-step browser instructions for anything outside the terminal; secrets pass only through forms she fills herself.
