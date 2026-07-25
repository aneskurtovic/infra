# Edge proxy — migration to the platform

Moves the Caddy that owns `:80/:443` out of one application's Compose project
and onto the platform, so every site — including that application's — is a
tenant snippet in `/opt/caddy-sites`.

**This is the highest-risk migration in the repo.** The edge proxy terminates TLS
for every site on the box; a mistake takes them all down at once. Read the whole
runbook before starting, and do it in a maintenance window.

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

**Extract the application's site blocks into a tenant snippet.** Take its
`docker/caddy/Caddyfile`, drop the global `{...}` options block and the
`import` line, and keep the site blocks (prod, the `www` redirect, stage):

```bash
# Write /opt/caddy-sites/ludo.caddy with those site blocks, then confirm the
# snippet set now covers every hostname that must stay up:
ls -1 /opt/caddy-sites/
# expect: aneskurtovic.caddy  ci.aneskurtovic.caddy  helifilm.aneskurtovic.caddy
#         uptime.aneskurtovic.caddy  ludo.caddy
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
