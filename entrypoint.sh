#!/bin/bash
# Entrypoint for ghcr.io/patte/zfs-autobackup
#
# Default: exec zfs-autobackup "$@" (the container behaves like the binary,
# runs once and exits).
#
# Service mode (CRON_SCHEDULE set): keep running and execute
# zfs-autobackup "$@" on the given cron schedule via supercronic, e.g. for
# docker compose, TrueNAS Apps or Unraid. With RUN_ON_STARTUP=true one run is
# done immediately on start as well.
set -euo pipefail

if [[ -z "${CRON_SCHEDULE:-}" ]]; then
  exec zfs-autobackup "$@"
fi

log() { echo "[entrypoint] $*" >&2; }

job=/run/zfs-autobackup-job
{
  echo "#!/bin/bash"
  echo "echo \"[cron] zfs-autobackup run started at \$(date -Is)\""
  printf 'zfs-autobackup'
  printf ' %q' "$@"
  echo
  echo 'rc=$?'
  echo 'echo "[cron] zfs-autobackup run finished at $(date -Is) with exit code $rc"'
  echo 'exit $rc'
} > "$job"
chmod 700 "$job"

if [[ "${RUN_ON_STARTUP:-false}" == "true" ]]; then
  log "RUN_ON_STARTUP=true, running zfs-autobackup now"
  "$job" || log "warning: startup run failed with exit code $?"
fi

echo "$CRON_SCHEDULE $job" > /run/crontab
log "starting scheduler with schedule '$CRON_SCHEDULE' for: zfs-autobackup $*"
exec supercronic -passthrough-logs /run/crontab
