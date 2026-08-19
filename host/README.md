# Host bootstrap

One-time, app-agnostic setup for a fresh box: Docker, the shared `edge` network,
firewall, SSH hardening, swap, fail2ban, and unattended security upgrades.

```bash
sudo ./bootstrap.sh

# with the optional read-only agent identity:
CLAUDE_RO_PUBKEY="$(cat ~/.ssh/id_ed25519_agent.pub)" sudo -E ./bootstrap.sh
```

Idempotent — re-running is safe and re-heals drifted settings.

## What belongs here (and what doesn't)

| Here (platform) | Not here (each application) |
| --- | --- |
| Docker engine + compose plugin | `/opt/<app>` directory trees |
| The shared **`edge`** network | App-private networks (e.g. `app-network`) |
| ufw rules for `22/80/443` | App compose stacks and their volumes |
| SSH hardening, swap, fail2ban, auto-upgrades | App systemd units, backups, log dirs |

The dividing line: **if a second application would need it too, it belongs here.**
Applications never publish container ports — they join `edge` and the proxy
reaches them by container name, so the firewall never grows per-app holes.

> **Known violation, as of 2026-08-19.** The line above is the intent, not yet
> the state of the box. Three `/etc/systemd/system/` timers — `ludo-backup`,
> `ludo-purge`, `ludo-docker-cleanup` — are installed by an *application's*
> deploy script, and `ludo-docker-cleanup` (weekly `docker builder prune` +
> `image prune`) is the **only** thing preventing box-wide disk exhaustion. A
> change in that tenant's repo can silently remove the platform's sole disk
> reclamation. Tracked as `BACKLOG.md` **P2**.
>
> Two other host-level settings that belong here and are currently unset:
> journald has no `SystemMaxUse=` (2.4 GB and climbing toward a ~3.8 GB default
> cap), and there is no `/etc/docker/daemon.json` — so Docker's log-size default
> is unbounded and `live-restore` is off. `BACKLOG.md` **P8**.

## The read-only agent user

`claude_ro` is a genuine least-privilege identity for automation and AI agents:

- **not** in the `docker` group — the Docker socket is root-equivalent;
- **no** sudo, and no readable secrets (`.env` files stay `root:root 600`);
- reads logs through `systemd-journal` membership, plus whatever ACLs an
  application explicitly grants it.

It is opt-in via `CLAUDE_RO_PUBKEY` (the **public** half of a dedicated key —
never a shared personal key). The variable is deliberately not baked into this
repo so the bootstrap stays reusable and no host's access list is published.

Applications grant their own read access, keeping secrets out of reach:

```bash
# in an app's own setup — log directories ONLY, never .env or secret dirs
setfacl -R    -m u:claude_ro:rX /opt/<app>/logs
setfacl -R -d -m u:claude_ro:rX /opt/<app>/logs
```

## Order of operations on a fresh box

1. `bootstrap.sh` (this).
2. The edge proxy — owns `:80/:443`, joins `edge`, imports site snippets from
   `/opt/caddy-sites/*.caddy`.
3. Platform services: [`../woodpecker`](../woodpecker) (CI) and
   [`../uptime-kuma`](../uptime-kuma) (monitoring).
4. Applications: each gets its own `/opt/<app>` tree, a compose stack on `edge`,
   and a Caddy snippet.
