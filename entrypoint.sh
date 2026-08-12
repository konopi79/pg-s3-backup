#!/usr/bin/env bash
#
# Starts the backup cron. See README.md.
set -euo pipefail
# shellcheck source=common.sh
. /usr/local/bin/common.sh

# crond hands its jobs a near-empty environment, so the variables the platform links
# into this container (DATABASE_URL, the S3 credentials, the destination token) have
# to be passed on explicitly.
export -p >/etc/backup.env
chmod 600 /etc/backup.env

SCHEDULE="${BACKUP_CRON:-17 2 * * *}"
# /etc/cron.d entries carry a user field, and the job's output is redirected to
# PID 1's stdout so it lands in the platform's log rather than in a syslog daemon
# this image does not run. Sourcing the env file also restores PATH -- cron's own
# is too narrow to contain pg_dump.
printf 'CRON_TZ=%s\n%s root bash -c ". /etc/backup.env; /usr/local/bin/backup.sh" >> /proc/1/fd/1 2>&1\n' \
  "${TZ:-UTC}" "$SCHEDULE" >/etc/cron.d/backup
chmod 0644 /etc/cron.d/backup
log "${BACKUP_NAME:-backup}: schedule $SCHEDULE (TZ=$TZ)"

# A deploy immediately proves the whole chain works instead of leaving it to be
# discovered at 02:17 -- or, worse, on the day it is needed. It must not crash the
# service, though: one wrong credential would turn into a restart loop.
#
# Retried, because a container can be running before the cluster's DNS knows about
# its neighbours: the database hostname failed to resolve on some starts and not
# others, seconds apart, with nothing else changed. Only the last attempt may report
# a *failure*, so a slow start does not show up as a failed backup -- but every
# attempt reports its success, whichever one gets there.
if [[ "${RUN_ON_START:-true}" == "true" ]]; then
  tries="${START_RETRIES:-5}"
  for attempt in $(seq 1 "$tries"); do
    log "initial run (attempt $attempt/$tries)"
    if ((attempt < tries)); then
      if HEARTBEAT_ON_FAILURE=false /usr/local/bin/backup.sh; then break; fi
      log "attempt $attempt failed, retrying in ${START_RETRY_DELAY:-15}s"
      sleep "${START_RETRY_DELAY:-15}"
    else
      /usr/local/bin/backup.sh || log "initial run FAILED -- staying up, the cron will retry"
    fi
  done
fi

exec cron -f
