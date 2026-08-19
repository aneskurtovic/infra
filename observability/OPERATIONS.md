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

**Always scope by `stack`.** Prod and stage deliberately share `service` names,
so a bare `{service="backend"}` spans both — that is the trap this schema exists
to make visible rather than silent.

## Useful queries

```logql
{stack="ludo-prod", service="backend"} |= "ERROR"
{stack="platform", service="caddy"} | json | status >= 500
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
