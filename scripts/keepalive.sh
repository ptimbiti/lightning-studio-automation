#!/bin/bash
# Keep a Lightning studio awake during a daily window.
# Window math runs in local time (TZ-aware) - machines run UTC, never compare UTC wall time to a local window.
# The loop self-terminates at window end AND at a hard max-runtime below Lightning's ~4h free->paid cliff.
#
# Edit these four constants:
PROJECT="myproject"
WINDOW_START="07:30"          # local time, e.g. a bit before the scheduled job
WINDOW_END="11:15"            # local time
TZDK="Europe/Copenhagen"      # your timezone
MAX_RUNTIME=12600             # 3h30m hard cap in seconds - NEVER reach Lightning's ~4h paid flip
LOCK="/tmp/${PROJECT}-keepalive.pid"

now=$(date +%s)
start=$(TZ=$TZDK date -d "today $WINDOW_START" +%s)
end=$(TZ=$TZDK date -d "today $WINDOW_END" +%s)

if [ "$now" -lt "$start" ] || [ "$now" -ge "$end" ]; then
  # outside the window: make sure no loop is running
  if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    kill "$(cat "$LOCK")" 2>/dev/null
  fi
  rm -f "$LOCK"
  exit 0
fi

# inside the window: start the loop if not already running (idempotent)
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi

(
  echo $$ > "$LOCK"
  t0=$(date +%s)
  while :; do
    n=$(date +%s)
    if [ "$n" -ge "$end" ] || [ $((n - t0)) -ge $MAX_RUNTIME ]; then
      rm -f "$LOCK"
      exit 0
    fi
    # tiny activity blip - background execution counts as activity for Lightning
    head -c 1M /dev/urandom | sha256sum > /dev/null
    touch "${HOME}/.keepalive-activity"
    sleep 60
  done
) &
sleep 0.3
echo "keepalive started pid $(cat "$LOCK" 2>/dev/null)"
