# Disaster recovery

The box is gone — hardware failure, a deleted server, a disk that no longer
mounts. This is how the platform comes back.

Restoring *one* thing on a box that still works is
[`backup/OPERATIONS.md`](backup/OPERATIONS.md). This document is for the case
where there is nothing left to log into.

> **Status, 2026-08-22.** This procedure has **never been executed**, and the
> backup stack it depends on is committed here but not yet running on any box
> (`BACKLOG.md` **P1**). Read it as the intended sequence, not as a tested one.
> The repo's own rule applies to this file harder than to any other: *committed
> is not deployed.*

## Before anything: what must exist off this box

Four things, and none of them can be recovered from the backup, because they are
what unlocks it:

| What | Where it must live | Why it cannot be in the backup |
| --- | --- | --- |
| The restic **repository URL** | password manager | You cannot read a repository you cannot find |
| The restic **repository password** | password manager | restic has no recovery path. A lost password makes every snapshot random bytes — permanently |
| **Storage backend credentials** (SSH key or S3 keys) | password manager | Same circularity, plus: a credential inside the archive is a gift to anyone who cracks it |
| **DNS registrar access** | password manager | Nothing on the box can re-point a record at a box that no longer exists |

If you are reading this to check whether those four exist: that is the right
time to check. Doing it after the failure is not a plan.

## What comes back, and what does not

| Restored | Not restored |
| --- | --- |
| CI database — repos, build history, **every deploy secret** | Loki logs (7-day triage data, deliberate) |
| ACME account key + every certificate | Docker build cache |
| Grafana dashboards, users, API keys | Tenant application code and deploys — each tenant's own repo and pipeline |
| Uptime Kuma monitors and their history | Tenant databases, except whatever the tenant handed over |
| `/opt/ci/*.env`, `/opt/caddy/caddy.env`, `/opt/observability/observability.env` | Anything configured by hand on the box and never committed |
| Tenant hand-off dumps, as files | |

**Objectives.** RPO: up to ~24 h of platform state (the nightly snapshot), plus
whatever a tenant's own dump schedule adds. RTO: hours, dominated by download
time and DNS propagation, not by the steps below.

## Phase 0 — prove the repository before you build anything

From **any** machine with restic and network access. Do this first: it is
fifteen minutes, and it decides whether the rest of this document is a recovery
or a rewrite.

```bash
export RESTIC_REPOSITORY='<from the password manager>'
export RESTIC_PASSWORD='<from the password manager>'

restic snapshots --tag platform --host platform --compact
restic ls latest | head -50
```

You should see a snapshot list ending within the last day or so, and a tree
containing `/opt/backups/staging/volumes/…` and
`/opt/backups/staging/secrets/…`.

If this fails, stop. Everything below assumes it worked, and a rebuild started
on a broken repository is a rebuild done twice.

## Phase 1 — a fresh host

```bash
# Provision the box. Then, on it:
git clone https://github.com/aneskurtovic/infra.git /tmp/infra
sudo /tmp/infra/host/bootstrap.sh
```

That installs Docker, the shared `edge` network, ufw, SSH hardening, swap,
fail2ban, and unattended upgrades. See [`host/README.md`](host/README.md).

Do **not** point DNS at this box yet. A half-built proxy answering on the real
hostname serves errors to real users and, worse, can burn Let's Encrypt rate
limit on certificates you are about to restore anyway.

## Phase 2 — the secrets, before anything that needs them

```bash
sudo /tmp/infra/backup/install.sh
```

Then write the repository URL and password into `/opt/backups/backup.env` and
`/opt/backups/restic-password` (mode `600`) from the password manager, and pull
the secret files back:

```bash
set -a; . /opt/backups/backup.env; set +a
export RESTIC_PASSWORD_FILE=/opt/backups/restic-password

install -d -m 700 /opt/backups/restore
restic restore latest --host platform --tag platform \
  --include /opt/backups/staging/secrets --target /opt/backups/restore

SEC=/opt/backups/restore/opt/backups/staging/secrets
install -d -m 755 /opt/ci /opt/caddy /opt/observability
for f in "$SEC"/opt/ci/*.env "$SEC"/opt/ci/.env; do
  [ -e "$f" ] || continue
  install -m 600 "$f" "/opt/ci/$(basename "$f")"
done
install -m 600 "$SEC/opt/caddy/caddy.env"                     /opt/caddy/caddy.env
install -m 600 "$SEC/opt/observability/observability.env"     /opt/observability/observability.env
```

Check the modes before moving on — `600 root:root`, all of them. These files
hold the GitHub OAuth secret, the Woodpecker agent secret, and the Grafana
admin password.

## Phase 3 — volumes

Every platform volume is `external: true` in its compose file precisely so that
`compose up` can never quietly create an empty one and start a service that
looks healthy and has lost everything. Create them, then fill them, then start
anything.

