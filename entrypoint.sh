#!/bin/bash
# Entrypoint for ghcr.io/patte/zfs-autobackup
#
# Default: exec zfs-autobackup "$@" (the container behaves like the binary,
# runs once and exits).
#
# Service mode (CRON_SCHEDULE set): keep running and execute
# zfs-autobackup "$@" on the given cron schedule via supercronic, e.g. for
# docker compose, TrueNAS Apps or Unraid.
#   RUN_ON_STARTUP=true        also run once immediately on start
#   PING_URL=https://...       healthchecks.io style monitoring: GET $PING_URL/start
#                              before a run, $PING_URL on success, $PING_URL/fail
#                              (with the last log lines as body) on failure
#   UNHEALTHY_AFTER_FAILURES   consecutive failed runs after which /healthcheck.sh
#                              reports unhealthy (default 2)
set -euo pipefail

if [[ -z "${CRON_SCHEDULE:-}" ]]; then
  exec zfs-autobackup "$@"
fi

log() { echo "[entrypoint] $*" >&2; }

job=/run/zfs-autobackup-job
{
  echo '#!/bin/bash'
  echo 'echo "[cron] zfs-autobackup run started at $(date -Is)"'
  echo '[[ -n "${PING_URL:-}" ]] && curl -fsS -m 10 --retry 3 -o /dev/null "$PING_URL/start" || true'
  echo 'log=/run/zfs-autobackup-last.log'
  printf 'zfs-autobackup'
  printf ' %q' "$@"
  echo ' 2>&1 | tee "$log"'
  echo 'rc=${PIPESTATUS[0]}'
  echo 'echo "$rc" > /run/last-exit-code'
  echo 'if [[ $rc -eq 0 ]]; then'
  echo '  echo 0 > /run/consecutive-failures'
  echo '  [[ -n "${PING_URL:-}" ]] && curl -fsS -m 10 --retry 3 -o /dev/null "$PING_URL" || true'
  echo 'else'
  echo '  n=$(( $(cat /run/consecutive-failures 2>/dev/null || echo 0) + 1 ))'
  echo '  echo "$n" > /run/consecutive-failures'
  echo '  [[ -n "${PING_URL:-}" ]] && tail -c 10000 "$log" | curl -fsS -m 10 --retry 3 -o /dev/null --data-binary @- "$PING_URL/fail" || true'
  echo 'fi'
  echo 'echo "[cron] zfs-autobackup run finished at $(date -Is) with exit code $rc"'
  echo 'exit $rc'
} > "$job"
chmod 700 "$job"
echo 0 > /run/consecutive-failures

if [[ "${RUN_ON_STARTUP:-false}" == "true" ]]; then
  log "RUN_ON_STARTUP=true, running zfs-autobackup now"
  "$job" || log "warning: startup run failed with exit code $?"
fi

echo "$CRON_SCHEDULE $job" > /run/crontab
log "starting scheduler with schedule '$CRON_SCHEDULE' for: zfs-autobackup $*"
exec supercronic -passthrough-logs /run/crontab
