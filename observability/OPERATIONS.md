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

**Today it is loopback-only, over an SSH tunnel:**

```bash
ssh -L 3000:127.0.0.1:3000 root@<box>     # then browse http://localhost:3000
```

`caddy/logs.aneskurtovic.caddy` is committed but **not active** — it needs the
platform Caddy, which has not been deployed (the box still runs the
application's own `ludo-caddy`, and `/opt/caddy` does not exist). It goes live as
Phase 3b of `caddy/MIGRATION.md`. The loopback port stays afterwards: when the
edge proxy is broken is exactly when you need logs.

## The two authentication gates (once published)

Grafana will sit behind Caddy `basic_auth` (`GRAFANA_USERNAME` /
`GRAFANA_PASSWORD_HASH` in `/opt/caddy/caddy.env`) *and* its own login
(`/opt/observability/observability.env`). Two different files, two different
credentials — a common source of confusion when rotating.

Rotate the Grafana password **in the Grafana UI**. `GRAFANA_ADMIN_PASSWORD`
applies on first start only; editing it later does nothing.

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
