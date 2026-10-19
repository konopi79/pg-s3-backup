#!/usr/bin/env bash
#
# The drill from the README, automated: a real Postgres, a real S3 (SeaweedFS
# standing in for the off-site bucket), a real backup, and a real restore that is checked for
# rows. Runs in CI on every push, and locally with nothing but Docker:
#
#   ./test/e2e.sh 16
#
# It is end-to-end on purpose. The failures this repository has actually produced --
# a client major that dumps but cannot restore, an addressing style that answers with
# HTML, a log line landing in a captured object key -- are all invisible to a linter
# and all obvious the moment the chain is run whole.
set -euo pipefail

PG_MAJOR="${1:-16}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMAGE="pg-s3-backup:e2e-$PG_MAJOR"
NET="pgs3-e2e-$PG_MAJOR"
PG="pgs3-e2e-pg-$PG_MAJOR"
S3SRV="pgs3-e2e-s3-$PG_MAJOR"
WORK="$(mktemp -d)"

DEST_BUCKET=offsite
SRC_BUCKET=uploads
ROWS=20000
# Deliberately not "postgres": a restore that silently went to the wrong database
# would still pass a row count taken from the wrong database.
APP_DB=app
SCRATCH_DB=restore_check

S3_KEY=e2etestkey
S3_SECRET=e2etestsecret

