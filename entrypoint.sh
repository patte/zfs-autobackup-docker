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

# An ssh dir mounted at /ssh-host (SSH_DIR of the wrapper script) is copied to /root/.ssh
# This is necessary because ssh requires its config to be owned by root and we want to 
# write in our config options without editing the users own ssh config.
# Our config options win over the user's config as e.g. the user's agent socket doesn't exist in the container.
# Files mounted into /root/.ssh directly take precedence over the ssh dir.
import_ssh_dir() {
  local src=/ssh-host dst=/root/.ssh p marker="# ---- appended from the ssh dir by entrypoint.sh ----"
  [[ -d $src ]] || return 0
  if [[ ! -r $src || ! -x $src ]]; then
    log "error: cannot read $src, add --cap-add DAC_OVERRIDE when it's owned by another user"
    exit 1
  fi
  while IFS= read -r -d '' p; do
    if [[ ! -e $src/$p ]]; then
      log "warning: skipping $p, its symlink target is outside the ssh dir"
    elif mountpoint -q "$dst/$p"; then
      log "keeping the mounted $dst/$p, skipping $p of the ssh dir"
    elif [[ -d $src/$p ]]; then
      install -d -m 700 "$dst/$p"
    elif [[ $p == config ]]; then
      # everything above the marker is the image's config, so a restart replaces rather than appends
      { awk -v m="$marker" '$0 == m { exit } { print }' "$dst/config"; echo "$marker"; cat "$src/config"; } > "$dst/config.new"
      chmod 600 "$dst/config.new"
      mv "$dst/config.new" "$dst/config"
    else
      install -m 600 "$src/$p" "$dst/$p"
    fi
  done < <(cd "$src" && find -L . -mindepth 1 \( -type d -o -type f -o -type l \) -printf '%P\0')
}

import_ssh_dir

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
