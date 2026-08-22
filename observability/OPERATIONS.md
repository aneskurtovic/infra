# Observability operations runbook

Steady-state operation of the platform's logging stack: one Loki, one Alloy
collector, one Grafana. For the one-time move off Ludo, see
[MIGRATION.md](MIGRATION.md).

```bash
cd /opt/observability
docker compose --env-file observability.env -f docker-compose.yml ps
```

## What is and isn't collected

Alloy ships every container's **stdout/stderr** as Docker captured it. That means
anything a service writes to a file inside itself is invisible here — most
notably Ludo's backend Serilog files, which remain that application's own
long-lived log path. This stack is for "what happened to this service recently"
triage across the whole box, not for deep single-application forensics.

Since 2026-08-22 it also ships the **systemd journal**, filtered to the
platform's own units — today `platform-backup.service`,
`platform-backup-maintenance.service` and `platform-docker-cleanup.service`.
The last of those logs disk usage before and after each weekly run, so the
build-cache sawtooth (`BACKLOG.md` **P2**) is a query rather than an SSH.
Nothing else from the journal is
collected: it is 2.4 GB with no cap (`BACKLOG.md` **P8**), and sshd/kernel/
fail2ban lines earn nothing in Grafana that `journalctl` does not already give.

Retention is **7 days**, enforced by Loki's compactor. There is no archive.

## Reaching Grafana

**Published at `https://logs.aneskurtovic.com`** since the edge-proxy migration
ran on 2026-08-10 (`caddy/MIGRATION.md`, Phase 3b). The platform `caddy`
container holds `:80/:443` and imports `caddy/logs.aneskurtovic.caddy` from
`/opt/caddy-sites`.

**The loopback path is still there, and still the one to use in an incident:**

```bash
ssh -L 3000:127.0.0.1:3000 root@<box>     # then browse http://localhost:3000
```

That is deliberate and permanent, not a leftover: when the edge proxy is broken
is exactly when you need to read logs, and routing the log UI through the thing
you are debugging is a bad dependency.

## The single authentication gate

**Grafana's own login is the only gate, on purpose.** An outer Caddy `basic_auth`
in front of it was tried and removed — once the browser satisfies the gate it
sends `Authorization: Basic …` on every subsequent request, Grafana's own
basic-auth client tries to resolve that user, fails with "no user found", and
401s even after a correct form login. Stripping the header would then break
Grafana API tokens, which travel in the same header. The full reasoning lives in
`caddy/logs.aneskurtovic.caddy`; don't re-litigate it here.

What covers the missing outer gate: `GF_AUTH_ANONYMOUS_ENABLED=false` (nothing
is readable unauthenticated), `X-Robots-Tag` keeping the instance out of search
indexes, and — the control that actually matters — the admin password having
been rotated off its bootstrap seed.

`GRAFANA_USERNAME` / `GRAFANA_PASSWORD_HASH` may still be present in
`/opt/caddy/caddy.env`. They are **unused**; harmless to leave, safe to delete.

> **Note the asymmetry.** The uptime dashboard *does* keep an outer Caddy gate
> (`caddy/uptime.aneskurtovic.caddy`). Only Grafana dropped it, because only
> Grafana consumes the `Authorization` header itself.

Rotate the Grafana password **in the Grafana UI**. `GRAFANA_ADMIN_PASSWORD`
(`/opt/observability/observability.env`) applies on first start only; editing it
later does nothing.

Grafana is a single login over **every tenant's logs**. If that stops being
acceptable, add SSO/OAuth *inside Grafana* rather than a second HTTP gate.

Loki itself has **no authentication**. Its only host binding is `127.0.0.1:3100`,
and it is never routed through Caddy. Keep it that way — `auth_enabled: false`
means anything that can reach it can read every tenant's logs.

## Label scheme

Two labels matter. `stack` says whose logs these are; `service` says which
component:

| Container | `stack` | `service` |
|---|---|---|
| `ludo-backend` | `ludo-prod` | `backend` |
| `ludo-backend-stage` | `ludo-stage` | `backend` |
| `portfolio` | `portfolio` | `portfolio` |
| `helifilm` | `helifilm` | `helifilm` |
| `caddy`, `woodpecker-server`, `uptime-kuma`, … | `platform` | container name |
| *(journal)* `platform-backup.service` | `platform` | `platform-backup` |
| *(journal)* `platform-docker-cleanup.service` | `platform` | `platform-docker-cleanup` |

The journal rows deliberately use the same two labels as containers, so a unit
and a container are queried identically. They carry no `container` or `stream`
label — which is also how you tell them apart:
`{stack="platform", container=""}` is everything that came from systemd.

**Always scope by `stack`.** Prod and stage deliberately share `service` names,
so a bare `{service="backend"}` spans both — that is the trap this schema exists
to make visible rather than silent.

## Useful queries

