# Platform backlog

What this platform is missing, why it matters *on this box*, and what "done"
looks like. One item per gap, ordered by what would hurt first.

This file exists because the platform reached the point where the interesting
work stopped being "stand the services up" and started being "keep them alive
without me watching." Everything below is that second kind of work.

It has three parts, and the difference between them matters:

1. **Already true — do not re-open.** Recommendations that are settled, each with
   the file that proves it. Read this before acting on any external review.
2. **Items (P1–P13).** Gaps found by *measuring the box* — things broken,
   unbounded, or unobserved today. Ordered by what would hurt first.
3. **Direction (P14–P21).** Forward proposals from the three external reviews.
   Not defects; nothing here is currently failing. Kept separate so "we should
   probably do SSO one day" never outranks "nothing alerts."

## How to read an item

| Part | What it is for |
| --- | --- |
| **Problem** | The gap, stated as a failure that can actually happen here |
| **Evidence** | What was observed on the box or in the repo, with the date |
| **Shape of the fix** | Enough direction to start; not a design document |
| **Done when** | A check someone can run and get a yes/no from |
| **Not this** | Scope deliberately excluded, so it doesn't creep back in |

**Evidence is dated and rots.** Every observation below comes from a read-only
forensic pass over the live box on **2026-08-19**. The repo's own rule applies to
this file too: *committed is not deployed.* Re-measure before acting — a gap may
have closed, and a number may have grown.

## The tenant boundary applies here

`host/README.md` draws the line this repo lives by: **if a second application
would need it too, it belongs to the platform.** The backlog inherits that line,
and it is easy to cross by accident when writing about backups or monitoring.

Worked example: the box runs two Postgres databases (`ludo-postgres`,
`ludo-postgres-stage`). They hold real data, and losing them would hurt most —
but they are **Ludo's**, not the platform's. So:

- **Platform owns** the backup *substrate*: the off-site target, the encrypted
  repository, the schedule, the restore drill, and a documented contract a
  tenant can call to hand over a consistent dump.
- **Ludo owns** producing that dump and calling the contract.

An item here that says "back up ludo-postgres" is a bug in this file. An item
that says "give tenants somewhere to put a dump, and prove it restores" is
correct.

> **The boundary is currently inverted, and that is item P2.** Three
> `/etc/systemd/system/` timers — `ludo-backup`, `ludo-purge`,
> `ludo-docker-cleanup` — are installed by a *tenant's* deploy script, and one of
> them is the only thing preventing platform-wide disk exhaustion. The principle
> above is not yet true on the box.

---

# Already true — do not re-open

Three external reviews of this stack (`ChatGPT.txt`, `GoogleAI.txt`, `ZAI.txt`,
kept outside the repo) were written from a **screenshot of the directory tree**,
not from the files. Their advice is sound in general and substantially stale
here. Each row cites what disproves the recommendation.

| Recommendation | Status | Proof |
| --- | --- | --- |
| "Pin image versions, never `latest`" | **Done** | Exact tags throughout: `caddy:2.8-alpine`, `grafana/loki:3.6.13`, `grafana/alloy:v1.18.0`, `grafana/grafana:13.1.1`, `louislam/uptime-kuma:2.3.2`, `woodpeckerci/woodpecker-*:v3.16.0`. (Age is a separate problem — **P11**) |
| "Add `no-new-privileges:true`" | **Done — one exception** | Present on 15 of 16 containers. `woodpecker-agent` lacks it, matching the committed compose — but that flag is the *least* significant part of its exposure. See **P6** before "fixing" it |
| "Set resource limits" | **Done** | Memory **and** cpu limits on all 16 running containers, tenants included. Oversubscription is **P8** |
| "Add per-container log rotation" | **Done — including tenants** | Verified on the box: all 16 containers report `logopts=map[max-file:3 max-size:10m]`. The uncovered set is CI *step* containers only — **P8** |
| "Enable Loki retention, it's off by default" | **Done, and proven empirically** | Not just config: a 10-day query returns nothing older than 7 days + 1 h on any stack. The compactor is deleting. `loki-data` is **14.49 MB** — log volume is not a disk concern here |
| "Keep Loki labels low-cardinality" | **Done** | Two labels, `stack` + `service` |
| "Provision Grafana datasources instead of click-ops" | **Done** | `observability/grafana/provisioning/datasources/loki.yml` |
| "Add a `.gitignore`, never commit `.env`" | **Done** | Blocks `*.env`, `*.key`, `*.pem`, `id_ed25519*`; committed config carries only `${VAR:?required}` references |
| "Don't expose management interfaces publicly" | **Done, verified** | `ss -tlnp` shows public listeners are **only** `:22`, `:80`, `:443`. Grafana/Loki/both Postgres bind `127.0.0.1`; Woodpecker gRPC binds the Tailscale address. The "Docker bypasses ufw" hazard has **no surface here** |
| "Remove the `Server` header" | **Partly — 2 of 3 sites** | `-Server` / `-X-Powered-By` in `logs.` and `uptime.` snippets. **`ci.aneskurtovic.caddy` has no `header` block at all** — no HSTS, no `nosniff`, no `-Server`. Corrected in **P18**; the original "Done" here was wrong |
| "Ensure time sync is running" | **Done** (distro default) | `timedatectl`: `System clock synchronized: yes`, `NTP service: active` |
| "Kernel hardening via sysctl" | **Already sane** (distro default) | `tcp_syncookies=1`, `rp_filter=2`, `accept_redirects=0`. `bootstrap.sh` sets only `vm.swappiness=10`, so these are inherited, not asserted — see **P20** |
| "Add healthchecks everywhere" | **Done, 2 deliberate exceptions + 1 real gap** | Loki (no HTTP client in image) and Alloy are documented exceptions. `ludo-simulator` genuinely lacks one — **P13** |
| "Harden SSH, ufw, fail2ban, unattended upgrades" | **Done** | `host/bootstrap.sh`; fail2ban confirmed active and working |
| "Use Alloy, Promtail is EOL" | **Done** | Alloy `v1.18.0` |
| "Watch for config drift" | **Zero drift found** | Every readable platform file on the box is byte-identical to repo HEAD (SHA-compared). The only mismatch was a CRLF artifact of the Windows checkout |

## Rejected on the merits

**Restructure into `ci/woodpecker/`.** The additive parts of that tree
(`backups/`, `secrets/`) are fine and will appear when something lands in them —
a directory holding a README that promises future work is worse than no
directory. The **rename** is rejected: it invalidates 27 commits of history and
every runbook path in exchange for a tidier tree. Churn on a working layout is
not an improvement.

**Watchtower, or any unattended auto-update of running containers.** Silently
replacing a pinned production container at 03:00 converts a controlled upgrade
into a morning outage of unknown cause. Update *notification* is welcome — **P11**.

**Kubernetes, Nomad, Consul, Vault, Mimir, distributed Loki, Ceph.** All three
reviews independently say don't, and they are right. One box, one operator.

