# Security

This tool handles a whole application's data at once: a `pg_dump` of the production
database and a copy of its upload bucket. A flaw here is not a flaw in one feature —
it is either every record in the database or the ability to destroy the only copy of
them. That is the reason this file exists on a project of five shell scripts.

## Reporting a vulnerability

**Please do not open a public issue.**

Use GitHub's private vulnerability reporting — the **Security** tab of this
repository, then *Report a vulnerability*. It is enabled. If you would rather not use
GitHub, mail <konopi79@seznam.cz>.

This is a one-person side project, not a vendor with an on-call rota. Expect an
acknowledgement within a week. Anything that lets an attacker read backup contents,
delete history, or reach the source database gets looked at the day I see it;
everything else waits for a weekend. If you have heard nothing in two weeks, assume
the mail went astray and ping again.

Please include what an attacker gains, not only what is wrong — the difference between
"an operator with the private key could do X" and "a stranger with the destination
token could do X" decides whether this is urgent. Proof-of-concept code is welcome. No
bounty is on offer; credit in the fix commit is, unless you would rather not be named.

## Supported versions

There are no releases and no version numbers. **`main` is the supported version**, and
you build the image yourself, so a fix reaches you when you rebuild. There is no
mechanism here to push an update to a running deployment — if you run this, watch the
repository.

## What the design assumes

Read this before reporting: several things that look alarming are deliberate, and
several things that look harmless are the actual soft spots.

**The container never holds the key that decrypts backups.** It has only the *public*
age recipient, so an attacker who owns the backup service can write objects it cannot
read. This is the single most important property in the design. A report that
undermines it — anything letting the container, its logs, or the destination bucket
yield plaintext — is the most serious kind of finding here.

**The private age key is the crown jewel, and it lives outside this system.** Lose it
and every dump ever taken is scrap; leak it and every dump ever taken is readable,
including the ones already off-site. Nothing in this repository can protect it. It
belongs in a password manager and on the operator's machine, one key pair per project,
and it is passed to `restore.sh` as a read-only mount — never baked into an image,
never an environment variable on a hosted service.

**Nothing in the backup path deletes.** Retention is a lifecycle rule on the
destination bucket, `rclone copy` is used instead of `sync`, and failed runs are left
in place rather than cleaned up. That is not an oversight — it is what keeps a bug in
this code, or a stolen destination token, from shortening history. Note the limit,
though: **a token that can write can usually also delete**, so the destination bucket
wants object-lock or retention if the provider offers it. Scope each token to one
bucket; a token shared across projects makes one compromise into several.

**Credentials arrive as environment variables and are never written to disk.** rclone
is configured entirely through `RCLONE_CONFIG_*` variables precisely so no config file
holds a secret. Anything with access to the container's environment — a shell in the
container, a process listing on some platforms, a crash dump — has the database URL
and both sets of S3 credentials. That is inherent to the deployment model, not a bug
to be reported; what *would* be a bug is this code copying a secret somewhere more
durable than the environment.

**Logs go to stderr and connection URLs are redacted** (`redact()` in `common.sh`).
They still contain bucket names, object keys and the project's `BACKUP_NAME`. A leak
of a secret into a log line is a real finding — treat one as such.

**The dump is personal data.** For the project this was written for it holds names,
e-mail addresses, phone numbers and password hashes. That is why the encryption is not
optional and why `AGE_RECIPIENT` is a hard requirement rather than a default.

**The restore path runs on a trusted machine, by hand.** `restore.sh` decrypts with
the private key, and `into` will happily `--clean` an existing database. It is
deliberately not automated and deliberately not something the backup service can do.
Findings that require an attacker to already hold the private key and a shell on the
operator's machine describe a lost game, not a vulnerability.

**`PG_MAJOR` must match the server major.** A mismatch produces an archive that cannot
be restored — a correctness and availability problem, covered in the README, not a
security one. Report it as a bug.

## Out of scope

- **Application secrets.** They are not in the dump and a dump alone may not be a
  complete restore — an application that encrypts data at rest with a key derived from
  an environment variable is silently broken by restoring under a different value. Keep
  the production environment in a password manager and treat it as part of the backup.
  This is a documented gap, not something this tool intends to solve.
- **Vulnerabilities in the base image or in `pg_dump`, `rclone`, `age`, `curl`, `jq`.**
  Report those upstream. If a fix needs a change here — a pin, a rebuild, a flag — say
  so and it will be made.
- **The operator's own bucket policy, IAM scoping, or hosting platform.** The README
  says what the setup should look like; a deployment that ignores it is a
  misconfiguration, not a flaw in this code.
- **Anything requiring an attacker who already controls the destination bucket, the
  source database, or the operator's machine.**

## If you run this

The two habits that matter more than any patch:

1. **Rehearse a restore.** A backup nobody has restored is not a backup. `restore.sh
verify` exists for exactly this and prints row counts, because a restore that
   reports success over an empty schema is worth nothing.
2. **Put a dead man's switch on it** (`HEALTHCHECK_URL`). If the container is gone
   altogether, only something outside it can notice that no ping arrived — a backup
   that quietly stopped months ago is the ordinary way this fails.
