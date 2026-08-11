# A cron container that backs up one application: an age-encrypted pg_dump plus a
# copy of its S3 bucket, both pushed to a bucket at a different provider.
#
# PG_MAJOR must match the server this backs up. It is tempting to just ship the
# newest client, since pg_dump handles any older server -- but the archive it writes
# is not restorable into that older server: a 17 client emits `SET transaction_timeout`,
# which 16 does not recognise, and pg_restore stops there. The dump direction would
# work and the restore would fail, which is the worst possible place to find out.
#
# Getting it wrong now fails loudly and early instead: a client older than the server
# makes pg_dump refuse outright, on the very first run after a deploy.
#
# Debian rather than Alpine: glibc's resolver follows resolv.conf's `ndots` and
# search domains, which is what an in-cluster hostname like
# `…-postgres-….<namespace>.svc` relies on. musl handles that differently and it
# is not worth finding out the hard way in a backup. (The DNS failures seen while
# bringing this up turned out to be a start-up race rather than the resolver --
# see the retry in entrypoint.sh -- so this is caution, not a diagnosis.)
# The image is bigger; it runs for ten seconds a day.
ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-bookworm

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash age jq curl ca-certificates tzdata cron \
  && rm -rf /var/lib/apt/lists/*

# rclone comes from upstream, not from apt: bookworm ships 1.60 (2022), which R2
# answers with `501 NotImplemented` on upload. Pinned rather than "current", so a
# rebuild a year from now produces the same image.
ARG RCLONE_VERSION=1.75.0
# No default: BuildKit fills TARGETARCH in automatically, and giving it one here
# would override that and fetch an amd64 package on an arm64 builder.
ARG TARGETARCH
RUN curl -fsSL -o /tmp/rclone.deb \
  "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-${TARGETARCH}.deb" \
  && dpkg -i /tmp/rclone.deb \
  && rm /tmp/rclone.deb

# Cron fires on local time and the projects are Czech; the small hours are quiet.
ENV TZ=Europe/Prague

COPY common.sh backup.sh restore.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