**Rootless Docker.** Not now. Both the CI agent and the log collector need the
socket; converting them is a project with a real chance of breaking CI, and
**P6** addresses the same exposure more honestly.

---

# Items

## P1 — Everything the platform owns is one disk failure from gone · **Critical**

> **Status 2026-08-22 — the fix is committed, and the box is unchanged.** The
> platform backup stack now exists in [`backup/`](backup/): a nightly restic
> snapshot of every platform volume and secret file, fourteen daily generations,
> weekly `prune` + `check`, a tenant hand-off directory, a restore drill, and
> [`DISASTER-RECOVERY.md`](DISASTER-RECOVERY.md).
>
> **Nothing has been installed or run.** No repository exists, no snapshot has
> been taken, and no restore has been attempted, so every number in the evidence
> below is still true of the live box. This item stays **Critical** and stays
> open. The remaining work is not writing code — it is
> `backup/install.sh`, one repository, one password stored off-box, and the
> drill. See "Done when" for exactly what is left.

**Problem.** A nightly Postgres dump exists and is well-engineered. It is also
the *only* backup on the box, it belongs to a tenant, it keeps **one
generation**, and it writes to **the same disk it protects against**. Every
volume the platform itself owns has no backup at all.

**Evidence (2026-08-19).** `ludo-backup.timer` runs nightly at 04:00 and
succeeded this morning. `backup-db.sh` is genuinely careful — atomic temp-file
swap, `pg_restore -l` validation, a >1 MB size floor, and an explicit guarantee
that a partial dump can never destroy the last good one. Then:

```bash
DIR=/opt/ludo/backups
DEST="$DIR/ludo_prod_latest.dump"     # ONE file, overwritten nightly
```

What is lost if the disk dies right now:

| State | Size | Backed up? |
| --- | --- | --- |
| `ludo-postgres-data` (prod) | 6.633 GB | Dump exists — **on the same disk**. Off-box: **no** |
| `ludo-postgres-stage-data` | 71.5 MB | **No** — not in the script |
| `woodpecker-server-data` | 112.1 MB | **No** — OAuth state, agent secret, every per-repo deploy secret |
| `caddy-data` | 90.4 MB | **No** — ACME account key + every certificate |
| `grafana-data` | 90.3 MB | **No** |
| `uptime-kuma-data` | 4.6 MB | **No** — the repo itself calls this "precious" |
| `/opt/ci/*.env`, `/opt/caddy/caddy.env`, `/opt/observability/observability.env` | — | **No** |

No restic, no borg, no off-box target, no restore drill. `crontab -l` is empty;
`/etc/cron.d/` holds only distro defaults; no backup timer exists besides
`ludo-backup`.

Two aggravating details:

- **Single-generation retention.** A corruption discovered on day 2 has no clean
  copy — the good one was overwritten at 04:00.
- **`woodpecker/BOOTSTRAP.md` used to delegate to a "host backup system" that
  does not exist.** Corrected on 2026-08-19 to a real manual procedure, but the
  underlying gap is this item.

**Shape of the fix.** A platform-owned `backup/` stack — now written, see
[`backup/README.md`](backup/README.md):

- **restic** to a Hetzner Storage Box or S3-compatible bucket, repository
  encrypted, password held root-only under `/opt`. Restic gives dedup,
  encryption, `restic check` integrity verification, **and multiple generations**
  — the last of which the current script structurally cannot.
- A **systemd timer**, so failures land in the journal Alloy ships to Loki,
  making "the backup failed" queryable rather than silent.
- A **tenant hand-off contract**: a documented directory a tenant's pre-backup
  hook writes a consistent dump into, which the platform sweeps off-site. The
  platform never learns what Postgres is; Ludo never learns what restic is.
- Note that `/opt/backups` does not currently exist; `/opt/ludo/backups` (0700)
  is the tenant's own. Create the platform's root-only and keep them distinct.

**One assumption in the sketch above was wrong, and is fixed alongside it.**
"the journal Alloy already ships to Loki" — Alloy shipped no journal at all.
`alloy/config.alloy` had a `loki.source.docker` and nothing else, so a systemd
timer's failure would have gone to the journal and stopped there, invisible in
Grafana, which is the exact silence this item is about. A `loki.source.journal`
scoped to the platform's own units now exists; see **P4** for why it is scoped
rather than shipping all 2.4 GB of journal.

**Done when.**

