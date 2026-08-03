# Edge proxy — migration to the platform

Moves the Caddy that owns `:80/:443` out of one application's Compose project
and onto the platform, so every site — including that application's — is a
tenant snippet in `/opt/caddy-sites`.

**This is the highest-risk migration in the repo.** The edge proxy terminates TLS
for every site on the box; a mistake takes them all down at once. Read the whole
runbook before starting, and do it in a maintenance window.

## Confirm the box before you read further

This directory has existed, committed and unexecuted, for some time. **A file in
this repo describes intent, not deployment.** Establish which world you are in
first — the answer changes every command below:

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '443|caddy'
ls -la /opt/caddy 2>&1
```

- `ludo-caddy` holds `:80/:443` and `/opt/caddy` does not exist → **not migrated**;
  this runbook applies in full.
- `caddy` holds `:80/:443` and `/opt/caddy` exists → already migrated; you want
  Phase 4/5 or nothing at all.

Checking the repo instead of the box has already produced two wrong changes in
this platform's history. Spend the ten seconds.

## Why the ordering below is what it is

Three constraints force the sequence:

1. **Ports are exclusive.** Only one container can hold `:80/:443`, so old and
   new cannot overlap — there is an unavoidable outage of a few tens of seconds.
2. **Certificates must be migrated, not re-issued.** The old `caddy_data` volume
   holds every certificate and the ACME account key. Starting fresh would
   re-issue everything at once and can hit Let's Encrypt rate limits, leaving
   sites without valid certs for hours.
3. **The application's deploy would fight the new proxy.** Its deploy runs
   `compose up -d --wait --remove-orphans`. While its compose still defines a
   `caddy` service, a deploy after cutover tries to start the old container and
   collides on `:80`. Once the service is removed from its compose, a deploy
   would instead treat a still-running old container as an orphan and delete it.
   Either order is wrong *during* the window — hence the deploy freeze below.

## Phase 0 — prepare (no outage, fully reversible)

Nothing here touches the running proxy.

```bash
# Platform config
install -d -m 755 /opt/caddy
cp <infra>/caddy/Caddyfile        /opt/caddy/Caddyfile
cp <infra>/caddy/docker-compose.yml /opt/caddy/docker-compose.yml
install -m 600 /dev/null /opt/caddy/caddy.env
```

Fill `/opt/caddy/caddy.env` from `.env.example`. Copy the tenant values out of
the application's existing `.env` so snippets keep resolving:

```bash
grep -E '^(DOMAIN|STAGE_DOMAIN|UPTIME_KUMA_USERNAME|UPTIME_KUMA_PASSWORD_HASH)=' \
  /opt/ludo/app/.env >> /opt/caddy/caddy.env
