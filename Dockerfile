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
ARG PG_MAJOR=17
FROM postgres:${PG_MAJOR}-alpine

RUN apk add --no-cache bash rclone age jq curl tzdata

# Cron fires on local time and the projects are Czech; the small hours are quiet.
ENV TZ=Europe/Prague

COPY common.sh backup.sh restore.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
