#!/usr/bin/env bash
#
# One backup run: an age-encrypted Postgres dump plus a copy of the application's
# S3 bucket, both pushed to a bucket at another provider. See README.md.
#
# Nothing here deletes anything. Retention is a lifecycle rule on the destination
# bucket, so neither a bug nor a stolen token running this script can shorten
# history.
set -euo pipefail
# shellcheck source=common.sh
. /usr/local/bin/common.sh

require BACKUP_NAME AGE_RECIPIENT

# Both halves are on by default and each is turned off *explicitly*. Skipping one
# because its configuration happens to be absent is how a backup silently stops
# covering the data it is trusted to cover.
DO_DATABASE="${BACKUP_DATABASE:-true}"
DO_FILES="${BACKUP_FILES:-true}"
[[ "$DO_DATABASE" == "true" || "$DO_FILES" == "true" ]] ||
  die "BACKUP_DATABASE and BACKUP_FILES are both off -- nothing to do"

configure_dest
if [[ "$DO_DATABASE" == "true" ]]; then require DATABASE_URL; fi
if [[ "$DO_FILES" == "true" ]]; then configure_src; fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
# The first of the month is kept for a year, every other day for a fortnight --
# both by lifecycle rules keyed on this prefix.
TIER="daily"
if [[ "$(date '+%d')" == "01" ]]; then TIER="monthly"; fi

backup_database() {
  local key="db/$TIER/$BACKUP_NAME-$STAMP.dump.age" size
  local -a stages
  log "database -> $key"

  # -Fc so pg_restore can go table by table; age so the storage provider -- and
  # this container, which only ever holds the public key -- cannot read the names,
  # e-mails, phone numbers and password hashes inside.
  pg_dump --format=custom --compress=9 --no-owner --no-privileges "$DATABASE_URL" |
    age --recipient "$AGE_RECIPIENT" |
    rclone rcat "dest:$BACKUP_BUCKET/$key"

  # Checked by hand, because `set -e` does not fire here: this function is called
  # inside an `||` list, which disables it for the whole body. Without this a
  # pg_dump that died halfway would upload a truncated dump and, being over the
  # size floor below, pass for a good one.
  stages=("${PIPESTATUS[@]}")
  # `return`, not `die`: the files half and the failure ping still have to happen.
  ((stages[0] == 0)) || { log "pg_dump failed (exit ${stages[0]})"; return 1; }
  ((stages[1] == 0)) || { log "age failed (exit ${stages[1]})"; return 1; }
  ((stages[2] == 0)) || { log "upload failed (exit ${stages[2]})"; return 1; }

  # And an empty object is the other silent failure: the pipe produces one anyway.
  size="$(rclone size --json "dest:$BACKUP_BUCKET/$key" | jq -r '.bytes')"
  ((size >= 1024)) || { log "uploaded dump is only ${size} B"; return 1; }
  log "database ok (${size} B)"
}

backup_files() {
  log "files -> files/"
  # copy, never sync: an object deleted in production must not disappear here --
  # that deletion is the exact case this backup exists for. Application upload keys
  # are normally unique per upload and never rewritten, so comparing sizes settles
  # it without downloading anything.
  rclone copy --size-only --transfers 4 "src:$SRC_BUCKET" "dest:$BACKUP_BUCKET/files/"
  log "files ok"
}

failed=0
if [[ "$DO_DATABASE" == "true" ]]; then
  backup_database || { log "database FAILED"; failed=1; }
else
  log "database skipped (BACKUP_DATABASE=$DO_DATABASE)"
fi
if [[ "$DO_FILES" == "true" ]]; then
  backup_files || { log "files FAILED"; failed=1; }
else
  log "files skipped (BACKUP_FILES=$DO_FILES)"
fi

# A dead man's switch, off-platform on purpose: if this container is gone
# altogether, only something outside it can notice that no ping arrived.
if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
  url="$HEALTHCHECK_URL"
  if ((failed)); then url="$HEALTHCHECK_URL/fail"; fi
  curl -fsS -m 10 --retry 3 -o /dev/null "$url" || log "warn: heartbeat ping failed"
fi

if ((failed)); then exit 1; fi
log "backup complete"
