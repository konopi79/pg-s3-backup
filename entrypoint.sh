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
printf '%s bash -c ". /etc/backup.env; /usr/local/bin/backup.sh" >> /proc/1/fd/1 2>&1\n' \
  "$SCHEDULE" >/etc/crontabs/root
log "${BACKUP_NAME:-backup}: schedule $SCHEDULE (TZ=$TZ)"

# A deploy immediately proves the whole chain works instead of leaving it to be
# discovered at 02:17 -- or, worse, on the day it is needed. It must not crash the
# service, though: one wrong credential would turn into a restart loop.
if [[ "${RUN_ON_START:-true}" == "true" ]]; then
  log "initial run"
  /usr/local/bin/backup.sh || log "initial run FAILED -- staying up, the cron will retry"
fi

exec crond -f -L /dev/stdout
