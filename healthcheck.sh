#!/bin/bash
# Docker healthcheck. Only meaningful in service mode (CRON_SCHEDULE set):
# unhealthy when the scheduler is gone or the last UNHEALTHY_AFTER_FAILURES
# (default 2) runs in a row failed. Always healthy in one-shot mode.
[[ -f /run/crontab ]] || exit 0
pgrep -f supercronic >/dev/null || { echo "supercronic not running"; exit 1; }
n=$(cat /run/consecutive-failures 2>/dev/null || echo 0)
if (( n >= ${UNHEALTHY_AFTER_FAILURES:-2} )); then
  echo "last $n zfs-autobackup runs failed (exit code $(cat /run/last-exit-code 2>/dev/null))"
  exit 1
fi
exit 0