```bash
for v in woodpecker-server-data caddy-data grafana-data uptime-kuma-data loki-data; do
  docker volume create "$v"
done

restic restore latest --host platform --tag platform \
  --include /opt/backups/staging/volumes --target /opt/backups/restore

for v in woodpecker-server-data caddy-data grafana-data uptime-kuma-data; do
  src="/opt/backups/restore/opt/backups/staging/volumes/$v"
  [ -d "$src" ] || { echo "MISSING FROM SNAPSHOT: $v" >&2; continue; }
  docker run --rm -v "$v:/data" -v "$src:/restored:ro" \
    alpine:3.22 sh -ec 'cp -a /restored/. /data/'
  echo "restored $v"
done
```

`loki-data` is created empty and stays empty — seven days of triage logs are not
worth restoring, and `observability/OPERATIONS.md` settled that. Creating the
volume anyway keeps the compose file's `external: true` contract satisfied.

## Phase 4 — bring the stacks up, in this order

```bash
# 1. Edge proxy — it owns :80/:443 and every other stack's UI reaches the world
#    through it. Its restored volume already holds valid certificates, so this
#    does NOT need to talk to Let's Encrypt to serve TLS.
install -d -m 755 /opt/caddy /opt/caddy-sites
cp /tmp/infra/caddy/Caddyfile /opt/caddy/Caddyfile
cp /tmp/infra/caddy/docker-compose.yml /opt/caddy/docker-compose.yml
cp /tmp/infra/caddy/*.caddy /opt/caddy-sites/
docker compose --env-file /opt/caddy/caddy.env -f /opt/caddy/docker-compose.yml up -d

# 2. CI.
docker compose --env-file /opt/ci/.env -f /tmp/infra/woodpecker/docker-compose.yml up -d

# 3. Observability.
docker compose --env-file /opt/observability/observability.env \
  -f /tmp/infra/observability/docker-compose.yml up -d

# 4. Monitoring.
docker compose -f /tmp/infra/uptime-kuma/docker-compose.yml up -d
```

Read each stack's own runbook for the details this compresses —
[`woodpecker/BOOTSTRAP.md`](woodpecker/BOOTSTRAP.md),
[`observability/MIGRATION.md`](observability/MIGRATION.md),
[`uptime-kuma/MIGRATION.md`](uptime-kuma/MIGRATION.md). The order is what
matters here: the proxy first, because everything else is reached through it.

## Phase 5 — DNS

Only now. Point every A/AAAA record at the new address.

Certificates are already restored and valid, so there is no gap while ACME
issues — that is the whole reason `caddy-data` is backed up rather than treated
as disposable. Caddy will renew normally once `:80/:443` are reachable at the
new address.

## Phase 6 — verify, in this order

1. `https://ci.aneskurtovic.com` loads and **GitHub login works** — that proves
   the OAuth secret came back, not just the database.
2. A repository still has its deploy secrets: Woodpecker → repo → Settings →
   Secrets. If these are missing, the CI volume did not restore; stop and fix
   that before anyone pushes.
3. `https://logs.aneskurtovic.com` loads and Grafana accepts the admin login.
   The Loki datasource is provisioned from the repo, so it is present even
   though the log history is not.
4. `https://uptime.aneskurtovic.com` loads and the monitor list is intact —
   Kuma v2 has no declarative export, so the volume *is* the configuration.
5. Trigger one real pipeline end to end. A restored CI server that schedules
   nothing is a failure you want to find deliberately.
6. `/opt/backups/bin/backup.sh` — the new box must be backing itself up before
   you call this done. A recovered platform with no backups is where you were
   before all this.

## Phase 7 — what still needs a human

- **Tenant applications.** Each tenant redeploys from its own repo through CI.
  The platform's job ends at a working pipeline.
- **Tenant databases.** Hand each tenant its dump from
  `/opt/backups/handoff/<tenant>/`; loading it is the tenant's side of the
  contract (`backup/README.md`).
- **The GitHub OAuth app**, if the hostname changed — the callback URL is
  configured on GitHub, not in the volume.
- **Uptime Kuma notification channels.** They live in the restored volume, but
  test one. A monitoring stack that has come back without a working notification
  path is `BACKLOG.md` **P3** happening again, quietly.
- **Anything configured by hand and never committed.** There should be nothing:
  the 2026-08-19 audit found zero config drift. That claim is worth re-testing
  here, because this is the one moment it gets checked for real.

## Known gaps in this plan

- **The restore drill has not been run** (`backup/OPERATIONS.md` § Restore drill
  log). Until it has, every "restored" above is an expectation.
- **Nothing enumerates which repository holds which deploy secret**
  (`BACKLOG.md` **P5**), so Phase 6 step 2 is a spot check, not a proof. The
  honest answer today is that a pipeline failing after recovery is how you find
  the one that did not come back.