```logql
{stack="ludo-prod", service="backend"} |= "ERROR"
{stack="platform", service="caddy"} | json | status >= 500

# Disk usage over time, until P4 gives us a real metric. Seven points a month,
# straight out of the weekly reclamation run.
{stack="platform", service="platform-docker-cleanup"} |= "disk "

# Anything the platform's own timers warned about — backup, reclamation, both.
{stack="platform", service=~"platform-.+"} |= "WARN"
{stack="helifilm"}
{stack=~"ludo-.+"} |= "OutOfMemory"

# Noisiest containers over the last hour — start here when disk grows.
topk(10, sum by (container) (count_over_time({stack=~".+"}[1h])))

# Containers matching no `stack` rule. Should be empty; anything here is a
# tenant someone forgot to onboard. The `container=~".+"` matcher is required —
# Loki rejects a selector in which every matcher can match the empty string, so
# a bare `{stack=""}` is an error, not an empty result.
sum by (container) (count_over_time({container=~".+", stack=""}[1h]))
```

## Verifying journal collection

`alloy validate` will pass whether or not journal collection actually works —
it checks the config, not the collector's capabilities or the host's journald
mode. Two things have to be true on the box, and both fail *silently*:

```bash
# 1. The journal is persistent. If journald is in volatile mode its files are in
#    /run/log/journal, the bind mount creates an empty /var/log/journal, and the
#    source reads nothing while every container reports healthy.
journalctl --header | head -3
ls -d /var/log/journal/*

# 2. Lines actually arrive. Emit one under a collected unit's identifier and
#    look for it — this is the only end-to-end proof.
systemd-cat -t platform-backup echo "journal collection test $(date -u +%FT%TZ)"
```

Then, in Grafana (allow ~15 s):

```logql
{stack="platform", service="platform-backup"}
```

If the query is empty and step 1 was fine, check `docker logs alloy` for
`loki.source.journal` errors. Alloy needs journal support compiled in; the
official image has it, a rebuilt or substituted one may not, and that shows up
as a component error at start rather than as a bad config.

## Alerting

Four rules, provisioned from `grafana/provisioning/alerting/` the same way the
datasource is — committed, not clicked, so a rebuilt Grafana notifies the same
place without anyone remembering. They also fix the error Grafana logged at
every start: `can't read alerting provisioning files from directory`.

| Rule | Fires when | Severity |
| --- | --- | --- |
| Backup has not completed in 26h | No `platform backup complete` line — including because Loki or Alloy is broken | critical |
| Backup reported warnings | A stale tenant hand-off, an unreadable secret file | warning |
| Backup repository check failed | `Fatal` from restic or the scripts in 7 days | critical |
| Disk above its threshold | Either platform timer logged `WARN: disk` | critical |

**The thing to understand before editing them.** These query *logs*, not metrics
— there is no metrics backend yet (**P4**), so "did the backup run" is asked as
"does a success line exist". A LogQL query matching no lines returns **no
series**, not zero, so `count_over_time(...) == 0` can never be true. Absence
arrives as **No Data**, which is why the rule that matters most has
`noDataState: Alerting` and a `< 1` threshold. Do not "fix" it into `== 0`; that
is an alert that silently never fires.

Two consequences worth stating rather than discovering:

- A broken Alloy, Loki, or Grafana-to-Loki path also produces No Data and will
  notify. That is correct — losing the ability to know whether the backup ran is
  not meaningfully better than the backup not running.
- **"The weekly maintenance run stopped happening" has no rule and cannot have
  one.** Loki keeps 7 days; the job runs every 7 days. Any absence window wide
  enough to mean something is wider than the data. It is covered transitively: a
  repository that has become unreachable fails the *nightly* backup too, and
  rule 1 catches that within 26 hours.

### Where notifications go

`GRAFANA_ALERT_WEBHOOK_URL`, from `/opt/observability/observability.env`. The URL
is a credential and never enters the repo; the file that references it does.
It is **required** — a `compose up` without it fails, deliberately, because
Grafana starting with rules that evaluate correctly and reach nobody is the
state `BACKLOG.md` **P3** calls "worse than having no monitoring, because it
looks like coverage."

This is a *second* destination, not a replacement for Uptime Kuma's own
notifications. Kuma probes the sites from outside the applications and has to be
able to tell you the box is down — which is exactly when Grafana cannot.

### Verify it, end to end, once

Provisioning that loads is not the same as a notification that arrives, and the
whole point of this item is that nobody had checked.

```bash
# 1. The contact point resolved its URL. If it shows the literal
#    "$__env{GRAFANA_ALERT_WEBHOOK_URL}", the interpolation did not happen on
#    this Grafana version — see the note at the top of contact-points.yml.
#    Alerting -> Contact points -> platform-notifications -> Test

# 2. A rule actually fires. This writes a real matching line into the journal;
#    Alloy ships it, and platform-disk-high should notify within ~15 minutes
#    (5m evaluation + 10m `for`).
systemd-cat -t platform-backup echo "WARN: disk: 99% used, 0.1G free (threshold 85%)"

# 3. Watch it arrive, then watch it RESOLVE 26h later — or don't wait, and just
#    confirm the alert appears under Alerting -> Alert rules -> Platform.
```

