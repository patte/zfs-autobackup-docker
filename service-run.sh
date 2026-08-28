#!/bin/bash
# One zfs-autobackup run in service mode (called by supercronic and for
# RUN_ON_STARTUP), with the arguments stored by entrypoint.sh.
#
# PING_URL (optional, healthchecks.io style, also understood by Uptime Kuma,
# Cronitor, ...): GET $PING_URL/start before the run, GET $PING_URL after a
# successful run, POST $PING_URL/fail with the last log lines after a failed one.
#
# State for /healthcheck.sh: /run/zfs-autobackup.last-exit-code and
# /run/zfs-autobackup.failures (consecutive failed runs).
set -uo pipefail

log=/run/zfs-autobackup.last.log
mapfile -d '' args < /run/zfs-autobackup.args

# ping <suffix> [curl args...]: request $PING_URL<suffix>, no-op without PING_URL
ping() {
  [[ -n "${PING_URL:-}" ]] || return 0
  local suffix=$1; shift
  curl -fsS -m 10 --retry 3 -o /dev/null "$@" "$PING_URL$suffix" || echo "[cron] warning: ping $PING_URL$suffix failed" >&2
}

echo "[cron] zfs-autobackup run started at $(date -Is)"
ping /start

zfs-autobackup "${args[@]}" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
echo "$rc" > /run/zfs-autobackup.last-exit-code

if [[ $rc -eq 0 ]]; then
  echo 0 > /run/zfs-autobackup.failures
  ping ""
else
  n=$(( $(cat /run/zfs-autobackup.failures 2>/dev/null || echo 0) + 1 ))
  echo "$n" > /run/zfs-autobackup.failures
  tail -c 10000 "$log" | ping /fail --data-binary @-
fi

echo "[cron] zfs-autobackup run finished at $(date -Is) with exit code $rc"
exit "$rc"
