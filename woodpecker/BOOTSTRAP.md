# Woodpecker CI — Bootstrap Runbook

One-time setup for a self-hosted Woodpecker instance serving multiple GitHub
repositories from a single host. GitHub stays the forge (OAuth + webhooks);
Woodpecker runs the pipelines and deploys.

Placeholders: `<HOST_IP>` = the box's public IP, `ci.aneskurtovic.com` = the CI
hostname. Never commit the real values you enter below — they live only in
root-only files under `/opt/ci`.

## Secret boundary (read first)

Nothing secret is in this repo. The committed compose references variables; the
values live in three root-only files the compose reads at runtime:

| File | Holds | Committed? |
| --- | --- | --- |
| `/opt/ci/.env` | non-secret config (see `.env.example`) | no |
| `/opt/ci/server-oauth.env` | `WOODPECKER_GITHUB_SECRET` | **never** |
| `/opt/ci/agent.env` | `WOODPECKER_AGENT_SECRET` | **never** |

Per-repository **deploy** credentials are added later in the Woodpecker UI and
live inside Woodpecker's database volume — never in any file or this repo.

## 1. DNS and GitHub OAuth

1. Create a proxied DNS record `ci.aneskurtovic.com` → `<HOST_IP>`.
2. Create a GitHub **OAuth App** (not a GitHub App):
   - Homepage URL: `https://ci.aneskurtovic.com`
   - Authorization callback URL: `https://ci.aneskurtovic.com/authorize`
3. Record the OAuth **client id** and generated **client secret**.

Woodpecker installs each repository's webhook when you enable it in the UI — no
manual webhook needed.

## 2. Host-only configuration (run as root)

```bash
install -d -m 700 /opt/ci
install -m 600 /dev/null /opt/ci/.env
install -m 600 /dev/null /opt/ci/server-oauth.env
```

Write the OAuth client secret interactively so it never enters shell history:

```bash
read -rsp 'GitHub OAuth client secret: ' S
printf 'WOODPECKER_GITHUB_SECRET=%s\n' "$S" > /opt/ci/server-oauth.env
unset S
```

Fill `/opt/ci/.env` from `.env.example` (`CI_DOMAIN`, `WOODPECKER_GITHUB_CLIENT`,
`WOODPECKER_ADMIN`, `WOODPECKER_REPO_OWNERS`). Keep everything under `/opt/ci`
owned by root, mode 700/600.

## 3. Networks and first start

```bash
docker network inspect ci-network >/dev/null 2>&1 || docker network create ci-network
docker network inspect edge       >/dev/null 2>&1 || docker network create edge

# Validate, then start ONLY the server for the first login.
docker compose --env-file /opt/ci/.env -f docker-compose.yml config --quiet
docker compose --env-file /opt/ci/.env -f docker-compose.yml up -d woodpecker-server
```

Drop `caddy/ci.aneskurtovic.caddy` into the host's Caddy sites directory and
reload/restart the proxy so it serves the hostname. If the DNS record is proxied,
the first Let's Encrypt issuance needs a brief DNS-only (grey-cloud) window;
renewals work fine while proxied.

## 4. Register the named agent

Sign in at `https://ci.aneskurtovic.com` with the admin GitHub account. In
**Settings → Agents**, add an agent named `aneskurtovic-docker-agent`, leave it
enabled, and copy its generated token. Store it interactively:

```bash
install -m 600 /dev/null /opt/ci/agent.env
read -rsp 'Agent token: ' T
printf 'WOODPECKER_AGENT_SECRET=%s\n' "$T" > /opt/ci/agent.env
unset T
```

Set `WOODPECKER_DISABLE_USER_AGENT_REGISTRATION=true` in `/opt/ci/.env`, then
start the full stack:

```bash
docker compose --env-file /opt/ci/.env -f docker-compose.yml up -d --wait --wait-timeout 120
docker compose --env-file /opt/ci/.env -f docker-compose.yml ps
```

The token identifies only this runner and is revocable in the admin UI.

## 5. Enable repositories and add deploy secrets

For each repo, enable it in the Woodpecker UI, then add its **repository**
secrets (Settings → Secrets), each restricted to `push` events.

Deploy credentials are **repository-scoped, never global** — a global deploy key
would be readable by every repo on the instance. Give each repo only what it
deploys with:

| Repo | Secrets (push-scoped) | Connects as |
| --- | --- | --- |
| an application repo | `deploy_host`, `deploy_ssh_key`, `deploy_known_hosts` | its own deploy user |
| another app | `<app>_deploy_host`, `<app>_deploy_ssh_key`, `<app>_deploy_known_hosts` | its own deploy user |

Collect each `*_known_hosts` value by reading the box's host key off local disk
(`/etc/ssh/ssh_host_ed25519_key.pub`) — never `ssh-keyscan` inside CI (that is
trust-on-first-use).

## 6. Branch protection

Protect the default branch in GitHub using the Woodpecker status checks the
repo's workflows report (contexts under `ci/woodpecker/`). Add a `nightly` cron
in the Woodpecker repo settings only if that repo defines cron-triggered
workflows.

## Recovery

```bash
docker compose --env-file /opt/ci/.env -f docker-compose.yml logs --tail 200
docker compose --env-file /opt/ci/.env -f docker-compose.yml up -d
```

Back up the `woodpecker-server-data` volume with the host backup system. Restoring
it restores Woodpecker's database (repo setup, secrets, build metadata); the OAuth
client secret and agent secret are restored separately from the host secret files.

## Upgrades

Server and agent are pinned together to the same version and must be upgraded
together after reading the upstream migration notes.
