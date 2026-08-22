# Platform backup

Off-site, encrypted, multi-generation backups of everything the **platform**
owns, plus a swept hand-off directory for what tenants choose to give it.

Before this existed, the box had exactly one backup: a tenant's nightly Postgres
dump, keeping **one generation**, written **to the disk it protects against**.
Every platform-owned volume had none at all. That is `BACKLOG.md` **P1**, and
this directory is its answer.

```
backup.sh          nightly: quiesce → stage → snapshot → forget
maintenance.sh     weekly:  prune → check (structure + 10% of the data)
restore-drill.sh   on demand: restore into a scratch volume and verify it
install.sh         idempotent installer: restic, /opt/backups, units, timers
systemd/           the two timers and their services
.env.example       documented config; copied to /opt/backups/backup.env
OPERATIONS.md      steady state, restores, failure modes, the drill log
```

Recovering a whole box is a different document:
[`../DISASTER-RECOVERY.md`](../DISASTER-RECOVERY.md).

## What is backed up

| Source | Why it is irreplaceable |
| --- | --- |
| `woodpecker-server-data` | Repo setup and **every per-repository deploy secret**. Nothing enumerates which repo holds which — after a rebuild you find out when a pipeline fails |
| `caddy-data` | The ACME account key and every issued certificate. Restoring it is also what keeps a rebuild from re-issuing every certificate at once into a Let's Encrypt rate limit |
| `grafana-data` | Dashboards, users, API keys |
| `uptime-kuma-data` | Monitor definitions and their entire history — Kuma v2 has no declarative export, so this volume *is* the configuration |
| `/opt/ci/*.env`, `/opt/caddy/caddy.env`, `/opt/observability/observability.env` | The values the committed config only *references*. The `.env.example` files name every variable; only these hold them |
| `/opt/backups/handoff/<tenant>/` | Whatever tenants hand over — see the contract below |

**Not backed up, on purpose.** `loki-data` (seven days of triage data with a
working compactor — `observability/OPERATIONS.md` settled this), `alloy-data`
(read positions; losing it duplicates a few log lines), tenant databases
directly, and Docker's build cache.

**Also not backed up: `/opt/backups/backup.env` and the repository password.**
They are the keys to the archive, and the archive is not where keys go. Both
belong in a password manager, off this box. See
[`../DISASTER-RECOVERY.md`](../DISASTER-RECOVERY.md).

## Why restic

The requirement that decided it is *multiple generations*, which the existing
tenant script structurally cannot provide: it writes one file and overwrites it
nightly, so a corruption found on day two has no clean copy. On top of that
restic gives content-addressed deduplication (fourteen daily copies of a mostly
unchanged 112 MB database cost roughly one), encryption at rest so the storage
provider is not trusted, and `restic check`, which verifies that what is stored
can still be read.

The **backend is deliberately not decided here.** `RESTIC_REPOSITORY` is the
only thing that says where snapshots go, and any restic backend satisfies it.
The one rule is that it is off this box.

## The tenant hand-off contract

The platform owns the *substrate*; a tenant owns producing something consistent
to put in it. Stated as narrowly as possible, so neither side has to learn the
other's storage:

> A tenant writes consistent dumps into `/opt/backups/handoff/<tenant>/`.
> The platform sweeps that directory off-site every night, encrypted, with the
> same retention as everything else, and warns in the journal when a tenant's
> newest file goes stale.

That is the whole contract. The platform never learns what Postgres is; the
tenant never learns what restic is.

**The tenant's side**, for a database — the point is `pg_dump`, which produces a
consistent dump of a *running* database. The platform cannot do this for the
tenant, because doing it correctly requires knowing what is inside:

```bash
install -d -m 700 /opt/backups/handoff/ludo     # once, as root

docker exec ludo-postgres pg_dump -U ludo -Fc ludo \
  > /opt/backups/handoff/ludo/ludo_prod_$(date -u +%Y%m%dT%H%M%SZ).dump
```

Two things the tenant still owns after handing over:

