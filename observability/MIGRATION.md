# Centralized logging — migration to the platform

Moves log collection out of one application's Compose project and onto the
platform: Ludo's two Loki instances and two Promtail collectors become one
platform Loki and one Alloy collector that covers **every** container on the box.

Lower risk than the edge-proxy migration — nothing here terminates TLS, and
everything through Phase 2 is additive and reversible. The risky part is Phase 3,
which is a genuine cutover.

## Why the ordering below is what it is

Four constraints force the sequence:

1. **The DNS name `loki` is exclusive on `ludo-network`.** Ludo's own Loki
   already answers to it there. Attaching a second container with the same name
   makes Docker's embedded DNS return *both* records, and Ludo's backend
   `HttpClient` (BaseAddress `http://loki:3100`) hits them non-deterministically.
   Ludo's must be gone before the platform's attaches.
2. **The host port `127.0.0.1:3100` is exclusive.** Ludo's prod Loki binds it for
   the read-only `claude_ro` user. The platform Loki wants the same port, so the
   two cannot both publish it.
3. **Ludo's deploy would fight the new stack.** Its deploy runs
   `compose up -d --wait --remove-orphans`. While its compose still defines
   `loki`/`promtail`, a deploy after cutover restarts the old containers and
   re-collides. Once the services are removed from its compose, a deploy would
   instead treat still-running old containers as orphans and delete them. Either
   order is wrong *during* the window — hence the deploy freeze in Phase 3.