| # | Check | State |
| --- | --- | --- |
| 1 | A scheduled run completes unattended and `restic snapshots` shows it | **open** — nothing installed |
| 2 | **≥7 daily generations** are retained, not one | written (`BACKUP_KEEP_DAILY=14`), unproven |
| 3 | `restic check` passes on a schedule, and failure is visible in Grafana | written (weekly timer, journal → Loki); the *alert* still needs **P3**/**P4** |
| 4 | **A restore has actually been performed** into a scratch volume, verified, dated | **open** — `backup/restore-drill.sh` exists, `backup/OPERATIONS.md` § Restore drill log says "never performed" |
| 5 | `DISASTER-RECOVERY.md` exists: bootstrap → restore secrets → restore volumes → re-point DNS | ✅ done |

Item 4 is the one that matters. Until it has a date, this stack is automation
that has never been asked to produce the thing it exists for, and item 1 going
green will make it *look* finished.

**Not this.** Not backing up Loki — 7-day triage data, and `OPERATIONS.md`
already settled that. Not backing up tenant databases directly. Not Hetzner
snapshots as the strategy: same-provider, and per Hetzner's docs attached Volumes
are excluded from server backups.

## P2 — The platform's disk safety is owned by a tenant · **High**

**Problem.** The only mechanism preventing disk exhaustion on this box is a
systemd timer installed by **Ludo's deploy script**. A change in a tenant repo
can silently remove the platform's sole disk-reclamation mechanism. This is the
tenant boundary inverted: the platform depends on an application for its own
survival.

**Evidence (2026-08-19).** Disk is 26 G / 38 G (**72%**), 11 G free.

```
ludo-docker-cleanup.timer   Sun *-*-* 05:00   last: Sun 2026-08-16 (SUCCESS)
  → docker builder prune -af
  → docker image prune -af --filter "until=168h"
```

```
docker system df
TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
Images          28      15      7.498GB   6.215GB (82%)
Build Cache     76      0       2.675GB   2.537GB
Local Volumes   18      14      7.387GB   258.9MB
```

Build cache regrew **2.675 GB in 3 days** — roughly **890 MB/day of CI churn**.
The weekly sawtooth is currently stable (prune reclaims ~2.5 GB/week, CI adds
~2.7 GB/week, net drift near zero) **while the timer works**. If it fails, is
disabled, or is dropped by a tenant deploy: **~12 days to a full disk.**

Nothing observes any of this. The 72% figure required an SSH and a `df` to find.

**Shape of the fix.** Move build-cache and image reclamation into a
platform-owned unit installed by `host/bootstrap.sh`, alongside the journal cap
in **P8**. The tenant's timer can remain for tenant-specific concerns, but the
platform must not depend on it. Then graph disk (**P4**) so the sawtooth is
visible and a broken timer shows up as a trend, not a surprise.

**Done when.** A platform-owned unit reclaims build cache on a schedule,
`bootstrap.sh` installs it idempotently, disk % is graphed with an alert below
85%, and removing the tenant's timer changes nothing about platform safety.

**Not this.** Not resizing the volume as the primary answer — that buys time and
teaches nothing. Not pruning volumes automatically; the existing script's
"NEVER prunes volumes" rule is correct, and the leaked volumes in **P12** should
be removed deliberately.

## P3 — Nothing alerts. Production failed twice and nobody was told. · **High**

**Problem.** The box has monitoring that records failures and no path from a
recorded failure to a human. This is worse than having no monitoring, because it
looks like coverage.

**Evidence (2026-08-19).** Uptime Kuma's own log:

```
2026-08-05  Monitor #2 'Production Backend + Database': timeout of 24000ms exceeded
2026-08-10  Monitor #2: Request failed with status code 525
2026-08-17  Monitor #2: Request failed with status code 502
2026-08-18  Monitor #2: Request failed with status code 502
```

**Four failures across two weeks, including two 502s in the last 48 hours.**
Every line reports `Resend Interval: 0`, which suggests no notification channel
is attached — that specific inference is unproven (the monitor list lives in the
root-only SQLite DB), but the outcome is not in doubt: production failed on
Aug 17 and Aug 18 and it took a forensic audit to discover it.

Grafana's side is equally quiet:

```
logger=provisioning.alerting level=error msg="can't read alerting provisioning files
  from directory" path=/etc/grafana/provisioning/alerting error="no such file or directory"
logger=ngalert.state.manager msg="State cache has been initialized" states=0
```

No `provisioning/alerting/` exists in the repo, and zero alert states at last
container start.

**Shape of the fix.** The cheap half first: attach a notification channel to
Kuma (Discord/Telegram webhook is enough) and confirm it fires. Then provision
Grafana alert rules from the repo under
`observability/grafana/provisioning/alerting/`, committed rather than clicked —
matching how `loki.yml` is already handled.

Note the dependency: with no metrics datasource (**P4**), the only signal Grafana
can currently alert on is Loki log volume. Kuma is the near-term alerting path;
Grafana becomes useful for alerts once P4 lands.

**Done when.** A deliberately failed monitor produces a notification off-box
within a stated window, and the Aug-17-style 502 would now reach someone.

**Not this.** Not building a paging rotation. Not alerting on everything — start
with "production is down" and "the backup failed."

## P4 — No metrics backend, so none of P2 or P8 is visible · **High**

**Problem.** The observability stack collects *logs* and nothing else. There is
no time-series database, so there is no CPU, memory, disk, swap,
container-restart, or certificate-expiry signal anywhere — and nothing to alert
on. Every number in this backlog had to be found by hand over SSH. That is the
finding: not that the box is unhealthy, but that its health is unobserved.

**Evidence (2026-08-19).** `alloy/config.alloy` contains only
`discovery.docker`, `discovery.relabel`, `loki.source.docker`, `loki.write`. No
`prometheus.exporter.unix`, no `prometheus.scrape`, no remote-write. No
Prometheus, Mimir, or VictoriaMetrics container exists.
`observability/grafana/provisioning/datasources/` holds only `loki.yml`.

*Updated 2026-08-22:* `loki.relabel` + `loki.source.journal` were added for the
backup units (**P1**). That is still only logs — every word above about metrics
is unchanged, and the journal source is scoped to a keep list precisely so it
does not become a way to pretend otherwise. "The backup failed" is now a log
line you can query; "disk is at 87%" is still nothing at all.

**Shape of the fix.** Alloy is already running and is one block away from host
metrics: `prometheus.exporter.unix` (node_exporter built in) and
`prometheus.exporter.cadvisor` for per-container usage. That leaves only storage.
**VictoriaMetrics** suits a 4 GB box better than Prometheus — materially lower
RAM for the same data — though either is defensible. Provision the datasource
from the repo, as `loki.yml` already is.

The alerts that would have caught what this audit found by hand:

| Alert | Why this one |
| --- | --- |
| Disk > 80%, > 90% | **P2** — the sawtooth, and a broken cleanup timer |
| Swap in use / memory pressure | **P8** — 588 MB already swapped |
| Container restart loop | `ludo-simulator` has no healthcheck (**P13**) |
| Certificate expiry < 14 days | Caddy auto-renews, but silently stops if ACME breaks |
| Backup stale / failed | **P1** is worthless if its failures are silent |

**Done when.** Grafana shows disk, memory, and swap for the host; the disk and
backup alerts fire to a real channel; and datasource + rules are committed under
`observability/grafana/provisioning/`.

**Not this.** Not Mimir, not remote write, not a second Grafana. Not
application-level metrics — that is each tenant's call. Retention should be short
and stated, for the same reason Loki's is.

## P5 — Secrets are readable at runtime, and die with the box · **High**

**Problem.** Two separate weaknesses in one system.

**(a) Runtime exposure.** The repo's principle — *"real values live in root-only
files on the host"* — holds for **git**, and does not hold at **runtime**. The
`claude` user has no sudo and cannot read `/opt/ci/agent.env` (mode `0600 root`),
yet can read its entire contents via `docker inspect woodpecker-agent`. The same
applies to the production Postgres password, which appears in plaintext in two
places: `ludo-postgres`'s `POSTGRES_PASSWORD` and `ludo-backend`'s connection
string.

Docker group membership is root-equivalent, so this is not privilege escalation.
The point is that the root-only-file control provides **no defense in depth at
runtime**: anything with docker access exfiltrates prod credentials in one
command, and several non-sudo accounts have docker access.

**(b) Single-copy survivability.** Those files exist in exactly one place. Disk
loss takes every secret with it. The three `.env.example` files are a genuinely
useful partial inventory — they name each variable and its host file — but the
hard-to-reissue parts are uncovered: `WOODPECKER_GITHUB_SECRET`,
`WOODPECKER_AGENT_SECRET`, and above all the **per-repository deploy secrets
stored inside `woodpecker-server-data`**, which nothing enumerates. After a
rebuild there is no way to know which repos are missing which credentials until a
pipeline fails.

**Evidence (2026-08-19).** Confirmed by read-only `docker inspect` as the
non-sudo `claude` user. Values are deliberately not reproduced here or anywhere
in the repo. Also found: stale `0600` copies of secret-bearing files accumulating
with no expiry — `/opt/ci/.env.bak.20260810101211`,
`/opt/ludo/app/.env.bak.20260707-142033`,
`/opt/ludo/app/.env.pre-uptime-kuma.20260715T154630Z.bak`.

**Shape of the fix.**

1. **Rotate** the Woodpecker agent secret and the prod Postgres password. They
   have been read during this audit; treat them as exposed.
2. Move Postgres to Docker secrets or the `_FILE` env convention so the value is
   never in container config. (Tenant-side for the DB; platform-side for the
   agent secret.)
3. **SOPS + age** for survivability — an encrypted `secrets/*.sops.env` can live
   in this public repo safely because the age private key never does. Keep that
   key off-box with the operator; it is the one thing whose loss is
   unrecoverable. This composes with **P1**: an encrypted file is just another
   thing restic ships.
4. Cheap and worth doing regardless: a committed **inventory** of which secrets
   must exist and how to reissue each. That turns a rebuild from archaeology into
   a checklist.
5. Sweep the stale `.env.bak.*` files — they widen the window in which a rotated
   secret is still recoverable on disk.

**Done when.** `docker inspect` reveals no password or token; both exposed values
are rotated; every host secret is either encrypted-committed or listed in a
reissue inventory; and a dry run can name every value needed to rebuild from bare
metal.

**Not this.** Not Vault, not a secrets daemon. Not putting the age key in the
repo, in a note, or on the box being backed up.

## P6 — The CI blast radius is the socket, not the missing flag · **High (accepted)**

**Problem.** `woodpecker-agent` mounts `/var/run/docker.sock` **read-write** — it
must, to create step containers — which makes its network isolation decorative.
It is also the one platform service with no `security_opt` block, but that is the
least important part of this item.

**Evidence (2026-08-19).** The agent is attached to `ci-network` **only** and
genuinely cannot reach `ludo-network` at layer 3. That containment is illusory.
With a read-write socket the agent can:

- create a container attached to `ludo-network` and reach `ludo-postgres:5432`;
- read `POSTGRES_PASSWORD` via `docker inspect`, with no network access at all
  (**P5**);
- mount host `/` into a new container;
- read `caddy-data` (every private key) and `woodpecker-server-data` (every
  deploy secret).

Confirmed: `woodpecker-agent` reports `no-new-privileges` as `<no value>`,
matching the committed compose. `alloy` mounts the same socket **read-only** and
*does* carry the flag — the collector is the better-hardened of the two.
`WOODPECKER_MAX_WORKFLOWS=1` is in effect.

The compose comment — *"Workflow containers do NOT inherit it — keep the repo
untrusted"* — is accurate about **step** containers and understates the
**agent's** own reach.

**Shape of the fix.** Be honest in the docs first: the real control bounding a
compromised build is **who can trigger a pipeline** (`WOODPECKER_OPEN=false`,
`WOODPECKER_REPO_OWNERS`, repo-scoped secrets), not the agent's network. State
that in `BOOTSTRAP.md`, replacing the implication that `ci-network` isolation
constrains anything.

Add `security_opt: [no-new-privileges:true]` to the agent for consistency — cheap
and harmless — but do not describe it as mitigation.

The structural answer, when the box grows: the CI runner is the first service to
move to a second host, ahead of Grafana or Caddy. Not now; record the direction.

**Done when.** `BOOTSTRAP.md` states the actual trust boundary, including that
the agent can reach tenant data despite its network; the agent has the flag or a
comment saying why not; and the off-box Windows agent's equal trust level is
written down.

**Not this.** Not rootless Docker. Not removing the socket — the Docker backend
requires it. Not a second host yet.

## P7 — Docs described a box that no longer exists — ✅ **DONE 2026-08-19**

**Kept as a record, not as open work.**

**Problem.** The repo's thesis is *"committed is not deployed… the box describes
its actual shape, and they drift."* The drift had caught the docs that teach it.
Eight files described the pre-migration world as current.

Worth noting alongside: the forensic pass found **zero config drift** — every
readable platform file on the box is byte-identical to repo HEAD. The drift was
entirely in prose, which is the harder kind to notice.

**What was wrong.**

- `README.md` — claimed Grafana sits behind Basic auth. Removed in `ed7e920`
  because it broke login: the browser keeps sending `Authorization: Basic …`,
  which outranks Grafana's session cookie and 401s a correctly logged-in user.
- `observability/OPERATIONS.md` — said the snippet was "not active", the box
  "still runs `ludo-caddy`", and "`/opt/caddy` does not exist". All false since
  2026-08-10. Its "two authentication gates" section described a gate that no
  longer exists.
- `observability/MIGRATION.md` — a "Why no public route yet" note asserting the
  platform Caddy had never been deployed.
- `uptime-kuma/MIGRATION.md`, `uptime-kuma/OPERATIONS.md` — both said the edge
  proxy was "currently `ludo-caddy`; will become a platform Caddy later."
- `caddy/.env.example` — presented `GRAFANA_USERNAME` / `GRAFANA_PASSWORD_HASH`
  as the live "OUTER gate". Unused since `ed7e920`.
- `observability/.env.example` — "this is the inner gate. The outer one is Caddy
  basic_auth." There is no outer one.
- `woodpecker/BOOTSTRAP.md` — told you to "back up the volume with the host
  backup system," which **does not exist** (**P1**). Replaced with a working
  manual procedure, including creating `/opt/backups` mode `700` first, since a
  bind mount would otherwise create it world-readable for archives containing
  every deploy secret in the clear.

**A real bug, not just staleness.** Commit `64977e6` fixed
`docker exec caddy caddy hash-password` dying with a bare `Error: EOF` — it
prompts on stdin, and without `-it` gets a closed one. The fix was applied to
`caddy/MIGRATION.md` **only**. The same command, still missing `-it`, survived in
`caddy/.env.example` and `uptime-kuma/OPERATIONS.md`. Both now fixed.

**Deliberately left alone.** Kuma's `## The outer authentication gate` still
asserts a gate — correctly. That snippet kept its `basic_auth`, and
`caddy/docker-compose.yml` still resolves `UPTIME_KUMA_PASSWORD_HASH`. Only
Grafana dropped its gate, because only Grafana consumes the `Authorization`
header itself. The two must not be blanket-edited together. Loopback SSH-tunnel
instructions were kept everywhere: still true, and still the right advice when
the proxy is the broken thing.

**The lesson worth keeping.** A fix applied to the file where a bug was *hit*,
rather than to every file carrying the same instruction, leaves the trap armed
elsewhere. When a runbook command is corrected, grep the repo for that command
before closing it out.

## P8 — Journal, daemon defaults, and a 124% memory commitment · **Medium**

Three host-level gaps that share a cause: `bootstrap.sh` configures ufw, swap,
fail2ban, and unattended-upgrades, but never touches journald or Docker's daemon
config.

**(a) The journal has no cap.** `journalctl --disk-usage` reports **2.4 GB**.
`/etc/systemd/journald.conf` is entirely default — every line commented. With no
`SystemMaxUse=`, journald defaults to **10% of the filesystem ≈ 3.8 GB** here. It
will grow another ~1.4 GB before self-capping. It will not fill the disk alone,
but that is 10% of the volume permanently spent on logs Alloy is *also* shipping
to Loki.

The driver is relentless SSH scanning — `kex_exchange_identification` resets and
`maximum authentication attempts exceeded for root` dominate the error log.
fail2ban is active and working; it cannot stop the connection attempt from being
logged. `/var/log/dmesg.0` is 92 MB and `btmp`+`btmp.1` are 49 MB of failed
logins.

> **Measurement gotcha worth keeping:** as the `claude` user,
> `journalctl --disk-usage` reports 161.7 M — that is only the *user* journal.
> The real figure needs `claude_ro`'s `systemd-journal` membership. Check as
> `claude_ro`.

**(b) No `/etc/docker/daemon.json`.** This is **not** the tenant-container problem
it first appears to be — all 16 long-running containers, tenants included, carry
`max-size: 10m` / `max-file: 3` (worst case 16 × 30 MB = 480 MB, matching the
observed 580 MB). The genuinely uncovered set is **Woodpecker step containers**,
created through the Docker API with `logopts=map[]` — the unbounded daemon
default. Measured live steps were tiny (6.8 KB, 4.0 KB), so the risk is a single
pathological build looping on stderr with nothing to stop it.

Also `Live Restore Enabled: false` — a daemon restart currently drops every site.

**(c) Memory is committed at 124%.** Limits sum to **4,736 MB** on a **3,819 MB**
box, plus 2 GB per CI step on top. Actual usage is comfortable (`ludo-postgres`
265 MiB, `loki` 198 MiB, `ludo-backend` 183 MiB, `grafana` 180 MiB, everything
else under 135 MiB) and there have been **zero OOM events in 15 days**. Docker
limits are ceilings, not reservations, so this is not a bug. But **588 MB of swap
is already in use** with `vm.swappiness=10`, meaning the box has been under real
memory pressure at some point, and there is no arbiter if a CI step claims its
full 2 GB while services drift toward their ceilings.

**Shape of the fix.** Set `SystemMaxUse=` (500 M is generous given Loki) and a
`daemon.json` with a log-size default plus `live-restore: true`, both written
idempotently by `bootstrap.sh` — it already re-heals drifted settings by design.
Name both in `host/README.md`'s "what belongs here" table. For memory, decide
whether 124% is intentional headroom-by-statistics or wants trimming; either way
graph swap (**P4**) so pressure is visible.

Note the daemon log default applies to containers created **after** reload;
existing ones keep their setting until recreated.

**Done when.** `journalctl --disk-usage` stays under its cap, `daemon.json` is
present and installed by bootstrap, a fresh CI step container shows a log limit,
and swap is graphed.

**Not this.** Not disabling the journal — it is the record when Loki is the thing
that is broken. Not editing tenants' compose files; they are already correct.

## P9 — 12 days on an unpatched kernel, and rebooting is not free · **Medium**

**Problem.** A kernel update is installed and waiting for a reboot nobody has
scheduled — on a public-facing box. Worse, the reboot itself carries a known
coupling that makes it something to plan rather than fire off.

**Evidence (2026-08-19).**

```
$ cat /var/run/reboot-required.pkgs        $ uname -r
linux-image-6.8.0-137-generic              6.8.0-136-generic
linux-base                                 (flagged Aug 7 — 12 days)
```

`unattended-upgrades` is active and installed the kernel; it cannot reboot into
it. The box has been up 15 days.

**The coupling:** `woodpecker-server` binds `100.120.41.12:9000` — the Tailscale
address. Its own compose comment warns that *if `tailscaled` has not come up yet
after a reboot the bind fails and this container restart-loops until it does.*
That is intended behaviour ("loud and closed beats quietly reachable"), but it
means a reboot needs a post-boot check. `Live Restore Enabled: false` (**P8**)
compounds it.

**Shape of the fix.** A maintenance-window procedure in `host/README.md`: check
`/var/run/reboot-required`, reboot, then verify `tailscale ip -4` resolves,
`woodpecker-server` is healthy rather than restart-looping, all sites serve, and
both Postgres containers came back. Then track reboot-required as a monitored
signal once **P4** exists.

**Done when.** The box runs the current kernel, and a documented post-reboot
checklist exists that names the Tailscale/gRPC ordering hazard.

**Not this.** Not automatic reboots — the Tailscale coupling is exactly why
`unattended-upgrades` should not be handed that job here.

## P10 — The monitor lives on the box it monitors · **Medium**

**Problem.** Uptime Kuma runs on the host it watches. Any failure that takes the
box down also takes down the monitor whose job is to report it. The result is
silence, indistinguishable from healthy. Grafana, Loki, and Alloy share this
fate: the log UI you would use to investigate an outage is inside the outage.

`uptime-kuma/OPERATIONS.md` already has an `## Availability limitation` section
admitting this. The gap is that admitting it is where the story ends.

**Evidence (2026-08-19).** `uptime-kuma` is one of 16 containers on this single
box.

**Shape of the fix.** One external heartbeat, which costs nothing: a dead-man's
switch (healthchecks.io, Better Stack, or a cron on any other machine) that Kuma
pings on a schedule. If the ping stops, the external service alerts. That inverts
the failure — silence becomes the alarm rather than the bug. A second Kuma on
another VPS is the heavier option and is not required.

This depends on **P3**: a heartbeat is only useful once *something* can notify.

**Done when.** Killing the Kuma container produces an external notification
within a stated window, and the availability-limitation section describes the
heartbeat rather than only naming the problem.

**Not this.** Not moving the whole observability stack off-box. Not a second
Hetzner box in the same datacentre — that shares the failure domain that matters.

## P11 — Pinned versions with no staleness signal · **Medium**

**Problem.** Every image is pinned, which is correct. The cost of pinning is that
nothing tells you an update exists — including a security update. Left alone,
"pinned" quietly becomes "running a two-year-old TLS terminator."

**Evidence (2026-08-19).** That is not hypothetical:

```
caddy:2.8-alpine   49.2MB   2 years ago
```

`caddy` is the **oldest image on the box by a wide margin** and the **only
container terminating TLS on the public internet**. Everything else is current:
`loki:3.6.13` (3 weeks), `grafana:13.1.1` (4 weeks), `alloy:v1.18.0` (4 weeks).
No Renovate config or update-notification mechanism exists anywhere in the repo.

**Shape of the fix.** **Renovate** raising PRs against this repo for compose image
tags — a PR is a notification carrying a diff and a changelog link, and merging
stays a human decision followed by a deliberate `docker compose up -d`. That
preserves the property the rejections defend: nothing updates itself. **Diun** is
the lighter alternative if notification alone suffices.

Upgrade Caddy as the first act, in a window — it owns `:80/:443` for every site,
so it is simultaneously the most urgent and the most delicate.

Consider digest pinning for core infrastructure images afterwards; a digest is
genuinely immutable where a tag is only conventionally so.

**Done when.** A new upstream release of any pinned image produces a visible PR
or notification within a day, Caddy is on a supported release, and each runbook's
upgrade path still describes a human running `compose up -d`.

**Not this.** Not Watchtower. Not auto-merge.

## P12 — Reclaim ~750 MB of dead weight and close Caddy Phase 5 · **Low**

**Problem.** Several finished migrations and CI runs left resources behind. None
is urgent; together they are most of a gigabyte, and one of them is a foot-gun.

**Evidence (2026-08-19).**

| Leftover | Size | Note |
| --- | --- | --- |
| `ludo-caddy-data` | 119.1 MB | Phase 5 `docker volume rm` never run; cutover was 9 days ago and the runbook said keep for a week |
| `ludo-caddy-config` | 10.2 KB | same |
| `ludo-uptime-kuma-data` | 2.3 MB | same |
| `voxmux-cargo-registry` | 137.5 MB | Orphan from an unrelated project; matches nothing on the box or in the repo |
| 2 × `wp_*` step containers + 2 volumes + 1 network | 111 MB | From a workflow **16 days ago**. `docker-cleanup.sh` explicitly never prunes volumes, so these leak permanently |
| `ludo-rollback-stage-*:cdc0c1a6` | 338 MB | **16 days old**, referenced by no container, and *survived* the `until=168h` prune that ran successfully on Aug 16 when they were already 13 days old |

Two consequences worth naming:

- **`docker system df` under-reports** reclaimable space, because the exited
  `wp_*` containers still hold links on their volumes.
- **Alloy is still trying to tail the dead step containers every 5 s**, emitting
  `error inspecting Docker container … No such container` into the platform's own
  log stream.

**The foot-gun:** `/opt/caddy-sites.next` still exists beside the live
`/opt/caddy-sites`, and is stale by exactly one file — `logs.aneskurtovic.caddy`,
which landed at 18:42 on Aug 10, hours after `.next` was staged at 11:29.
Re-running Phase 0 staging today would validate a config **missing Grafana's
site**. This is precisely the rot `caddy/MIGRATION.md` warns about, now
materialized.

Rollback images also live longer than intended: a weekly prune with a 7-day
filter gives them an effective lifetime of up to **14 days**, so ~600 MB of prod
rollback images is held rather than ~300 MB.

*Unresolved:* why the Aug-3 stage images escaped a prune they were long past the
filter for could not be determined without mutating experimentation. Worth
finding before trusting the filter.

**Shape of the fix.** Run Phase 5 as written, delete the four orphan volumes,
remove the stale `wp_*` resources, and either refresh or delete
`/opt/caddy-sites.next` — do not leave it stale. Add a dated log line to
`caddy/MIGRATION.md` recording the close-out, matching the entry style already
there, and state Phase 4's status explicitly rather than leaving it inferred.

**Done when.** `/opt/caddy-sites.next` is gone or current, the orphan volumes are
removed, Alloy stops logging inspect errors, and every site still serves.

**Not this.** Not deleting the runbook — it documents a repeatable procedure and
a genuine near-miss history. Not enabling automatic volume pruning.

## P13 — Small, cheap, and each a stated principle not held · **Low**

Individually trivial; grouped because each is a one-line fix.

- **Alloy phones home every 4 hours.** `msg="usage report sent with success"`,
  twice in the last 8 hours. The repo sets `GF_ANALYTICS_REPORTING_ENABLED: false`
  on Grafana with the comment *"Nothing here should phone home from a personal
  box"* — the same principle was not applied to Alloy, which needs
  `--disable-reporting` on its `command:`. A stated principle silently unheld.
- **`/opt/ludo/data` is `0777`.** Dated February, predating the platform split.
  Any local user — `claude`, `claude_ro`, `deploy`, `helideploy` — can write to
  it. `/opt/ludo/backups` is correctly `0700`. Tenant-owned, but worth raising.
- **`ludo-simulator` has no healthcheck** — the only container lacking one that
  is not a documented exception, and it is the process generating ~190k DB
  events/day. If it wedges, nothing notices.
- **CI step logs are unscoped.** 14 `wp_*` entries appear in Loki's `container`
  label values with no `stack` label, as `config.alloy` predicts. Harmless by
  design, but they count against `max_query_series: 500` on broad queries.
- **Human-room game events grow forever.** `purge-bot-events.sh` correctly caps
  bot-room events at 7 days using positive membership in the bot-only set, so
  human rooms accumulate indefinitely — at a far lower rate. Not a risk today;
  worth a monthly size trend once **P4** exists.


---

# Direction — proposals from the three reviews

Items P1–P13 came from measuring the box: things that are broken, unbounded, or
unobserved *today*. The three external reviews also proposed a set of **forward**
changes that are not defects and would not show up in any audit. They are
collected here so they are not lost, and so the difference is explicit: nothing
below is currently failing.

Sequencing note — `ChatGPT.txt` proposes "restic → Prometheus/alerts → SOPS/age →
host/IaC hardening" as the next four commits. That maps to **P1 → P4/P3 → P5 →
P19/P20**, and it is a good order. The items below mostly slot in after that.

## P14 — The admin plane is public, though the VPN is already running · **Medium**

**Problem.** Grafana, the CI UI, and the uptime dashboard are published on the
public internet and defended by passwords. SSH is likewise open to the world.
Every one of these is used by exactly one person, who already has a working
tailnet — so the exposure buys nothing.

`ChatGPT.txt` and `GoogleAI.txt` both raise this independently, and it is the one
proposal where this box is already 90% of the way there.

**Evidence (2026-08-19).** `tailscaled` is **active**, and Woodpecker's gRPC port
already binds the tailnet address `100.120.41.12` — the pattern is established
and working. Meanwhile `ss -tlnp` shows `0.0.0.0:22` open to the internet, and
the cost of that is measurable: the 2.4 GB journal in **P8** is largely
`kex_exchange_identification` resets and `maximum authentication attempts
exceeded for root`. fail2ban is active and working; it cannot stop the connection
from being logged.

**Shape of the fix.** Two independent steps, easiest first:

1. **Take SSH off the public internet.** Restrict `:22` to the tailnet (Hetzner
   Cloud Firewall is the belt-and-braces layer, since it filters before packets
   reach the box). This alone removes the journal's dominant write source.
2. **Move the admin UIs behind the tailnet** — Grafana first, since **P7**
   records that it now runs on a single auth gate over *every tenant's* logs.
   The public sites (`aneskurtovic.com`, `helifilm`, the Ludo app) obviously stay
   public; `logs.`, `ci.`, and `uptime.` need not be.

**Done when.** `:22` is unreachable from a non-tailnet address, and at least
Grafana is reachable only over the tailnet — with the loopback SSH tunnel still
documented as the break-glass path (**P7** keeps it deliberately).

**Not this.** Not Headscale — Tailscale is already running and works. Not
removing the public sites. Not relying on the Hetzner firewall *instead* of ufw;
use both.

## P15 — One identity for the admin UIs · **Low–Medium**

**Problem.** Three admin surfaces, three separate credential sets: Grafana's own
login, Kuma's own login plus its outer Caddy `basic_auth`, and Woodpecker's
GitHub OAuth. Rotating anything means remembering which file holds which value —
`observability/OPERATIONS.md` already warns that this is "a common source of
confusion when rotating."

`GoogleAI.txt` proposes Authelia/Authentik with Caddy's `forward_auth`.

**Evidence (2026-08-19).** Three different mechanisms in three different places.
More pointedly: `caddy/logs.aneskurtovic.caddy` already reaches this conclusion
on its own, having been forced to drop Grafana's outer gate — *"If that stops
being acceptable, add SSO/OAuth in GRAFANA rather than a second HTTP gate here —
one login, and no header collision."*

**Shape of the fix.** Two routes, and the cheaper one may be enough:

- **Cheap:** configure Grafana's built-in **GitHub OAuth**. You already run a
  GitHub OAuth app for Woodpecker and `WOODPECKER_REPO_OWNERS` already encodes
  "who is allowed." This gives Grafana a real identity with no new service, and
  is exactly what the Caddy snippet recommends.
- **Heavier:** Authelia or Authentik behind `forward_auth`, covering Kuma too and
  adding 2FA. That is a new stateful service to run, back up (**P1**), and keep
  patched — weigh it against having two users, one of whom is a bot.

**Note the interaction with P14.** If the admin plane moves behind the tailnet,
much of the argument for SSO weakens — the tailnet becomes the outer gate. Do
**P14 first**, then re-evaluate whether this is still worth the moving parts.

**Done when.** Either Grafana authenticates against GitHub, or a decision is
recorded that the tailnet (**P14**) is the answer and this item is closed.

**Not this.** Not another HTTP `basic_auth` layer in front of Grafana — that
specific approach is settled and documented as broken.

## P16 — The platform runs CI and does not use it on itself · **Medium**

**Problem.** This repo's whole thesis is that CI belongs to the platform, and
every tenant deploys through Woodpecker. The platform itself does not: changes to
`docker-compose.yml`, the `Caddyfile`, or `loki-config.yml` reach the box because
a human copies them there and runs `compose up -d`. That is the mechanism that
produced the drift **P7** just cleaned up.

`GoogleAI.txt` proposes exactly this — a pipeline that applies infra changes on
merge to `main`.

**Evidence (2026-08-19).** There is **no `.woodpecker/` directory in this
repository.** Every tenant repo has one; the platform repo does not. Note the
audit found *zero* config drift, so the manual process is being done carefully —
this is about making that durable rather than fixing a present failure.

**Shape of the fix.** Start with the safe half, which is most of the value:

- **Validate on every PR** — `docker compose config` on all four stacks,
  `caddy validate` on the Caddyfile, a YAML lint. This catches a broken compose
  file before it reaches the box, and risks nothing.
- **Then, cautiously, apply on merge.** The hazard is real and specific: the CI
  server and agent are *themselves* containers in one of these stacks, so a
  pipeline that runs `compose up -d` on `woodpecker/` can restart the thing
  running the pipeline. Caddy is worse — `caddy/MIGRATION.md` calls it "the
  highest-risk migration in the repo" because a mistake takes every site down at
  once. Consider applying only `observability/` and `uptime-kuma/` automatically
  and leaving `caddy/` and `woodpecker/` as deliberate manual steps.

There is also a bootstrapping problem worth naming: if a bad commit breaks Caddy
or Woodpecker, the pipeline that would fix it may be unreachable. Keep the manual
path documented and working.

**Done when.** A PR against this repo runs config validation, and it is written
down which stacks apply automatically and which never will.

**Not this.** Not auto-applying `caddy/` or `woodpecker/` without a considered
decision. Not a full GitOps controller — this is a compose box.

## P17 — Container hardening beyond the flags already set · **Low–Medium**

**Problem.** The stacks already do the high-value things: pinned images, resource
limits, `no-new-privileges`, log rotation, no unnecessary published ports. All
three reviews propose the next tier — `read_only`, `cap_drop: [ALL]`,
`PidsLimit`, and non-root `user:`. None of it is currently applied.

**Evidence (2026-08-19).** Across all 16 containers: **`read_only: true`
nowhere**, `PidsLimit` unset everywhere (`0`), and no `cap_drop` in any compose
file. Running as root: `caddy`, `loki` (deliberate, documented), `alloy`
(deliberate, documented), `uptime-kuma`, `woodpecker-agent`, both Postgres, and
both static-site nginx containers. Already non-root and worth copying:
`grafana` (`472`), `woodpecker-server` (`woodpecker`), `ludo-backend` (`app`),
`ludo-frontend` (`101`).

**Shape of the fix.** Do this incrementally, one service per change, verifying
each — a `read_only` root filesystem breaks any container that writes to a path
you did not anticipate, and finding that out across seven services at once is
miserable. Best candidates first: the two nginx static sites (`helifilm`,
`portfolio`) are near-trivially `read_only` with a `tmpfs` for the cache dirs.

`PidsLimit` is the cheapest of the set and worth applying broadly — it is the
guard against a fork bomb in a CI step, which is a plausible failure on this box.

Leave `loki` and `alloy` as root: both carry written explanations, and **P6**
already establishes that the socket, not the flags, is what bounds the CI agent.

**Done when.** `PidsLimit` is set platform-wide, the two static sites run
`read_only`, and any service left as root has a comment saying why — matching the
convention Loki and Alloy already follow.

**Not this.** Not a big-bang hardening pass across all 16 at once. Not rootless
Docker (rejected above).

## P18 — The CI site has no security headers, and the others duplicate theirs · **Low**

**Problem.** Two related Caddy gaps, one of which is a real omission rather than
a tidiness question.

**Evidence (2026-08-19).**

```
caddy/logs.aneskurtovic.caddy    → full header block
caddy/uptime.aneskurtovic.caddy  → full header block
caddy/ci.aneskurtovic.caddy      → NO header block at all
```

`ci.aneskurtovic.caddy` is nine lines: `encode` and `reverse_proxy`, nothing
else. So the CI UI — which is authenticated, and behind which sit every
repository's deploy secrets — serves without HSTS, without `X-Content-Type-Options`,
without `X-Frame-Options`, and **advertises its `Server` header**, while the two
less sensitive sites do all of it. This also means the reject table's original
"Server header: Done" claim was wrong; it has been corrected there.

The second half is `ZAI.txt`'s point: `logs.` and `uptime.` carry byte-identical
header blocks, and a third copy is now needed. That is the moment to factor it
out rather than paste it again.

**Shape of the fix.** Define the shared block once as a Caddy **snippet** in
`caddy/Caddyfile` (`(security_headers) { … }`) and `import security_headers` from
each site file. Note the constraint this must respect: `Caddyfile` deliberately
"defines NO sites" and tenant snippets live in `/opt/caddy-sites`, host-owned and
outside any repo. A named snippet is global config, not a site, so it fits that
rule — but each tenant's file must still opt in with one `import` line, and a
tenant who wants different headers must remain free to write their own.

Separately, `ZAI.txt` proposes **rate limiting**. Caddy's rate-limit module is
not in the standard build, so this means a custom image — worth it only for a
specific reason. The login endpoints on `logs.` and `ci.` would be the reason, if
one is wanted.

**Done when.** `ci.aneskurtovic.com` returns HSTS and `nosniff` and does not
advertise `Server`, and the header block is defined once rather than three times.

**Not this.** Not moving tenant sites into the repo — the host-owned
`/opt/caddy-sites` boundary is deliberate. Not a custom Caddy build unless rate
limiting is actually wanted.

## P19 — Reproducible host build, eventually · **Low (direction)**

**Problem.** `host/bootstrap.sh` is idempotent, re-heals drift, and is honestly
good for what it is. It is still a shell script, run by hand, whose correctness is
only proven by running it on the one box that already exists. Nothing describes
the Hetzner resources themselves — server type, firewall, DNS, IPs — so the
box is reproducible only in the parts Linux owns.

`ChatGPT.txt` proposes OpenTofu for the Hetzner resources and Ansible for what is
inside Linux, and explicitly says to **evolve into it rather than rewrite now**.
That caveat is the important part and is adopted here.

**Evidence (2026-08-19).** `bootstrap.sh` is 192 lines covering Docker, the
`edge` network, ufw, SSH, swap, fail2ban, and unattended-upgrades. It sets
exactly one sysctl (`vm.swappiness=10`). No OpenTofu, no Ansible, no Hetzner
resource definition anywhere in the repo.

**Why this is Low despite being architecturally right.** It buys almost nothing
until there is a second box or a real rebuild. **P1**'s `DISASTER-RECOVERY.md`
delivers most of the practical value — knowing how to rebuild — at a fraction of
the cost. The natural trigger to revisit is **P6**'s "move the CI runner to a
second host": two boxes is when hand-run scripts stop scaling and Ansible starts
paying for itself.

**Done when.** Either a second host exists and is provisioned by Ansible, or a
note here records that one box does not justify it yet. Re-read at the next
rebuild.

**Not this.** Not rewriting `bootstrap.sh` now. Not adopting OpenTofu for a
single server that was created by hand and is not being recreated.

## P20 — Host settings inherited rather than asserted · **Low**

**Problem.** Several host-level protections are correct on this box **by Ubuntu
default**, not because anything in this repo sets them. That is fine until a
distro upgrade or a different image changes a default, at which point the
platform silently loses a property it never knew it had.

**Evidence (2026-08-19).** All good today, none of it asserted by
`bootstrap.sh`, which sets only `vm.swappiness=10`:

```
net.ipv4.tcp_syncookies      = 1
net.ipv4.conf.all.rp_filter  = 2
net.ipv4.conf.all.accept_redirects = 0
timedatectl: System clock synchronized: yes, NTP service: active
```

`ZAI.txt` raises all of these plus file-descriptor limits (`fs.file-max`,
per-user `ulimit`), which matter on a box running 16 containers and unbounded CI
steps — that one is not merely inherited, it is unexamined.

**Shape of the fix.** Extend the existing `/etc/sysctl.d/99-platform.conf` that
`bootstrap.sh` already writes for `vm.swappiness` — pin the network values it
currently inherits, add file-descriptor limits, and assert time sync is enabled
rather than assuming it. This is a few lines in a script that already exists and
is already idempotent. Fold it in with the journald cap from **P8**; same file,
same rationale.

`ZAI.txt` also proposes **CrowdSec** over fail2ban. fail2ban is active and
working, and **P14** would remove most of what it defends against by taking SSH
off the public internet. Do P14 first; if SSH is tailnet-only, CrowdSec is
solving a problem you no longer have.

**Done when.** `bootstrap.sh` asserts the network sysctls and file limits it
currently inherits, and a fresh box gets them without depending on distro
defaults.

**Not this.** Not CrowdSec before **P14**. Not tuning sysctls that have no
symptom — pin what is already correct; do not invent values.

## P21 — Application logs are unparsed text · **Low**

**Problem.** Alloy ships every container's stdout to Loki as opaque lines. Any
structured field a service emits — level, request ID, latency, status — is
findable only by substring match. `observability/OPERATIONS.md`'s own example
query is `{stack="ludo-prod", service="backend"} |= "ERROR"`, a text search
standing in for a level filter.

`ZAI.txt` proposes a JSON parsing stage and richer relabelling.

**Evidence (2026-08-19).** `alloy/config.alloy` contains `discovery.docker`,
`discovery.relabel`, `loki.source.docker`, and `loki.write` — no `stage.json`, no
pipeline stages at all.

**Shape of the fix.** Add a JSON parsing stage for containers that actually emit
JSON, then extract `level` as a **structured metadata field**, not a label. That
distinction is the whole point: the repo's low-cardinality label scheme (`stack` +
`service`) is a deliberate, documented decision and this must not erode it. Loki
3.x supports structured metadata precisely so fields can be queryable without
becoming index labels.

Worth doing only if the tenants emit JSON — check before building the pipeline.
`ludo-backend` is the only plausible candidate.

**Done when.** A level filter is a field match rather than a substring search,
and `{stack}`/`{service}` remain the only labels.

**Not this.** **Do not turn request IDs, user IDs, trace IDs, or URLs into
labels** — every review says so and `loki-config.yml` is built on that
assumption. Not parsing nginx access logs; that is what the Caddy access log is
for.

## Also proposed, not adopted

- **Makefile** (`ZAI.txt`, filed under "typing docker compose gets tedious").
  Rejected for now: each stack has a different `--env-file`, and those exact
  invocations are already written in every runbook and in each compose file's
  header comment. A Makefile would become a second place to keep them correct,
  and the runbooks are load-bearing during incidents in a way a Makefile is not.
  Reconsider if a fifth stack lands.
- **Watchtower / automatic container updates.** Rejected on the merits above.
- **Borgmatic** as an alternative to restic (`GoogleAI.txt`). No objection to it;
  **P1** picks restic because all three reviews converge on it and its `check` +
  retention story is the part that matters here. Not worth re-deciding.
---

## What was checked and found healthy

Recorded so a future pass knows these were examined rather than skipped:

- **Zero config drift** between repo HEAD and the box, across every readable
  platform file.
- **Network exposure is clean.** Public listeners are `:22`, `:80`, `:443` and
  nothing else. The "Docker publishes past ufw" hazard has no surface here.
- **TLS certificates all healthy** — nearest expiry 50 days
  (`aneskurtovic.com`, Oct 8). The Aug 10 migration preserved certificates rather
  than re-issuing.
- **Loki retention verified empirically**, not just from config.
- **Zero OOM events and zero failed systemd units** in 15 days.
- **fail2ban active and working.**
- **`backup-db.sh` is well-engineered** — its weakness is retention and location
  (**P1**), not correctness.
