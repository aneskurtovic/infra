# Uptime Kuma — migration to the platform (from Ludo)

Uptime Kuma was originally part of Ludo's Compose stack (`ludo-uptime-kuma`,
`ludo-network`, volume `ludo-uptime-kuma-data`, an inline Caddy block on
`uptime.ludo-nexus.com`). This moves it onto the neutral platform: its own
Compose project on the shared `edge` network, served at
`uptime.aneskurtovic.com`, with the **monitor config + history preserved**.

The dashboard's monitors watch every project, so it belongs to the platform, not
to one tenant. Run these as root on the box. `<edge-caddy>` is the container that
owns `:80/:443` — since 2026-08-10 that is the platform `caddy` (see
`caddy/MIGRATION.md`); on a box where the edge migration has not run it is still
the application's own `ludo-caddy`. Check before substituting:
`docker ps --format '{{.Names}}\t{{.Ports}}' | grep 443`.

## 0. Preconditions

The edge Caddy already imports `/opt/caddy-sites/*.caddy` and already has the
`UPTIME_KUMA_USERNAME` / `UPTIME_KUMA_PASSWORD_HASH` environment variables (Ludo
set them for the old inline block). This migration reuses them, so **no Caddy
secret needs re-entering**. Confirm they are present:

```bash
docker exec <edge-caddy> printenv UPTIME_KUMA_USERNAME >/dev/null && echo "user OK"
docker exec <edge-caddy> printenv UPTIME_KUMA_PASSWORD_HASH >/dev/null && echo "hash OK"
```

If you ever need to regenerate the hash: `docker exec <edge-caddy> caddy hash-password`.

## 1. DNS (grey-cloud first)

Cloudflare → aneskurtovic.com → add A record: Name `uptime`, IPv4 = the box IP,
Proxy status **DNS only (grey)** for the first Let's Encrypt issuance. Flip to
proxied in step 7.

## 2. Copy the platform config to the box

From your workstation (infra is public, so a clone also works — see infra
BOOTSTRAP's F1a pattern):

```bash
install -d -m 755 /opt/uptime-kuma
# from a checkout of aneskurtovic/infra:
scp uptime-kuma/docker-compose.yml   root@<box>:/opt/uptime-kuma/docker-compose.yml
scp caddy/uptime.aneskurtovic.caddy  root@<box>:/opt/caddy-sites/uptime.aneskurtovic.caddy
```

## 3. Migrate the volume (old container STOPPED — SQLite must be quiesced)

Copy while Kuma is stopped so the SQLite DB is consistent. The old volume is left
untouched as an instant rollback.

```bash
docker stop ludo-uptime-kuma
docker volume create uptime-kuma-data
docker run --rm \
  -v ludo-uptime-kuma-data:/from:ro \
  -v uptime-kuma-data:/to \
  alpine sh -c 'cp -a /from/. /to/ && echo copied'
```
Verify the DB came across: `docker run --rm -v uptime-kuma-data:/d alpine ls -la /d | grep kuma.db`

## 4. Start the platform-owned container

```bash
cd /opt/uptime-kuma
docker compose -f docker-compose.yml config --quiet && echo "compose OK"
docker compose -f docker-compose.yml up -d
docker ps --filter name=^uptime-kuma$ --format '{{.Names}} {{.Status}}'
```
Expected: `uptime-kuma Up ... (healthy)` after ~30s. Now that the old container is
stopped, the `uptime-kuma` network alias resolves only to this new one on `edge`.

## 5. Add the Caddy site + issue TLS

```bash
docker restart <edge-caddy>
sleep 25
curl -sI https://uptime.aneskurtovic.com/ | grep -i 'HTTP/'
```
Expected: `HTTP/2 401` — a **401 is success here** (Caddy basic_auth is challenging;
TLS issued and the proxy works). A TLS/502 error is not.

## 6. Verify the deliverable (data, not just the check)

In a browser: `https://uptime.aneskurtovic.com` → pass the basic_auth gate → sign
in to Kuma → confirm **your existing monitors and history are all present**. That
proves the volume copy carried the database, not just that a fresh Kuma booted.

## 7. Flip DNS to proxied

Cloudflare → the `uptime` record → **Proxied (orange)**. Renewals work while proxied.
Verify: `curl -sI https://uptime.aneskurtovic.com/ | grep -i '^server:'` → `cloudflare`.

## 8. Decommission the Ludo copy (separate Ludo PR + box step)

Only after step 6 is confirmed and a short soak:

- **Ludo repo PR:** remove the `uptime-kuma` service from `docker-compose.yml`, the
  inline Uptime-Kuma block from `docker/caddy/Caddyfile`, and move/redirect
  `docs/UPTIME_KUMA.md` to this repo. Drop the now-unused `UPTIME_KUMA_DOMAIN` env
  (username/hash stay — the edge Caddy still needs them for this site).
- **Box:** `docker rm ludo-uptime-kuma` (already stopped). Keep the old
  `ludo-uptime-kuma-data` volume as a backup for a week, then
  `docker volume rm ludo-uptime-kuma-data`.

## Rollback (any time before step 8)

```bash
docker compose -f /opt/uptime-kuma/docker-compose.yml down
rm -f /opt/caddy-sites/uptime.aneskurtovic.caddy
docker restart <edge-caddy>
docker start ludo-uptime-kuma
```
The old container + original `ludo-uptime-kuma-data` volume are untouched, so this
is a clean revert.

## Fresh box (no Ludo history)

There is nothing to migrate — just `docker volume create uptime-kuma-data` before
step 4, set `UPTIME_KUMA_USERNAME` + `UPTIME_KUMA_PASSWORD_HASH` in the edge Caddy's
environment (`caddy hash-password`), and skip steps 3 and 8.
