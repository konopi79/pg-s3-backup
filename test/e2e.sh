#!/usr/bin/env bash
#
# The drill from the README, automated: a real Postgres, a real S3 (MinIO standing
# in for the off-site bucket), a real backup, and a real restore that is checked for
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
MINIO="pgs3-e2e-minio-$PG_MAJOR"
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
# test exists to find out when that stops working. MinIO is the opposite -- it only
# stands in for the off-site bucket, so a release of it landing on an unrelated commit
# has no business turning the build red. Bump these by hand, deliberately.
#
# From quay.io, not Docker Hub. MinIO removed `minio/minio` and `minio/mc` from Hub
# -- both are a flat 404 there, not a missing tag -- and the drill went red on a
# commit nobody made. The same pinned releases are still published on quay.io, so
# this is a registry change and not a version bump: quay.io serves the MinIO
# release under sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e,
# the same digest the last green Hub pull reported. Do not shorten these back to
# the Hub names; there is nothing left there to pull.
MINIO_IMAGE=quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z
MC_IMAGE=quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() {
  printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$PG" "$MINIO" >/dev/null 2>&1 || true
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

mc() { docker run --rm --network "$NET" --entrypoint sh "$MC_IMAGE" -c "$1"; }
MC_ALIAS="mc alias set d http://$MINIO:9000 $S3_KEY $S3_SECRET >/dev/null"

say "network"
docker network create "$NET" >/dev/null

say "postgres $PG_MAJOR"
docker run -d --name "$PG" --network "$NET" --network-alias postgres \
  -e POSTGRES_PASSWORD=postgres "postgres:$PG_MAJOR-bookworm" >/dev/null
wait_for postgres docker exec "$PG" pg_isready -U postgres

say "minio"
docker run -d --name "$MINIO" --network "$NET" \
  -e "MINIO_ROOT_USER=$S3_KEY" -e "MINIO_ROOT_PASSWORD=$S3_SECRET" \
  "$MINIO_IMAGE" server /data >/dev/null
wait_for minio mc "$MC_ALIAS"

say "buckets"
# NO_CHECK_BUCKET is set in common.sh (the real token may not create buckets), so
# the destination has to exist beforehand -- exactly as in production.
mc "$MC_ALIAS && mc mb -p d/$DEST_BUCKET d/$SRC_BUCKET"

say "seed: $ROWS rows and three uploaded files"
docker exec "$PG" psql -U postgres --quiet -c "CREATE DATABASE $APP_DB;"
docker exec "$PG" psql -U postgres -d "$APP_DB" --quiet -c "
  CREATE TABLE notes (id serial PRIMARY KEY, body text NOT NULL, at timestamptz DEFAULT now());
  INSERT INTO notes (body) SELECT md5(g::text) || repeat('x', 40) FROM generate_series(1, $ROWS) g;"
for n in 1 2 3; do printf 'upload %s\n' "$n" >"$WORK/file$n.txt"; done
docker run --rm --network "$NET" -v "$WORK:/w" --entrypoint sh "$MC_IMAGE" \
  -c "$MC_ALIAS && mc cp /w/file1.txt /w/file2.txt /w/file3.txt d/$SRC_BUCKET/" >/dev/null

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
  -e "BACKUP_ENDPOINT=http://$MINIO:9000"
  -e "BACKUP_ACCESS_KEY_ID=$S3_KEY"
  -e "BACKUP_SECRET_ACCESS_KEY=$S3_SECRET"
  -e BACKUP_PROVIDER=Minio
  -e BACKUP_REGION=us-east-1
  -e "S3_BUCKET=$SRC_BUCKET"
  -e "S3_ENDPOINT=http://$MINIO:9000"
  -e "S3_ACCESS_KEY=$S3_KEY"
  -e "S3_SECRET_KEY=$S3_SECRET"
)

say "backup"
docker run --rm --network "$NET" "${backup_env[@]}" --entrypoint backup.sh "$IMAGE"

say "check: what landed in the off-site bucket"
listing="$(mc "$MC_ALIAS && mc ls --recursive d/$DEST_BUCKET")"
printf '%s\n' "$listing"

dumps="$(printf '%s\n' "$listing" | grep -c 'db/daily/e2e-.*\.dump\.age' || true)"
((dumps == 1)) || fail "expected exactly one dump under db/daily/, found $dumps"

for n in 1 2 3; do
  printf '%s\n' "$listing" | grep -q "files/file$n.txt" || fail "files/file$n.txt is missing"
done

key="$(mc "$MC_ALIAS && mc find d/$DEST_BUCKET --name '*.dump.age' --print '{base}'" | tr -d '\r')"
size="$(mc "$MC_ALIAS && mc stat --json d/$DEST_BUCKET/db/daily/$key" |
  docker run --rm -i --entrypoint jq "$IMAGE" -r '.size')"
((size >= 1024)) || fail "dump is only ${size} B -- that is the empty-dump case, not a backup"

say "check: the dump is encrypted, not merely uploaded"
# Fetched to a file rather than piped into grep: `mc | grep -q` lets grep exit on the
# first hit, killing mc with SIGPIPE, and under `pipefail` that non-zero status reads
# as "no plaintext found" -- a false clean bill of health on the one check that most
# needs to be honest.
mc "$MC_ALIAS && mc cat d/$DEST_BUCKET/db/daily/$key" >"$WORK/dump.age"
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
docker run --rm --network "$NET" -v "$WORK:/w" --entrypoint sh "$MC_IMAGE" \
  -c "$MC_ALIAS && mc cp /w/runt.age d/$DEST_BUCKET/db/daily/e2e-29991231T235959Z.dump.age" >/dev/null

restore_env=(
  -e "BACKUP_NAME=e2e"
  -e "BACKUP_BUCKET=$DEST_BUCKET"
  -e "BACKUP_ENDPOINT=http://$MINIO:9000"
  -e "BACKUP_ACCESS_KEY_ID=$S3_KEY"
  -e "BACKUP_SECRET_ACCESS_KEY=$S3_SECRET"
  -e BACKUP_PROVIDER=Minio
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
mc "$MC_ALIAS && mc rm d/$SRC_BUCKET/file2.txt" >/dev/null
docker run --rm --network "$NET" "${restore_env[@]}" -v "$WORK/key.age:/key:ro" \
  -e "S3_BUCKET=$SRC_BUCKET" -e "S3_ENDPOINT=http://$MINIO:9000" \
  -e "S3_ACCESS_KEY=$S3_KEY" -e "S3_SECRET_KEY=$S3_SECRET" \
  --entrypoint restore.sh "$IMAGE" files
mc "$MC_ALIAS && mc ls d/$SRC_BUCKET" | grep -q file2.txt ||
  fail "file2.txt was not restored into the application's bucket"

printf '\n\033[1;32mPASS\033[0m  pg%s: %s rows dumped, encrypted, uploaded, restored and counted\n' \
  "$PG_MAJOR" "$ROWS"