Do step 2 knowing what it does: it is a genuine false alarm, and it is the only
honest way to test an alert path.

### Editing and silencing

The files are the source of truth; provisioned rules show read-only in the UI, so
a change made there is lost on the next container recreate. Edit the file and
restart Grafana. Silences are runtime state and *are* set in the UI — they live
in `grafana-data`, which the platform backup covers.

## Adding a tenant

Onboarding is one rule and a reload — never a new collector.

1. Add a `stack` rule to `alloy/config.alloy`, next to the existing ones:

   ```alloy
   rule {
     source_labels = ["__meta_docker_container_name"]
     regex         = "^/newapp$"
     target_label  = "stack"
     replacement   = "newapp"
   }
   ```

   Keep the regex anchored and mutually exclusive with the others. If the app
   runs several containers with a shared prefix, follow the Ludo pattern —
   and mind the `service` rules' ordering comment before adding one there.

2. Validate **before** deploying. `alloy validate` exits non-zero and prints
   diagnostics for both syntax errors and bad component references — do not use
   `alloy fmt` for this, it is only a formatter and passes a config that will
   crash-loop:

   ```bash
   docker run --rm -v "$PWD/alloy:/etc/alloy:ro" grafana/alloy:v1.18.0 \
     validate /etc/alloy/config.alloy
   echo "exit=$?"    # must be 0 — stop here if not
   ```

3. Deploy and reload:

   ```bash
   cp alloy/config.alloy /opt/observability/alloy/config.alloy
   docker restart alloy
   docker logs --tail 20 alloy    # must not be erroring
   ```

4. Confirm within ~15s (the discovery refresh interval):

   ```bash
   curl -s 'http://127.0.0.1:3100/loki/api/v1/label/stack/values'
   ```

## When logs stop arriving

Work outward from the collector:

1. `docker logs alloy` — socket permission errors, config errors, or a Loki it
   cannot reach.
2. Alloy's own UI on `http://127.0.0.1:12345` (not published; use
   `docker exec alloy wget -qO- http://127.0.0.1:12345/-/ready`) shows component
   health.
3. `curl -s http://127.0.0.1:3100/ready` — Loki up?
4. `docker logs loki | grep -i "rate\|limit"` — a burst may be hitting
   `ingestion_rate_mb`. Raise it in `loki/loki-config.yml` and restart Loki.
5. Disk: `docker system df -v | grep loki-data`. If the compactor is failing,
   retention silently stops and the volume grows without bound.

If Loki crash-loops on `mkdir /loki/chunks`, the `user: "0"` line in the compose
was removed — see its comment.

## Backup

Grafana holds dashboards, users, and API keys; that is the only state worth
keeping. **Loki's data is deliberately not backed up** — it is 7-day triage data,
and restoring stale logs into a live index causes more confusion than it solves.
The platform backup stack ([`../backup/`](../backup)) makes the same split for
the same reason: `grafana-data` is in the nightly off-site snapshot, `loki-data`
is not.

The command below is the manual, immediate version — the right thing before an
upgrade. It writes into the working directory, so run it somewhere with room and
copy the archive off the box; an archive on the disk you are protecting against
is not a backup.

```bash
docker run --rm -v grafana-data:/data:ro -v "$PWD:/backup" alpine \
  tar czf "/backup/grafana-$(date +%F).tar.gz" -C /data .
```

## Restore

```bash
docker compose --env-file observability.env -f docker-compose.yml stop grafana

# Preserve current state before replacing it.
docker run --rm -v grafana-data:/data:ro -v "$PWD:/backup" alpine \
  tar czf /backup/grafana-prerestore.tar.gz -C /data .

# Replace ARCHIVE with the reviewed backup filename.
docker run --rm -v grafana-data:/data -v "$PWD:/backup" alpine \
  sh -c 'rm -rf /data/* /data/..?* 2>/dev/null; tar xzf /backup/ARCHIVE -C /data'

docker compose --env-file observability.env -f docker-compose.yml start grafana
```

## Upgrade and rollback

All three images are version-pinned in `docker-compose.yml`. Upgrade one service
at a time, not the stack — a Loki schema change and a Grafana datasource change
are much easier to tell apart when they are separate steps.

```bash
# Bump the tag in docker-compose.yml, then:
docker compose --env-file observability.env -f docker-compose.yml up -d loki
docker logs loki
```

Rolling back means restoring the previous tag and re-running the same command.
Loki's on-disk schema (`v13`, tsdb) has been stable across the 3.x line, but read
the release notes before crossing a **minor** version — a schema migration is not
reversible by changing the tag back.
