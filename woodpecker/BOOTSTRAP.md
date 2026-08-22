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

> **This boundary protects git, not the runtime.** The table above is true and
> worth keeping, but do not read more into it than it says. The values are
> readable at runtime by anything with Docker access: `docker inspect
> woodpecker-agent` prints `WOODPECKER_AGENT_SECRET` in plaintext to a user with
> no sudo and no read access to `/opt/ci/agent.env`. Docker group membership is
> root-equivalent, so this is not an escalation — it means the root-only file
> mode is not a second line of defence. See `BACKLOG.md` **P5**.

## What a pipeline can actually reach

Stated plainly, because the compose file's comments understate it and the network
layout invites the wrong conclusion.

`woodpecker-agent` is attached to `ci-network` only, and genuinely cannot reach
`ludo-network` at layer 3. **That containment is decorative.** The agent mounts
`/var/run/docker.sock` read-write — it must, to create step containers — and with
a read-write socket it can create a container on any network, mount host `/`,
read every volume including `caddy-data` (private keys) and
`woodpecker-server-data` (every deploy secret), and read any container's
environment without touching the network at all.

So the control that actually bounds a compromised build is **who can trigger a
pipeline**, not what the pipeline can see:

- `WOODPECKER_OPEN=false` — no self-registration;
- `WOODPECKER_REPO_OWNERS` — only your own repositories may be enabled;
- repository-scoped deploy secrets — a pipeline holds only its own credential;
- `WOODPECKER_MAX_WORKFLOWS=1` — one workflow at a time, so CI never contends
  with live services.

Keep pipelines untrusted (no `privileged`, no host volume mounts) and treat the
right to enable a repository as the security decision it is.

The off-box Windows agent is **weaker still**, not equivalent: it uses the
`local` backend, so steps run directly on that host with no container at all.
`windows-agent/README.md` states this plainly under "Trust boundary" and "What
this does not do" — read it before enabling any repository that the Windows
agent will serve.

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

## 7. Agents that do not run on this box

The agent in `docker-compose.yml` reaches the server at `woodpecker-server:9000`
over `ci-network`, so gRPC never leaves Docker. An agent on another machine — a
Windows host, for instance, which the Docker backend cannot serve — needs a
route to that port from outside.

**That route is Tailscale, not a public endpoint.** The server publishes `:9000`
bound to its tailnet address and nothing else:

```bash
# On this box, once:
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --accept-dns=false --hostname=hetzner-ci
tailscale ip -4        # -> the value for CI_AGENT_GRPC_BIND
```

`--accept-dns=false` matters. Tailscale's MagicDNS rewrites `/etc/resolv.conf`
by default; on a host whose Caddy does ACME and reverse-proxy lookups, silently
replacing the resolver risks an outage for every site here in exchange for a CI
convenience. Take the route, not the DNS.

Then set `CI_AGENT_GRPC_BIND` in `/opt/ci/.env` and recreate **only** the server:

```bash
docker compose --env-file /opt/ci/.env -f docker-compose.yml config --quiet
docker compose --env-file /opt/ci/.env -f docker-compose.yml up -d woodpecker-server
docker inspect woodpecker-server --format '{{json .HostConfig.PortBindings}}'
```

That last line is the check that matters: the binding must show the tailnet
address, never `0.0.0.0`. Verify from the remote machine that the port answers
over the tailnet and **does not** answer on the public IP.

Register the off-box agent in **Admin → Agents**, and pin it to the same version
as the server. An agent whose entry shows an empty platform and a zero
last-contact time has never connected — that is a created record, not a runner.

Because the alternative gets proposed every time: exposing gRPC through the edge
proxy on a public hostname would mean a Caddy restart affecting every site here,
a certificate for a hostname that exists only for CI plumbing, and an
authentication endpoint on the public internet. Tailscale removes that exposure
rather than mitigating it.

## Recovery

```bash
docker compose --env-file /opt/ci/.env -f docker-compose.yml logs --tail 200
docker compose --env-file /opt/ci/.env -f docker-compose.yml up -d
```

**The compose file must actually be on the box at the path the running
containers record.** Compose reconstructs a project from container labels, so
`docker compose ls` will happily list a project whose `docker-compose.yml` has
been deleted — the stack keeps running and every management command fails. Check
with:

```bash
docker inspect woodpecker-server \
  --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
ls -l "$(docker inspect woodpecker-server \
  --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
```

If the file is missing, restore it from this repository before doing anything
else; a running-but-unmanageable stack is a problem you want to find on a
Tuesday, not during an incident.

### Backing up `woodpecker-server-data`

> **A platform backup stack now exists in the repo — and has never been run on
> this box.** [`../backup/`](../backup) takes a nightly off-site restic snapshot
> of this volume, keeps fourteen generations, and verifies weekly. Until someone
> installs it and completes a restore drill (`BACKLOG.md` **P1**), the only
> backup of this volume is the manual one below, and nobody is doing it for you.
>
> Keep taking one before every upgrade regardless. It is immediate, it does not
> depend on the network or on remembering a repository password, and "the thing
> I am about to change" is exactly when a snapshot from up to 24 hours ago is
> the wrong granularity.

This volume holds Woodpecker's database: repository setup, **every
per-repository deploy secret**, and build metadata. It is the most tedious thing
on the box to reconstruct by hand, because nothing enumerates which repos hold
which secrets — you find out when a pipeline fails.

Take one before any upgrade, and after adding repositories or secrets:

```bash
# /opt/backups does not exist on a box where this has never been run. Create it
# root-only first — a bind mount would otherwise create it silently, world-
# readable, and these archives contain every deploy secret in the clear.
install -d -m 700 /opt/backups

docker compose --env-file /opt/ci/.env -f docker-compose.yml stop woodpecker-server
docker run --rm -v woodpecker-server-data:/data:ro -v /opt/backups:/backup \
  alpine:3.22 tar -C /data -czf /backup/woodpecker-$(date -u +%Y%m%dT%H%M%SZ).tar.gz .
chmod 600 /opt/backups/woodpecker-*.tar.gz
docker compose --env-file /opt/ci/.env -f docker-compose.yml start woodpecker-server
```

Stop the server first — this is a live database, and copying its files while it
writes can yield an archive that restores into a corrupt state.

**Copy the archive off the box.** An archive on the disk you are protecting
against is not a backup. It also contains every deploy secret in the clear, so
store it encrypted and mode `600`.

Restoring the volume restores the database. The OAuth client secret and the agent
secret are **not** in it — those live in `/opt/ci/server-oauth.env` and
`/opt/ci/agent.env` and are restored separately.

## Upgrades

Server and agent are pinned together to the same version and must be upgraded
together after reading the upstream migration notes.
