# Uptime Kuma operations runbook

Uptime Kuma is the private **platform** availability dashboard — it monitors every
project on the box (Ludo, the portfolio, Helifilm, the CI UI), not just one. It runs
the pinned `louislam/uptime-kuma:2.3.2` image, persists all state in the
`uptime-kuma-data` Docker volume, and exposes no host port. The edge Caddy is the only
ingress path and adds HTTP Basic authentication on top of Kuma's own account.

The instance intentionally has **no Docker socket mount**. Public HTTP/TLS checks and
internal network probes cover the stack without giving the monitoring UI control of the
Docker daemon.

> First stand-up / migration from Ludo's old stack: see [`MIGRATION.md`](MIGRATION.md).
> This runbook covers steady-state operations.

## Availability limitation

Kuma runs on the same host as the sites it watches. It detects application, container,
routing, database, and certificate failures while the host stays reachable, but it
cannot send an alert if the host, its network, or Kuma itself is down. Keep one
independent **off-host** monitor on `https://ludo-nexus.com/health` (or any tenant
health URL) as the host-level dead-man check, notifying through a path that does not
depend on this host.

## The outer authentication gate

The Caddy site (`caddy/uptime.aneskurtovic.caddy`) keeps Basic auth in front of Kuma's
own login — the outer gate protects a fresh DB from public setup-page races and limits
exposure of the UI. The bcrypt hash is **never committed**; it is provided to the edge
Caddy via `UPTIME_KUMA_USERNAME` / `UPTIME_KUMA_PASSWORD_HASH` in that Caddy's
environment (currently `ludo-caddy`; moves with the edge proxy later). Generate a hash:

```bash
docker exec <edge-caddy> caddy hash-password
```

Keep the env file mode `600`. The dashboard Basic-auth password and the Kuma
administrator password must be two different strong passwords.

## Monitor inventory

Uptime Kuma v2 stores monitor definitions in its database (no supported declarative
format), so create these in the UI. Use a 60-second interval and three retries unless
noted, and enable certificate-expiry notifications on every HTTPS monitor. Because this
is now the **platform** dashboard, its inventory should cover all tenants, not only
Ludo — add public-edge monitors for each:

| Group | Monitor | Type / target | Success condition |
|---|---|---|---|
| Public edge · Ludo | Production website | HTTPS `https://ludo-nexus.com/` | `200` |
| Public edge · Ludo | Backend + database | HTTPS `https://ludo-nexus.com/health` | `200`, keyword `"status":"healthy"` (30s interval) |
| Public edge · Ludo | Stage | HTTPS `https://stage.ludo-nexus.com/health` | `200`, keyword `"status":"healthy"` |
| Public edge · Portfolio | Portfolio | HTTPS `https://aneskurtovic.com/` | `200` |
| Public edge · Helifilm | Helifilm | HTTPS `https://helifilm.aneskurtovic.com/health` | `200` |
| Public edge · Platform | CI UI | HTTPS `https://ci.aneskurtovic.com/` | `200` or `302` |
| Production internal · Ludo | Backend + database | HTTP `http://backend:8080/health` | `200`, keyword `"status":"healthy"` |
| Production internal · Ludo | PostgreSQL listener | TCP `postgres:5432` | connection succeeds |

The public `/health` probes are the primary service-level alerts (they return `503`
when the DB is unreachable). Internal monitors make the failing layer clear during
triage; they don't replace the public end-user probes. In **Settings → General → TLS
Certificate Expiry**, enable expiry notifications with advance warnings at 30/14/7/3/1
days and keep certificate validation on for every HTTPS monitor.

## Notifications

Notification credentials live only in Kuma's data volume — **never** put webhook URLs,
bot tokens, SMTP passwords, or chat IDs in this repo or any `.env`. In **Settings →
Notifications**, add a provider (Discord webhook, SMTP, Telegram bot, or Slack webhook),
send its test message, save, and apply it to all production monitors. Configure at least
two independent destinations. Verify one DOWN and one recovery notification by
temporarily cloning a monitor with an unreachable URL, then delete the test monitor.

## Maintenance windows

Before a planned deploy/infra change, create a maintenance window (Kuma **Maintenance**
screen), attach only the affected monitors, set exact start/end, and add a reason.
Maintenance suppresses expected alerts without pausing checks or erasing history. After:
confirm public-edge monitors are UP, response times normal, latest heartbeat +
certificate-expiry present, and end the window if it didn't auto-expire.

## Backup

Kuma v2 removed JSON backup/restore — back up the Docker **volume**. It holds monitor
history, admin credentials, notification secrets, and status-page config, so store
archives mode `600` off-host. Take a consistent **offline** backup before every upgrade
and after material monitor/notification changes:

```bash
cd /opt/uptime-kuma
docker compose stop uptime-kuma
docker run --rm \
  -v uptime-kuma-data:/data:ro \
  -v /opt/backups:/backup \
  alpine:3.22 \
  tar -C /data -czf /backup/uptime-kuma-$(date -u +%Y%m%dT%H%M%SZ).tar.gz .
chmod 600 /opt/backups/uptime-kuma-*.tar.gz
docker compose start uptime-kuma
```

Copy the archive to encrypted off-host storage — a backup only on the monitored host
does not protect against host/disk loss.

## Restore

Destructive; perform only in an approved maintenance window, and confirm the archive
first.

```bash
cd /opt/uptime-kuma
docker compose stop uptime-kuma

# Preserve current state before replacing it.
docker run --rm -v uptime-kuma-data:/data:ro -v /opt/backups:/backup \
  alpine:3.22 tar -C /data -czf /backup/uptime-kuma-pre-restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz .

# Replace ARCHIVE with the reviewed backup filename.
docker run --rm -v uptime-kuma-data:/data -v /opt/backups:/backup:ro \
  alpine:3.22 sh -c 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -C /data -xzf /backup/ARCHIVE'

docker compose start uptime-kuma
docker compose logs --tail 100 uptime-kuma
```

After restore, log in through both auth layers, verify monitor history + notification
settings, send provider test messages, and confirm every monitor receives a fresh
heartbeat.

## Upgrade and rollback

1. Review upstream release + migration notes.
2. Take and copy an off-host volume backup.
3. Bump only the pinned image tag in `docker-compose.yml`.
4. `docker compose pull uptime-kuma && docker compose up -d uptime-kuma`.
5. Check logs, login, monitors, notifications, certificate data.

To roll back: stop Kuma, restore the pre-upgrade volume archive, restore the previous
pinned tag, and recreate only the `uptime-kuma` service. Never run an older image
against a volume already migrated by a newer release.

Official references: [install](https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install),
[update](https://github.com/louislam/uptime-kuma/wiki/%F0%9F%86%99-How-to-Update),
[maintenance](https://github.com/louislam/uptime-kuma/wiki/Maintenance),
[status pages](https://github.com/louislam/uptime-kuma/wiki/Status-Page).
