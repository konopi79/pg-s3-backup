#!/usr/bin/env bash
#
# Shared by backup.sh and restore.sh. Both talk to the same two buckets, and a
# remote configured one way for writing and another way for reading is a bug that
# only shows up on the day of a restore -- so the configuration lives in one place.

# Smallest plausible dump. A pg_dump that produced nothing still yields an object
# -- age's header over an empty input is about 200 bytes -- so this is the line
# between "a backup" and "a file". Used when writing one and again when reading
# one back, since a failed run stays in the bucket forever: nothing here deletes.
MIN_DUMP_BYTES="${MIN_DUMP_BYTES:-1024}"

# Logs go to stderr, always: some of these functions return a value on stdout, and
# a log line landing in a captured result produces a corrupt object key rather than
# an error. (It did, the first time this was rehearsed.)
log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

die() {
  log "FATAL $*"
  exit 1
}

# A connection URL carries the password; logs must never repeat it back.
redact() { printf '%s' "${1/\/\/*@/\/\/***@}"; }

# require VAR... -- fails naming every missing variable at once, not one per run.
require() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "missing environment variables: ${missing[*]}"
}

# The first non-empty of the given variables. Every platform publishes its S3
# credentials under slightly different names, and each project links whichever ones
# its own code happens to read; accepting the usual spellings is cheaper than a
# translation layer in every service's configuration.
env_any() {
  local name
  for name in "$@"; do
    if [[ -n "${!name:-}" ]]; then
      printf '%s' "${!name}"
      return 0
    fi
  done
  return 1
}

# The off-site bucket. rclone is configured entirely through the environment, so
# the image ships no config file and no credential is ever written to disk.
configure_dest() {
  require BACKUP_BUCKET BACKUP_ENDPOINT BACKUP_ACCESS_KEY_ID BACKUP_SECRET_ACCESS_KEY
  export RCLONE_CONFIG_DEST_TYPE=s3
  # Overridable so the whole thing can be rehearsed against a local MinIO before it
  # is ever pointed at the real bucket.
  export RCLONE_CONFIG_DEST_PROVIDER="${BACKUP_PROVIDER:-Cloudflare}"
  export RCLONE_CONFIG_DEST_REGION="${BACKUP_REGION:-auto}"
  export RCLONE_CONFIG_DEST_ENDPOINT="$BACKUP_ENDPOINT"
  export RCLONE_CONFIG_DEST_ACCESS_KEY_ID="$BACKUP_ACCESS_KEY_ID"
  export RCLONE_CONFIG_DEST_SECRET_ACCESS_KEY="$BACKUP_SECRET_ACCESS_KEY"
  # The token is scoped to this one bucket, so it may neither list nor create buckets.
  export RCLONE_CONFIG_DEST_NO_CHECK_BUCKET=true
}

# The application's own bucket, under whichever names the project links it.
configure_src() {
  SRC_BUCKET="$(env_any S3_BUCKET S3_BUCKET_NAME BUCKET_NAME)" ||
    die "no source bucket (S3_BUCKET / S3_BUCKET_NAME / BUCKET_NAME)"
  local endpoint key secret
  endpoint="$(env_any S3_ENDPOINT S3_HOST AWS_ENDPOINT_URL_S3)" ||
    die "no source endpoint (S3_ENDPOINT / S3_HOST / AWS_ENDPOINT_URL_S3)"
  key="$(env_any S3_ACCESS_KEY S3_ACCESS_KEY_ID AWS_ACCESS_KEY_ID)" ||
    die "no source access key (S3_ACCESS_KEY / S3_ACCESS_KEY_ID / AWS_ACCESS_KEY_ID)"
  secret="$(env_any S3_SECRET_KEY S3_SECRET_ACCESS_KEY AWS_SECRET_ACCESS_KEY)" ||
    die "no source secret key (S3_SECRET_KEY / S3_SECRET_ACCESS_KEY / AWS_SECRET_ACCESS_KEY)"

  export RCLONE_CONFIG_SRC_TYPE=s3
  export RCLONE_CONFIG_SRC_PROVIDER=Other
  export RCLONE_CONFIG_SRC_ENDPOINT="$endpoint"
  export RCLONE_CONFIG_SRC_ACCESS_KEY_ID="$key"
  export RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY="$secret"
  export RCLONE_CONFIG_SRC_REGION="$(env_any S3_REGION AWS_REGION || echo us-east-1)"
  # Addressing style is a genuine trap: a gateway that wants virtual-host addressing
  # answers a path-style request with an HTML page, and the S3 client can only report
  # a parse error. Path style is the safe default for self-hosted storage.
  if [[ "${S3_FORCE_PATH_STYLE:-true}" == "false" ]]; then
    export RCLONE_CONFIG_SRC_FORCE_PATH_STYLE=false
  else
    export RCLONE_CONFIG_SRC_FORCE_PATH_STYLE=true
  fi
}