- **Writing atomically.** Dump to a temporary name in the same directory and
  `mv` into place, so the sweep never catches a half-written file. The tenant's
  existing `backup-db.sh` already does exactly this — keep that part.
- **Local rotation.** The platform does not delete from `handoff/`; it only
  copies. A tenant that writes a new file nightly and never removes one fills
  the disk. Keep two or three locally and let the off-site retention hold the
  rest.

The tenant's local copy stays useful — restoring from `/opt/backups/handoff/`
is faster than pulling from off-site. It is just no longer the *only* copy,
which was the actual defect.

**Staleness is visible, not enforced.** If a tenant's newest file is older than
`BACKUP_HANDOFF_MAX_AGE_HOURS` (default 30), the run logs a warning and
continues. A tenant's broken cron is a tenant's problem; it must not take the
platform's own backup down with it.

## Install

The repo is a checkout you copy *from*. Once this has run, the checkout can be
deleted and backups keep working.

```bash
git clone https://github.com/aneskurtovic/infra.git /tmp/infra \
  || git -C /tmp/infra pull --ff-only
sudo /tmp/infra/backup/install.sh
```

Then, in order:

1. Put the repository password in `/opt/backups/restic-password` (mode `600`)
   **and in a password manager off this box**. restic has no recovery path.
2. Fill `/opt/backups/backup.env` — `RESTIC_REPOSITORY` and any backend
   credentials.
3. Initialise the repository, once, ever:
   ```bash
   set -a; . /opt/backups/backup.env; set +a
   RESTIC_PASSWORD_FILE=/opt/backups/restic-password restic init
   ```
   Nothing in this stack does this for you. `restic init` against a typo'd URL
   creates a brand-new empty repository and every later run "succeeds" into it.
4. Run one backup by hand and read the output: `/opt/backups/bin/backup.sh`
5. Re-run `install.sh` (it enables the timers once step 2 is done), or:
   ```bash
   systemctl enable --now platform-backup.timer platform-backup-maintenance.timer
   ```
6. **Run the restore drill and write the date down** in
   [`OPERATIONS.md`](OPERATIONS.md): `/opt/backups/bin/restore-drill.sh`

Until step 6 has happened, this box has backup *automation*. Whether it has
backups is unknown, and a green timer is not evidence either way.

## Schedule

| Unit | When | What |
| --- | --- | --- |
| `platform-backup.timer` | daily 05:30 (±5 m) | quiesce, stage, snapshot, forget |
| `platform-backup-maintenance.timer` | Sunday 07:00 (±15 m) | prune, then `check --read-data-subset=10%` |

05:30 sits after the tenant's 04:00 dump — otherwise every night ships the
previous day's — and after the 05:00 Sunday `docker builder prune`. Both are in
`BACKLOG.md` **P2**; if either moves, move this.

## The one thing that costs downtime

Three of the four volumes hold a live SQLite database, and copying one while it
writes can produce an archive that restores into a corrupt state. So each
service is **stopped, copied, and started again, one at a time** — the same
procedure `woodpecker/BOOTSTRAP.md` and `uptime-kuma/OPERATIONS.md` already
prescribe by hand. Seconds of downtime each, at 05:30, on services with no SLA.
If a CI workflow is mid-run, the agent reconnects but the workflow may still
need restarting.

**`caddy` is the exception and is copied live.** It owns `:80/:443`; stopping it
takes every site on the box down, monitoring and CI included. The genuinely
irreplaceable part of `caddy-data` — the ACME account key — is written once at
first start and never touched again.

## Where failures show up

The runs log to the journal under `platform-backup` and
`platform-backup-maintenance`, which `observability/alloy/config.alloy` ships to
Loki. In Grafana:

```logql
{stack="platform", service="platform-backup"}
{stack="platform", service=~"platform-backup.*"} |= "WARN"
```

There is still **no alert** — nothing pages anyone when the backup fails, and
that is `BACKLOG.md` **P3**/**P4**, not something this directory can close. What
it can do is make the failure queryable instead of invisible, and it does.
