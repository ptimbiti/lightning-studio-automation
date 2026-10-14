# Lightning Studio Automation

Keep a Lightning AI cloudspace awake on a schedule, run a daily agent job reliably despite auto-sleep, wake the machine remotely, and give the job a local memory brain. Built and running in production (since Oct 2026) on a **free-tier** Lightning studio with [Hermes Agent](https://hermes-agent.nousresearch.com).

## The platform facts that shape everything

- A studio auto-sleeps after **10 minutes** of inactivity. Extending/disabling that in the UI needs a paid plan.
- BUT **background execution counts as activity**: a running process keeps the studio awake.
- On the FREE tier, a machine awake continuously past **~4 hours flips to a PAID machine** (credit drain). Cap every keep-awake window well below that.
- When asleep, **nothing on the box runs** - not Hermes, not cron, not systemd. A scheduled job either fires during an awake window or needs (a) an external wake trigger, or (b) a catch-up-on-boot service.
- The OS user is NOT `root`/`zeus` - run `whoami` and set `User=` explicitly in every systemd unit.

## The architecture

```
07:35  GitHub Actions (external, free) starts the studio via Lightning API
07:30  keepalive window opens (systemd timer + script) -> holds machine awake
08:00  Hermes cron fires the morning digest (research -> gbrain -> Telegram)
11:15  window ends -> machine sleeps again, days before the 4h paid cliff
any boot: catch-up service fires the digest if today's run was missed
```

## Step 1 - Keep-awake service (time-boxed window)

Copy `scripts/keepalive.sh` to `/usr/local/bin/keepalive`, edit the window constants at the top (`PROJECT`, `WINDOW_START`, `WINDOW_END`, `TZDK`), then install the units in `systemd/` (replace `<user>` with `whoami`):

```bash
sudo install -m 755 scripts/keepalive.sh /usr/local/bin/keepalive
sudo cp systemd/keepalive.service systemd/keepalive.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now keepalive.timer
```

The timer runs the script every 5 minutes; the script itself decides whether a loop should be running (window math in local time via `TZ=`, never UTC wall time). A lockfile makes re-runs idempotent. The loop self-terminates at window end AND at a hard max-runtime below the 4h cliff.

Verify: `systemctl list-timers keepalive.timer` - and outside the window, confirm no loop process exists.

## Step 2 - Scheduled agent job + catch-up on boot (Hermes)

1. Create the job with a UTC cron schedule, `deliver=origin`, and - if users should be able to reply to a delivery - `attach_to_session` + `continuity`. The prompt must be **fully self-contained** (fresh session): absolute paths for every binary not on cron's PATH, explicit output format, and a completion marker: `touch ~/.hermes/cache/<job>-ran-$(date +%F)`.
2. Install `systemd/digest-catchup.service` (edit the job id + user). It fires on every studio boot: if today's marker is missing, it retry-loops `hermes cron run <job_id>` so the job fires shortly after whatever woke the machine.
3. Verify end to end: `hermes cron run <job_id>`, then check `hermes cron history`, the marker file, the saved artifact, and the delivery.

## Step 3 - Remote wake via GitHub Actions (free, no server needed)

When the machine is asleep nothing on it can wake it, so the trigger must live elsewhere. GitHub Actions works and costs nothing (~2 min/day).

1. Create a **private** repo with `templates/wake-workflow.yml` (edit your studio name / org / teamspace).
2. `gh auth login` (device flow), then `gh repo create studio-wake --private --source=. --push`.
3. Create a Lightning API key (lightning.ai -> avatar -> Settings -> API keys) and paste it **in your own browser** into repo Settings -> Secrets and variables -> Actions -> `LIGHTNING_API_KEY`. Never in chat.
4. Trigger once with `gh workflow run wake.yml` and check the log.

**Hard-won pitfalls**

- Pin the SDK version (`lightning-sdk==2026.10.13`): the API breaks between releases (the `cloud_account=` Studio kwarg existed in 2026.3.x, was **removed** by 2026.10.x).
- ALWAYS pin `machine` to the studio's current free value. `start()` from outside defaults to the paid DEFAULT machine - an unguarded call can boot a billed machine.
- Guard the call: only `start()` when `status == Status.Stopped` (Running => exit 0, anything else => exit without acting).
- Use `create_ok=False` so a typo'd identifier errors instead of silently creating a studio.
- GH cron drifts several minutes: schedule the wake 20-25 min before the deadline task, and use TWO UTC fires (e.g. `'35 5 * * *'` + `'35 6 * * *'`) so DST needs no manual patch - the Running guard makes the extra fire a no-op.
- GitHub disables scheduled workflows after ~60 days without commits - keep the monthly heartbeat-commit step.

**Discover your studio's identifiers** (run inside the studio):

```python
from lightning_sdk import Studio
s = Studio(create_ok=False)
print(s.name, s.teamspace.name, s.cloud_account, s.status)
# org is the first path segment of your lightning.ai studio URL
```

## Step 4 - gbrain as the job's memory

```bash
curl -fsSL https://bun.sh/install | bash          # bun >= 1.4 required
bun install -g github:garrytan/gbrain             # NEVER `npm i -g gbrain` (squatter package!)
gbrain init --pglite --no-embedding               # keyless, keyword search, all local
gbrain doctor --json                              # health check
echo "hello brain" | gbrain put hello-$$ && gbrain search hello   # round-trip test
```

Notes: bun's global bin may land outside `$HOME` (e.g. `/home/<user>/.cache/.bun/bin`) - resolve the absolute path and `export PATH` it inside every job prompt and systemd script; cron/systemd shells don't inherit your interactive PATH.

## License

MIT