echo 'CADDY_ACME_EMAIL=admin@ludo-nexus.com' >> /opt/caddy/caddy.env
chmod 600 /opt/caddy/caddy.env
```

### Extract the application's site blocks into a tenant snippet

**This is the step that takes the box down if it is wrong, and it is the one
step the platform cannot do for you.** The platform `Caddyfile` defines *zero*
sites — it only imports `/opt/caddy-sites/*.caddy`. Every hostname the old proxy
served from its own baked-in Caddyfile must exist as a snippet **before**
cutover, or that hostname simply stops resolving to anything the moment the new
proxy starts.

Check which hostnames are currently served from inside the container rather than
from `/opt/caddy-sites` — those are the ones with no snippet yet:

```bash
ls -1 /opt/caddy-sites/                       # what already has a snippet
docker exec ludo-caddy caddy adapt --config /etc/caddy/Caddyfile --pretty \
  | grep -oE '"[a-z0-9.-]+\.[a-z]{2,}"' | sort -u   # what is actually served
```

For Ludo the gap is four site blocks in `docker/caddy/Caddyfile`: `{$DOMAIN}`,
`www.{$DOMAIN}`, `http://www.{$DOMAIN}`, and `{$STAGE_DOMAIN}`. The snippet is
those four blocks verbatim, minus the global `{...}` options block and the
`import` line (the platform Caddyfile supplies both).

Three things that must hold, and are easy to miss:

1. **`{$DOMAIN}` / `{$STAGE_DOMAIN}` must be in `/opt/caddy/caddy.env`** — the
   snippet stays templated rather than hardcoding hostnames, so the variables
   have to resolve for the *platform* proxy, not the application's.
2. **`reverse_proxy backend:8080` keeps working**, but only because the platform
   proxy joins `ludo-network`. Those are Compose *service aliases*, registered
   per-network, so any container on that network resolves them regardless of
   project. Drop `ludo-network` from the proxy's compose and every Ludo route
   502s.
3. **The snippet belongs in the application's repo**, not this one. Tenants own
   their own routing; that is the whole point of the split. Phase 4 then teaches
   the app's deploy to write it. Note the two tenants disagree on where it
   lives — Helifilm uses `deploy/helifilm.aneskurtovic.caddy`, Ludo uses
   `docker/caddy/ludo.caddy` (PR #124). Either is fine; the deploy script names
   the path explicitly. Don't assume one from the other.

```bash
cp <app>/docker/caddy/ludo.caddy /opt/caddy-sites/ludo.caddy
ls -1 /opt/caddy-sites/
# expect: aneskurtovic.caddy  ci.aneskurtovic.caddy  helifilm.aneskurtovic.caddy
#         ludo.caddy  uptime.aneskurtovic.caddy
```

Validate the whole future config **before** touching anything, using a throwaway
container (no ports, so no conflict):

```bash
docker run --rm \
  -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
  -v /opt/caddy-sites:/etc/caddy/sites:ro \
  --env-file /opt/caddy/caddy.env \
  caddy:2.8-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```
Expected: `Valid configuration`. **Do not proceed until this passes.**

## Phase 1 — freeze deploys

Announce/ensure no application deploy runs until Phase 4. A deploy mid-window
will either collide on `:80` or delete the proxy as an orphan (see constraint 3).

## Phase 2 — cutover (the outage window, ~30–60s)

```bash
# 1. Copy the certificates. Stopped first, so nothing writes mid-copy.
docker stop ludo-caddy
docker volume create caddy-data
docker run --rm -v ludo-caddy-data:/from:ro -v caddy-data:/to \
  alpine sh -c 'cp -a /from/. /to/ && echo copied'

# 2. Confirm the certs actually came across BEFORE starting the new proxy.
docker run --rm -v caddy-data:/d alpine \
  find /d/caddy/certificates -name '*.crt' | head
#    expect one .crt per hostname

# 3. Start the platform proxy.
cd /opt/caddy
docker compose --env-file /opt/caddy/caddy.env -f docker-compose.yml config --quiet
docker compose --env-file /opt/caddy/caddy.env -f docker-compose.yml up -d
docker ps --filter name=^caddy$ --format '{{.Names}} {{.Status}}'
```

## Phase 3 — verify every site (not just one)

Derive the list from `/opt/caddy-sites/` rather than trusting the one below —
a hostname added since this was written and missed here is a site nobody checks.

```bash
for u in https://ludo-nexus.com/health \
         https://stage.ludo-nexus.com/health \
         https://aneskurtovic.com/ \
         https://helifilm.aneskurtovic.com/ \
         https://ci.aneskurtovic.com/ \
         https://uptime.aneskurtovic.com/ ; do
  printf '%-45s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' -L "$u")"
done
```
Expected: `200` everywhere except the uptime dashboard, which returns `401`
(its basic-auth gate). Also confirm the game loads in a browser and that
certificates are the **migrated** ones (no fresh-issuance delay).

**If anything is wrong, roll back now** (see below) rather than pressing on.

## Phase 3b — publish Grafana (unblocked by this migration)

`caddy/logs.aneskurtovic.caddy` has been committed and unusable since the
logging migration: it needs `GRAFANA_USERNAME` / `GRAFANA_PASSWORD_HASH`, and
the application's proxy had no `env_file` to read them from. The platform proxy
does. Until now Grafana has been reachable only over an SSH tunnel to
`127.0.0.1:3000`.

```bash
docker exec caddy caddy hash-password        # store the HASH, never the password
cat >> /opt/caddy/caddy.env <<'EOF'
GRAFANA_USERNAME=operator
GRAFANA_PASSWORD_HASH='PASTE_THE_HASH_HERE'
EOF

cp <infra>/caddy/logs.aneskurtovic.caddy /opt/caddy-sites/
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# Non-zero → rm the snippet and fix caddy.env. Do NOT reload a config that does
# not validate: the healthcheck is `caddy validate`, so a bad snippet marks the
# whole proxy unhealthy and takes every site's next reload with it.
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Point `logs.aneskurtovic.com` at the box first (grey-cloud for first issuance).
Then update `GRAFANA_ROOT_URL` in `/opt/observability/observability.env` from
`http://localhost:3000/` to `https://logs.aneskurtovic.com/` and
`docker compose ... up -d grafana`, or Grafana will keep generating links
pointing at localhost.

Keep the loopback port. When the edge proxy is broken is exactly when you need
logs, and routing the log UI solely through the thing you are debugging is a bad
dependency.

## Phase 4 — remove the proxy from the application (repo change)

Only after Phase 3 is green. In the application repo, merge the PR that:

- removes the `caddy` service, its `caddy_data`/`caddy_config` volumes, and its
  `docker/caddy/Caddyfile` from the app's Compose project;
- changes `remote-deploy.sh` to deploy its **snippet** instead of the container:
  write `/opt/caddy-sites/<app>.caddy`, validate, then
  `docker exec caddy caddy reload --config /etc/caddy/Caddyfile` — a graceful,
  zero-downtime config swap (this is why the admin API is bound to loopback);
- health-gates on the reload succeeding rather than on a container becoming
  healthy.

Then unfreeze deploys and push a no-op commit to confirm a full deploy cycle
works end-to-end with the new path.

## Phase 5 — clean up (after a soak)

```bash
docker rm ludo-caddy                 # already stopped
docker volume rm ludo-caddy-data     # ONLY after certs are proven working
```
Keep the old volume for at least a week — it is the fastest rollback.

## Rollback (valid until Phase 5)

```bash
cd /opt/caddy && docker compose -f docker-compose.yml down
cd /opt/ludo/app && docker compose up -d --no-deps caddy
curl -s -o /dev/null -w '%{http_code}\n' https://ludo-nexus.com/health
```
The old container definition, its `ludo-caddy-data` volume, and the app's own
`Caddyfile` are untouched through Phase 4, so this restores the exact prior
state. If Phase 4 has already merged, roll back by reverting that PR (the site
snippet in `/opt/caddy-sites` is harmless to leave in place).

## Notes

- The container is named `caddy`, not `<app>-caddy` — the name was part of the
  ownership confusion this migration removes. Update any host scripts, aliases,
  or docs that referenced the old name.
- The platform proxy joins **both** `edge` and each application-private network
  whose containers a snippet proxies to. A snippet can only reach what Caddy is
  attached to; adding a tenant with a private network means adding that network
  to the compose file.
- The healthcheck validates the running config rather than fetching one tenant's
  URL, so one application being down never marks the shared proxy unhealthy.
