#!/bin/bash
# Entrypoint for ghcr.io/patte/zfs-autobackup
#
# Default: exec zfs-autobackup "$@" (the container behaves like the binary,
# runs once and exits).
#
# Service mode (CRON_SCHEDULE set): keep running and execute
# zfs-autobackup "$@" on the given cron schedule via supercronic, e.g. for
# docker compose, TrueNAS Apps or Unraid. Each run is done by
# /service-run.sh, which also handles PING_URL and the failure counter used
# by /healthcheck.sh.
#   RUN_ON_STARTUP=true        also run once immediately on start
#   PING_URL=https://...       healthchecks.io style monitoring, see service-run.sh
#   UNHEALTHY_AFTER_FAILURES   consecutive failed runs after which /healthcheck.sh
#                              reports unhealthy (default 2)
set -euo pipefail

if [[ -z "${CRON_SCHEDULE:-}" ]]; then
  exec zfs-autobackup "$@"
fi

log() { echo "[entrypoint] $*" >&2; }

# the arguments for every run, NUL separated so any argv survives unchanged
printf '%s\0' "$@" > /run/zfs-autobackup.args
echo 0 > /run/zfs-autobackup.failures

if [[ "${RUN_ON_STARTUP:-false}" == "true" ]]; then
  log "RUN_ON_STARTUP=true, running zfs-autobackup now"
  /service-run.sh || log "warning: startup run failed with exit code $?"
fi

echo "$CRON_SCHEDULE /service-run.sh" > /run/crontab
log "starting scheduler with schedule '$CRON_SCHEDULE' for: zfs-autobackup $*"
exec supercronic -passthrough-logs /run/crontab
