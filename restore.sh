#!/usr/bin/env bash
#
# The other half of a backup: getting the data back. Run this from a machine that
# holds the age *private* key -- the backup service deliberately has only the public
# one, so it can write backups it cannot read.
#
#   docker run --rm -it --entrypoint restore.sh \
#     -e BACKUP_BUCKET -e BACKUP_ENDPOINT -e BACKUP_ACCESS_KEY_ID -e BACKUP_SECRET_ACCESS_KEY \
#     -v ~/.keys/project.age:/key:ro -e AGE_KEY_FILE=/key \
#     pg-s3-backup list
#
# See README.md for the full disaster-recovery runbook.
set -euo pipefail
# shellcheck source=common.sh
. /usr/local/bin/common.sh

usage() {
  cat <<'TXT'
restore.sh <command>

  list [daily|monthly]            what the off-site bucket holds
  into <key|latest> <target-url>  restore a dump into a database
  verify [key|latest]             restore into VERIFY_DATABASE_URL and count rows
  files                           copy the files back into the application's bucket

Needs the BACKUP_* credentials; everything that decrypts also needs AGE_KEY_FILE.
TXT
  exit "${1:-1}"
}

resolve_key() {
  local key="$1" line filter=()
  if [[ "$key" == "latest" ]]; then
    # Sorting by object key would order by the project name first and the timestamp
    # only second, so "latest" would quietly mean "alphabetically last project" in a
    # bucket holding more than one. Sort on the modification time instead, and narrow
    # to this project's dumps when a name is given.
    if [[ -n "${BACKUP_NAME:-}" ]]; then filter=(--include "*/$BACKUP_NAME-*"); fi
    line="$(rclone lsf --files-only --recursive --format tp --separator '|' \
      "${filter[@]}" "dest:$BACKUP_BUCKET/db/" | sort | tail -1)"
    [[ -n "$line" ]] || die "no dumps under db/${BACKUP_NAME:+ for $BACKUP_NAME}"
    key="db/${line#*|}"
    log "latest dump is $key"
  fi
  printf '%s' "$key"
}

# Streams a dump out of the bucket and decrypts it on the way past.
stream_dump() {
  require AGE_KEY_FILE
  [[ -r "$AGE_KEY_FILE" ]] || die "cannot read the private key at $AGE_KEY_FILE"
  rclone cat "dest:$BACKUP_BUCKET/$1" | age --decrypt --identity "$AGE_KEY_FILE"
}

cmd_list() {
  configure_dest
  rclone lsl "dest:$BACKUP_BUCKET/db/${1:-}"
}

cmd_into() {
  local key="$1" target="${2:-}"
  [[ -n "$target" ]] || usage
  configure_dest
  key="$(resolve_key "$key")"

  log "restoring $key into $(redact "$target")"
  # --clean --if-exists so a half-finished attempt can simply be repeated; without
  # it the second run drowns in "already exists" and hides the real errors.
  stream_dump "$key" |
    pg_restore --dbname="$target" --no-owner --no-privileges --clean --if-exists --exit-on-error
  log "restore ok"
}

cmd_verify() {
  local key="${1:-latest}" target="${VERIFY_DATABASE_URL:-}"
  [[ -n "$target" ]] || die "set VERIFY_DATABASE_URL to a scratch database (it gets wiped)"
  cmd_into "$key" "$target"

  # A restore that reports success but produces an empty schema is worth nothing,
  # so the drill ends by looking at what actually landed.
  log "row counts in the restored database:"
  psql "$target" --tuples-only --no-align --command "
    SELECT relname || ': ' || n_live_tup
    FROM pg_stat_user_tables
    WHERE n_live_tup > 0
    ORDER BY n_live_tup DESC
    LIMIT 20;"
}

cmd_files() {
  configure_dest
  configure_src
  log "copying files back into $SRC_BUCKET"
  # copy, not sync -- restoring must not delete anything that is already there.
  rclone copy --size-only --transfers 4 "dest:$BACKUP_BUCKET/files/" "src:$SRC_BUCKET"
  log "files ok"
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  into) shift; [[ $# -ge 2 ]] || usage; cmd_into "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  files) shift; cmd_files "$@" ;;
  -h | --help | help) usage 0 ;;
  *) usage ;;
esac
