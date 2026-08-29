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

log() { echo "[entrypoint] $*" >&2; }

# The zfs userland in this image drives the host's kernel module over /dev/zfs. The
# module validates ioctl arguments against an allow-list of keys it knows, so a userland
# newer than the module can fail with "invalid argument" on zfs send. Older is safe.
zfs_userland_version=""
zfs_kmod_version=""
check_zfs_versions() {
  local versions
  versions=$(zfs version 2>/dev/null) || return 0
  zfs_userland_version=$(echo "$versions" | sed -n '1s/^zfs-\([0-9]\+\.[0-9]\+\).*/\1/p')
  zfs_kmod_version=$(echo "$versions" | sed -n '2s/^zfs-kmod-\([0-9]\+\.[0-9]\+\).*/\1/p')
  [[ -n $zfs_userland_version && -n $zfs_kmod_version ]] || return 0

  if [[ $zfs_userland_version != "$zfs_kmod_version" ]] &&
     [[ $(printf '%s\n%s\n' "$zfs_userland_version" "$zfs_kmod_version" | sort -V | tail -1) == "$zfs_userland_version" ]]; then
    log "warning: zfs userland $zfs_userland_version is newer than the host module $zfs_kmod_version, zfs send may fail with 'invalid argument'"
  fi
}

check_zfs_versions

if [[ -z "${CRON_SCHEDULE:-}" ]]; then
  exec zfs-autobackup "$@"
fi

if [[ -n $zfs_kmod_version ]]; then
  log "zfs userland $zfs_userland_version, host module $zfs_kmod_version"
fi

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