4. **Old log chunks are not worth migrating.** Retention is 7 days, and every
   existing chunk predates the `stack` label, so it would be invisible to the
   scoped queries this migration introduces. A clean start is the default. (If
   you want the week anyway, see [Optional: keeping the old
   chunks](#optional-keeping-the-old-chunks) — but read the caveat first.)

Because of (1) and (2), `observability/docker-compose.yml` ships in its
**steady-state** form and carries two blocks marked `MIGRATION TOUCH POINT`.
Phase 1 runs against a generated `docker-compose.phase1.yml` with those two
blocks commented out; Phase 3 goes back to the real file and deletes the
generated one.

---

## Phase 0 — prepare (no outage, fully reversible)

Nothing here touches anything running.

```bash
# Platform config — the whole directory, since compose mounts ./loki, ./alloy
# and ./grafana by relative path.
install -d -m 755 /opt/observability
cp -r <infra>/observability/. /opt/observability/
install -m 600 /dev/null /opt/observability/observability.env

# Data volumes. Created deliberately, never auto-created by `compose up`.
docker volume create loki-data
docker volume create grafana-data
```

Fill `/opt/observability/observability.env` from `.env.example`. Then add the
Grafana basic-auth pair to the edge proxy's env and DNS:

```bash
docker exec caddy caddy hash-password        # store the HASH in /opt/caddy/caddy.env
# GRAFANA_USERNAME=… / GRAFANA_PASSWORD_HASH=…
```

Point `logs.aneskurtovic.com` at the box. If the record is proxied by
Cloudflare, grey-cloud it for first issuance.

## Phase 1 — collector up, verify the labels (additive, Ludo untouched)

Generate a Phase-1 variant of the compose file with both `MIGRATION TOUCH POINT`
blocks commented out — the `ludo-network` entry under `loki.networks` and the
`loki.ports` block. Generating a second file rather than editing the real one
means there is nothing to remember to revert: Phase 3 simply uses the original.
Ludo's Loki keeps running and keeps serving its admin tab throughout this phase.

```bash
cd /opt/observability
sed -e 's/^      - ludo-network$/#&/' \
    -e 's/^    ports:  # MIGRATION-TOUCHPOINT-PORTS$/#&/' \
    -e 's/^      - "127\.0\.0\.1:3100:3100"$/#&/' \
    docker-compose.yml > docker-compose.phase1.yml

# Confirm the transform did what it should: `edge` only, no host port.
docker compose --env-file observability.env -f docker-compose.phase1.yml config \
  | grep -A6 -E '^  loki:'
docker compose --env-file observability.env -f docker-compose.phase1.yml config --quiet

# Validate the collector config BEFORE starting anything. `validate` exits
# non-zero on bad component references as well as syntax errors; `fmt` does not
# and would let a crash-looping config through.
docker run --rm -v /opt/observability/alloy:/etc/alloy:ro grafana/alloy:v1.18.0 \
  validate /etc/alloy/config.alloy

docker compose --env-file observability.env -f docker-compose.phase1.yml up -d loki alloy
docker logs loki    # must NOT crash-loop on `mkdir /loki/chunks`
docker logs alloy   # must NOT error on the Docker socket
```

Both Lokis are now ingesting in parallel — harmless, and it is what makes this
phase reversible.

**Verify the label scheme.** The host port is not published yet, so query from a
throwaway container on `edge`:

```bash
lq() { docker run --rm --network edge curlimages/curl:latest -sG "$@"; }

# Every stack must be present.
lq 'http://loki:3100/loki/api/v1/label/stack/values'
#   expect: ludo-prod, ludo-stage, portfolio, helifilm, platform

# THE CRITICAL CHECK — the collision this whole migration exists to prevent.
lq 'http://loki:3100/loki/api/v1/query_range' \
   --data-urlencode 'query={stack="ludo-prod",service="frontend"}' \
   | grep -o '"container":"[^"]*"' | sort -u
#   expect ONLY ludo-frontend. If ludo-frontend-stage appears, the relabel rules
#   are wrong — STOP and re-read alloy/config.alloy's service section.

# A previously-dark tenant is now covered.
lq 'http://loki:3100/loki/api/v1/query_range' \
   --data-urlencode 'query={stack="helifilm"}'

# Anything that matched no `stack` rule — should be empty. The `container=~".+"`
# matcher is required, not decorative: Loki rejects a selector in which every
# matcher can match the empty string, so a bare `{stack=""}` is an error.
lq 'http://loki:3100/loki/api/v1/query_range' \
   --data-urlencode 'query={container=~".+", stack=""}'
```

**Rollback:** `docker compose -f docker-compose.phase1.yml down` and delete the
two volumes. Nothing else on the box has changed.

## Phase 2 — Grafana over an SSH tunnel (additive)

```bash
cd /opt/observability
# Still the phase1 file — Loki must not pick up ludo-network until Phase 3.
docker compose --env-file observability.env -f docker-compose.phase1.yml up -d grafana
```

Grafana publishes `127.0.0.1:3000` only, so reach it from your workstation:

```bash
ssh -L 3000:127.0.0.1:3000 root@<box>     # then browse http://localhost:3000
```

Log in, then **rotate the admin password immediately** — `GRAFANA_ADMIN_PASSWORD`
applies on first start only. The **Loki** datasource is already provisioned:
Explore → `{stack="platform"}` returns the edge proxy's and CI's logs, which have
never been queryable before.

> **Why no public route yet** *(resolved 2026-08-10 — kept for the reasoning)*.
> When this phase was written, `caddy/logs.aneskurtovic.caddy` was committed and
> ready but unusable: the platform's Caddy had never been deployed, the box still
> ran `ludo-caddy` from the application's compose, and `/opt/caddy` did not
> exist. Routing Grafana through `ludo-caddy` instead would have meant adding
> `GRAFANA_USERNAME` / `GRAFANA_PASSWORD_HASH` to *that* service's `environment:`
> block (it has no `env_file`), i.e. an application repo change and deploy —
> precisely the platform/application entanglement this repo exists to undo. So
> the snippet waited for the **edge proxy** migration.
>
> **That migration has since run** (`caddy/MIGRATION.md`, Phases 0–3, 2026-08-10).
> The platform `caddy` now owns `:80/:443` and Grafana is published at
> `logs.aneskurtovic.com`. Note that the basic-auth gate referenced above was
> **dropped** rather than made load-bearing — it broke Grafana's login. See
> `caddy/logs.aneskurtovic.caddy` and `OPERATIONS.md`. The loopback port remains
> the access path of choice during an incident.

**Rollback:** stop the grafana container. Nothing outside this compose project
has been touched.

## Phase 3 — cutover (the point of no easy return)

**Freeze Ludo deploys before starting** (constraint 3 above). Do this in a quiet
window: Ludo's admin Logs → Services tab is unavailable for the duration.

```bash
# 1. Stop and REMOVE Ludo's collectors. Removal (not just stop) is what frees
#    the `loki` DNS name on ludo-network and the 127.0.0.1:3100 host port.
docker rm -f ludo-loki ludo-promtail ludo-loki-stage ludo-promtail-stage

# 2. Confirm the name is actually free — this must fail to resolve.
docker run --rm --network ludo-network curlimages/curl:latest \
  -s --max-time 5 http://loki:3100/ready ; echo "exit=$?"
```

Now switch back to the real compose file — the one that has both `MIGRATION
TOUCH POINT` blocks live — and recreate Loki:

```bash
cd /opt/observability
docker compose --env-file observability.env -f docker-compose.yml up -d
rm -f docker-compose.phase1.yml    # nothing should use it again
```

Verify the name resolves to exactly one instance, from inside Ludo's backend:

```bash
docker exec ludo-backend wget -qO- http://loki:3100/ready
curl -s http://127.0.0.1:3100/ready          # the claude_ro loopback path is back
```

Ludo's admin Logs tab is still on the **unscoped** query at this point, so it
will show prod *and* stage interleaved. That is expected, and it is what Phase 4
fixes. Keep the deploy freeze until Phase 4 ships.

## Phase 4 — Ludo repo change

Ludo's own repo, not this one. Its branch flow is **`stage` → `main`**, so this
lands on `stage`, gets verified against the stage stack, and only then merges to
`main`. In summary:

- scope the LogQL selector in `server/LudoNexus.Api/Endpoints/AdminLogsEndpoints.cs`
  to `{stack="…",service="…"}`, reading the stack from a `LOKI_STACK` env var
  (`ludo-prod` / `ludo-stage`) set per compose file, matching the existing
  `LOKI_URL` convention;
- drop `caddy` from the service allowlist and the admin UI's picker — the proxy
  is platform-owned now, and that sub-tab has been silently empty since the edge
  proxy moved (its container is `caddy`, which never matched Promtail's
  `^/ludo-…$` filter);
- delete the `loki`/`promtail` services from `docker-compose.yml`, the
  `loki-stage`/`promtail-stage` services from `docker-compose.stage.yml`, the
  `docker/loki/` and `docker/promtail/` directories, and the four
  `ludo-loki-*` / `ludo-promtail-*` volume declarations;
- update `docs/DEPLOYMENT.md` and `docs/DEPLOY_PLAYBOOK.md` to point here.

Lift the deploy freeze once this is on `main` and deployed.

## Phase 5 — cleanup

Only after Ludo's admin Logs tab is confirmed working against the platform Loki:

```bash
docker volume rm ludo-loki-data ludo-loki-stage-data \
                 ludo-promtail-positions ludo-promtail-stage-positions
```

Verify the exact volume names with `docker volume ls | grep -E 'loki|promtail'`
first — this is unrecoverable.

## Optional: keeping the old chunks

Not recommended, and the caveat is the reason: chunks written by Ludo's Promtail
have no `stack` label, so the scoped queries introduced in Phase 4 will not
return them. You would be keeping data that only an unscoped ad-hoc query in
Grafana can see, for at most seven days until retention deletes it anyway. If you
still want it, between Phases 3 and 4:

```bash
docker stop loki
docker run --rm -v ludo-loki-data:/from:ro -v loki-data:/to alpine \
  sh -c 'cp -a /from/. /to/'
docker start loki
```

## Adding the next tenant

Nothing in this migration repeats. A new application on the box needs one `stack`
rule in `alloy/config.alloy` and a collector reload — see
[OPERATIONS.md](OPERATIONS.md).