# The fixtures are pinned, the subject under test is not. `postgres:$PG_MAJOR-bookworm`
# below is deliberately a moving tag: it is what the Dockerfile builds from, and this
# test exists to find out when that stops working. The S3 server is the opposite -- it
# only stands in for the off-site bucket, so a release of it landing on an unrelated
# commit has no business turning the build red. Bump these by hand, deliberately.
#
# SeaweedFS, not MinIO. MinIO first pulled its images from Docker Hub and then closed
# them on quay.io as well -- `unauthorized`, even for `:latest` -- and the drill went
# red for weeks on commits nobody made. Do not go back to it; there is nothing left
# to pull anonymously.
#
# The client is rclone's own image rather than the one under test: the checks below
# are the second opinion on what backup.sh wrote, and a second opinion that shares
# the binary -- and the version -- with the thing it is checking is not one.
S3_IMAGE=chrislusf/seaweedfs:4.48
RCLONE_IMAGE=rclone/rclone:1.75.2
S3_URL="http://$S3SRV:8333"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() {
  printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$PG" "$S3SRV" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Containers are up before they are ready, and every one of these has a different
# way of saying so. Retrying beats sleeping a guessed number of seconds.
wait_for() {
  local what="$1" tries=60
  shift
  for _ in $(seq 1 "$tries"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "$what never became ready"
}

# rclone against the fixture as remote `d:`; $WORK is /w inside, for uploads.
s3() {
  docker run --rm --network "$NET" -v "$WORK:/w" \
    -e RCLONE_CONFIG_D_TYPE=s3 -e RCLONE_CONFIG_D_PROVIDER=SeaweedFS \
    -e "RCLONE_CONFIG_D_ENDPOINT=$S3_URL" \
    -e "RCLONE_CONFIG_D_ACCESS_KEY_ID=$S3_KEY" -e "RCLONE_CONFIG_D_SECRET_ACCESS_KEY=$S3_SECRET" \
    "$RCLONE_IMAGE" "$@"
}

say "network"
docker network create "$NET" >/dev/null

say "postgres $PG_MAJOR"
docker run -d --name "$PG" --network "$NET" --network-alias postgres \
  -e POSTGRES_PASSWORD=postgres "postgres:$PG_MAJOR-bookworm" >/dev/null
wait_for postgres docker exec "$PG" pg_isready -U postgres

say "s3 (seaweedfs)"
# autoCreateBucket off: by default SeaweedFS creates a bucket on the first upload to
# it, which would make the pre-created destination below pass whether or not it
# existed -- and in production it has to.
docker run -d --name "$S3SRV" --network "$NET" \
  -e "AWS_ACCESS_KEY_ID=$S3_KEY" -e "AWS_SECRET_ACCESS_KEY=$S3_SECRET" \
  "$S3_IMAGE" mini -dir=/data -s3.autoCreateBucket=false >/dev/null
wait_for s3 s3 lsd d:

say "buckets"
# NO_CHECK_BUCKET is set in common.sh (the real token may not create buckets), so
# the destination has to exist beforehand -- exactly as in production.
s3 mkdir "d:$DEST_BUCKET"
s3 mkdir "d:$SRC_BUCKET"

say "seed: $ROWS rows and three uploaded files"
docker exec "$PG" psql -U postgres --quiet -c "CREATE DATABASE $APP_DB;"
docker exec "$PG" psql -U postgres -d "$APP_DB" --quiet -c "
  CREATE TABLE notes (id serial PRIMARY KEY, body text NOT NULL, at timestamptz DEFAULT now());
  INSERT INTO notes (body) SELECT md5(g::text) || repeat('x', 40) FROM generate_series(1, $ROWS) g;"
for n in 1 2 3; do printf 'upload %s\n' "$n" >"$WORK/file$n.txt"; done
s3 copy /w "d:$SRC_BUCKET" --include 'file?.txt'

say "build image (PG_MAJOR=$PG_MAJOR)"
docker build --quiet --build-arg "PG_MAJOR=$PG_MAJOR" -t "$IMAGE" "$ROOT" >/dev/null

say "age key pair"
docker run --rm --entrypoint age-keygen "$IMAGE" >"$WORK/key.age" 2>/dev/null
RECIPIENT="$(docker run --rm -v "$WORK:/w" --entrypoint age-keygen "$IMAGE" -y /w/key.age)"
[[ "$RECIPIENT" == age1* ]] || fail "age-keygen produced no recipient"

# The environment a deployed service gets, minus the cron: entrypoint.sh is skipped
# and backup.sh invoked directly, so the test does not wait for a schedule.
backup_env=(
  -e "BACKUP_NAME=e2e"
  -e "AGE_RECIPIENT=$RECIPIENT"
  -e "DATABASE_URL=postgresql://postgres:postgres@postgres:5432/$APP_DB"
  -e "BACKUP_BUCKET=$DEST_BUCKET"
  -e "BACKUP_ENDPOINT=$S3_URL"
  -e "BACKUP_ACCESS_KEY_ID=$S3_KEY"
  -e "BACKUP_SECRET_ACCESS_KEY=$S3_SECRET"
  -e BACKUP_PROVIDER=SeaweedFS
  -e BACKUP_REGION=us-east-1
  -e "S3_BUCKET=$SRC_BUCKET"
  -e "S3_ENDPOINT=$S3_URL"
  -e "S3_ACCESS_KEY=$S3_KEY"
  -e "S3_SECRET_KEY=$S3_SECRET"
)

say "backup"
docker run --rm --network "$NET" "${backup_env[@]}" --entrypoint backup.sh "$IMAGE"

say "check: what landed in the off-site bucket"
listing="$(s3 ls "d:$DEST_BUCKET")"
printf '%s\n' "$listing"

dumps="$(printf '%s\n' "$listing" | grep -c 'db/daily/e2e-.*\.dump\.age' || true)"
((dumps == 1)) || fail "expected exactly one dump under db/daily/, found $dumps"

for n in 1 2 3; do
  printf '%s\n' "$listing" | grep -q "files/file$n.txt" || fail "files/file$n.txt is missing"
done

key="$(s3 lsf --files-only --include '*.dump.age' "d:$DEST_BUCKET/db/daily")"
size="$(s3 lsf --format s "d:$DEST_BUCKET/db/daily/$key")"
((size >= 1024)) || fail "dump is only ${size} B -- that is the empty-dump case, not a backup"

say "check: the dump is encrypted, not merely uploaded"
# Fetched to a file rather than piped into grep: `rclone cat | grep -q` lets grep exit
# on the first hit, killing rclone with SIGPIPE, and under `pipefail` that non-zero status reads
# as "no plaintext found" -- a false clean bill of health on the one check that most
# needs to be honest.
s3 cat "d:$DEST_BUCKET/db/daily/$key" >"$WORK/dump.age"
header="$(head -c 21 "$WORK/dump.age")"
[[ "$header" == "age-encryption.org/v1" ]] ||
  fail "object does not start with an age header -- got '${header}'"
if grep -qa PGDMP "$WORK/dump.age"; then
  fail "plaintext pg_dump header found in the uploaded object"
fi

say "check: a failed run cannot become 'latest'"
# Nothing in the backup path deletes, so an earlier failure stays in the bucket
# forever -- newer, by modification time, than the good dump beside it. The size
# floor in resolve_key is the only thing standing between that and a restore.
printf 'age-encryption.org/v1\ntruncated\n' >"$WORK/runt.age"
s3 copyto /w/runt.age "d:$DEST_BUCKET/db/daily/e2e-29991231T235959Z.dump.age"

restore_env=(
  -e "BACKUP_NAME=e2e"
  -e "BACKUP_BUCKET=$DEST_BUCKET"
  -e "BACKUP_ENDPOINT=$S3_URL"
  -e "BACKUP_ACCESS_KEY_ID=$S3_KEY"
  -e "BACKUP_SECRET_ACCESS_KEY=$S3_SECRET"
  -e BACKUP_PROVIDER=SeaweedFS
  -e BACKUP_REGION=us-east-1
  -e AGE_KEY_FILE=/key
)
resolved="$(docker run --rm --network "$NET" "${restore_env[@]}" -v "$WORK/key.age:/key:ro" \
  --entrypoint restore.sh "$IMAGE" list 2>&1 || true)"
printf '%s\n' "$resolved" | grep -q "$key" || fail "restore list does not show $key"

say "restore into a scratch database"
docker exec "$PG" psql -U postgres --quiet -c "CREATE DATABASE $SCRATCH_DB;"
docker run --rm --network "$NET" "${restore_env[@]}" -v "$WORK/key.age:/key:ro" \
  -e "VERIFY_DATABASE_URL=postgresql://postgres:postgres@postgres:5432/$SCRATCH_DB" \
  --entrypoint restore.sh "$IMAGE" verify 2>&1 | tee "$WORK/verify.log"

grep -q 'restore ok' "$WORK/verify.log" ||
  fail "restore did not report success -- and 'latest' may have picked the runt"

say "check: the rows are actually there"
# Counted here rather than trusting verify's own output: n_live_tup comes from the
# statistics collector, so a restore that landed nothing and a restore whose stats
# have not caught up look the same. A count(*) does not.
restored="$(docker exec "$PG" psql -U postgres -d "$SCRATCH_DB" --tuples-only --no-align \
  -c 'SELECT count(*) FROM notes;' | tr -d '[:space:]')"
[[ "$restored" == "$ROWS" ]] || fail "restored $restored rows, expected $ROWS"

say "check: restoring files puts them back"
s3 deletefile "d:$SRC_BUCKET/file2.txt"
docker run --rm --network "$NET" "${restore_env[@]}" -v "$WORK/key.age:/key:ro" \
  -e "S3_BUCKET=$SRC_BUCKET" -e "S3_ENDPOINT=$S3_URL" \
  -e "S3_ACCESS_KEY=$S3_KEY" -e "S3_SECRET_KEY=$S3_SECRET" \
  --entrypoint restore.sh "$IMAGE" files
restored_files="$(s3 lsf "d:$SRC_BUCKET")"
grep -qx file2.txt <<<"$restored_files" ||
  fail "file2.txt was not restored into the application's bucket"

printf '\n\033[1;32mPASS\033[0m  pg%s: %s rows dumped, encrypted, uploaded, restored and counted\n' \
  "$PG_MAJOR" "$ROWS"
