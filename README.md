# pg-s3-backup

Off-site backups for an application that keeps its data in **PostgreSQL** and its
uploads in an **S3 bucket**. One small cron container per project: it dumps the
database, encrypts the dump, and pushes it — together with a copy of the bucket — to
storage at a *different* provider.

Built for projects hosted on [rock8.cloud](https://rock8.cloud), whose managed
Postgres has no backups of its own and no public host, so the backup has to run as a
service inside the project. It has nothing rock8-specific in it, though: give it a
connection URL and two sets of S3 credentials and it runs anywhere Docker does.

## What it does, and what it deliberately does not

- **Encrypts asymmetrically.** The container holds only the *public* age key, so a
  compromised backup service can write backups it cannot read. The private key lives
  in a password manager and on the operator's machine.
- **Never deletes anything.** Retention belongs to a lifecycle rule on the
  destination bucket, so neither a bug here nor a stolen token can shorten history.
- **`rclone copy`, never `sync`.** An object deleted in the application must not
  disappear from the backup — that deletion is the exact case this insures against.
- **Checks the dump it just uploaded.** A failed `pg_dump` still leaves an object
  behind; an empty one.
- **Restores are manual.** There is a `restore` command, not a restore *automation*.
  That one operation wants a human who knows why they are running it.
- **No UI, no state, no database of its own.** The whole thing is five shell scripts
  you can read in ten minutes. A backup tool that itself needs backing up has closed
  a circle nobody wants to be in.

## What it does not cover

**Application secrets.** They are not in the dump, and a dump alone is often not a
complete restore: if the application encrypts anything at rest with a key derived
from an environment variable, restoring under a different value silently breaks that
data. (In Malibo, `AUTH_SECRET` decrypts every stored Google refresh token.) Keep the
production environment in a password manager and treat it as part of the backup.

## Configuration

Everything is an environment variable; nothing is baked into the image except the
Postgres client version.

| Variable                                                                       | Meaning                                                         |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| `BACKUP_NAME`                                                                  | **required** — goes into the object name (`malibo-2026….dump.age`) |
| `AGE_RECIPIENT`                                                                | **required** — the public age key (`age1…`)                     |
| `DATABASE_URL`                                                                 | the source database                                              |
| `BACKUP_BUCKET` `BACKUP_ENDPOINT` `BACKUP_ACCESS_KEY_ID` `BACKUP_SECRET_ACCESS_KEY` | the off-site destination                                    |
| `S3_*`                                                                         | the application's own bucket (see below)                         |
| `BACKUP_DATABASE` / `BACKUP_FILES`                                             | default `true`; set `false` to turn a half off *deliberately*    |
| `BACKUP_CRON`                                                                  | default `17 2 * * *`, in `TZ` (default `Europe/Prague`)          |
| `RUN_ON_START`                                                                 | default `true` — a deploy proves the chain immediately           |
| `HEALTHCHECK_URL`                                                              | optional dead man's switch, e.g. a healthchecks.io check         |
| `BACKUP_PROVIDER` / `BACKUP_REGION`                                            | default `Cloudflare` / `auto`; override to rehearse against MinIO |

The application's bucket is read under whichever names the project links it:
`S3_BUCKET` / `S3_BUCKET_NAME` / `BUCKET_NAME`, `S3_ENDPOINT` / `S3_HOST` /
`AWS_ENDPOINT_URL_S3`, `S3_ACCESS_KEY` / `S3_ACCESS_KEY_ID` / `AWS_ACCESS_KEY_ID`,
`S3_SECRET_KEY` / `S3_SECRET_ACCESS_KEY` / `AWS_SECRET_ACCESS_KEY`, plus
`S3_REGION` and `S3_FORCE_PATH_STYLE` (default `true`).

Both halves are on by default and each is switched off explicitly, because a half
skipped for want of a variable is how a backup silently stops covering half the data.
A missing S3 configuration is therefore a hard failure, not a skip.

### `PG_MAJOR` is a build argument, and it must match the server

```bash
docker build --build-arg PG_MAJOR=16 -t pg-s3-backup:16 .
```

The obvious shortcut — always ship the newest client, since `pg_dump` reads any older
server — **does not work**, and this is worth stating plainly because the failure only
appears at restore time:

- a 17 client dumping a 16 server succeeds, but its archive sets
  `transaction_timeout`, which 16 does not recognise, so `pg_restore` stops;
- a 16 client cannot even read a 17 archive (`unsupported version (1.16) in file header`).

So the client major has to match the server major in **both** directions. A client
that is too *old* fails loudly on the first run after a deploy, which is the safe way
round: upgrade the image before upgrading the database.

## Setting up a project

1. **Destination bucket.** One per project (a token scoped to one bucket keeps the
   blast radius to one project). Lifecycle rules: delete `db/daily/` after 14 days,
   `db/monthly/` after 400. The run on the 1st of a month writes to `db/monthly/`.
   Object-lock/retention on `db/` is worth adding if the storage supports it — an
   object token that can write can generally also delete.
2. **An age key pair, per project.** A shared key would mean whoever can restore one
   project can read the other.
   ```bash
   docker run --rm --entrypoint age-keygen pg-s3-backup
   ```
   Private key (`AGE-SECRET-KEY-…`) into the password manager and nowhere else;
   public key into `AGE_RECIPIENT`. **Check you can find the private key again before
   the first backup runs** — without it every dump is scrap.
3. **The service.** On rock8: a repo service pointing at this repository, with
   `PG_MAJOR` as a build argument, the database and S3 credentials linked from the
   project's own services, and the `BACKUP_*` values set manually. The cheapest plan
   is plenty.

   **Link `URL_PLAIN`, not `URL`, into `DATABASE_URL`.** rock8's `URL` key is the
   "libpq-compatible" one and carries `uselibpqcompat=true`, which `pg_dump` rejects
   outright (`invalid URI query parameter`). The service also has no listener, so
   leave the health endpoint unset and treat `containerPort` as a formality —
   the platform is happy without one, though each deploy sits in
   `waiting-for-healthcheck` for several minutes before going live.

   **Run exactly one replica.** This is a cron, not a server: every replica keeps its
   own copy of the schedule, so two of them would mean two simultaneous `pg_dump`s
   against a live database every night.

   **Expect two or three extra dumps around each deploy, though — that is not a
   replica problem.** A rollout starts a fresh pod, which immediately runs its
   start-up backup, and rock8 rolls out more than once per deploy. Only one pod
   survives to run the schedule; a scheduled run producing exactly one object is the
   proof that the replica count is right, not the pod count during a deploy. The
   spares age out with the daily retention. There is deliberately no "skip if one was
   taken recently" rule — that is logic whose failure mode is not taking a backup.
4. **A healthchecks.io check** in `HEALTHCHECK_URL`. If the container is gone
   altogether, only something outside it can notice that no ping arrived — and a
   backup that quietly stopped months ago is the ordinary way this fails.

## Restoring

From a machine holding the private key, with an image built for the target's major:

```bash
export BACKUP_BUCKET=… BACKUP_ENDPOINT=https://<account>.r2.cloudflarestorage.com
export BACKUP_ACCESS_KEY_ID=… BACKUP_SECRET_ACCESS_KEY=… BACKUP_NAME=malibo
alias mrestore='docker run --rm -it --entrypoint restore.sh \
  -e BACKUP_BUCKET -e BACKUP_ENDPOINT -e BACKUP_ACCESS_KEY_ID -e BACKUP_SECRET_ACCESS_KEY \
  -e BACKUP_NAME -e AGE_KEY_FILE=/key -v ~/.keys/malibo.age:/key:ro pg-s3-backup:16'

mrestore list                                     # what is there
mrestore into latest "postgresql://…/app"          # or a specific db/daily/… key
mrestore files                                     # needs S3_* too
```

`latest` is resolved by modification time, not by object name — sorting keys would
order by project name first and timestamp second.

Rebuilding a lost project: provision a new database and bucket, restore the dump,
copy the files back, set the environment **including the original application
secrets**, deploy. Schema migrations do not need re-running; the dump carries the
schema.

## The drill

A backup nobody has restored is not a backup. Quarterly, into a scratch database:

```bash
psql "$ADMIN_URL" -c 'CREATE DATABASE restore_check;'
VERIFY_DATABASE_URL='postgresql://…/restore_check' mrestore verify
```

`verify` restores the newest dump and prints the row counts of the twenty largest
tables, because a restore that reports success over an empty schema is worth nothing.

The same drill against a local Postgres with MinIO standing in for the destination
(`BACKUP_PROVIDER=Minio`) is how this is tested before it is pointed at anything real.
Both `PG_MAJOR` findings above came out of exactly that rehearsal.

## Security and licence

Found a hole? [SECURITY.md](SECURITY.md) — please report it privately, not as an
issue. It also lists what the design deliberately assumes, which is worth reading
before you trust this with a production database.

[MIT](LICENSE). Use it, fork it, ship it; there is no warranty, and a backup tool is
exactly the kind of thing to verify yourself before relying on it.
