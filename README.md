# infra

Self-hosted platform infrastructure for my personal projects — a single small box
running the shared services every project leans on: [Woodpecker
CI](https://woodpecker-ci.org/) for build/deploy, [Uptime
Kuma](https://github.com/louislam/uptime-kuma) for availability monitoring, and
[Loki](https://grafana.com/oss/loki/) + [Grafana](https://grafana.com/) for
centralized logs — behind one TLS proxy on a shared `edge` network.

GitHub stays the forge (OAuth + webhooks); Woodpecker owns build and deploy. No
GitHub Actions, no third-party CI. This repo is the source of truth for the
platform — each application keeps only its own `.woodpecker/` pipelines. Shared,
cross-project services (CI, monitoring, and in time the edge proxy and host
bootstrap) live here so no single application owns the platform.

## Why this exists

CI that serves many projects shouldn't be owned by one of them. This repo pulls
the shared platform config out of any single application so adding a new project
means adding a repo, not editing an unrelated one. Applications are tenants; the
platform is neutral.

## Architecture

```mermaid
flowchart LR
    subgraph GH[GitHub]
      R1[app repo A]
      R2[app repo B]
    end
    subgraph Box[One host]
      subgraph edge[edge network]
        CADDY[Caddy · TLS :80/:443]
        GRAF[Grafana]
        LOKI[(Loki · 7d)]
      end
      subgraph ci[ci-network]
        WS[woodpecker-server]
        WA[woodpecker-agent · max 1 workflow]
      end
      WS --- edge
      APPS[deployed apps]
      ALLOY[Alloy · ro docker.sock]
    end
    R1 & R2 -- webhook --> WS
    CADDY -- proxies UI --> WS
    CADDY -- proxies UI --> GRAF
    WS -- schedules --> WA
    WA -- rsync + atomic symlink over SSH --> APPS
    ALLOY -- scrapes every container --> LOKI
    GRAF -- queries --> LOKI
```

- **`woodpecker-server`** — OAuth, webhooks, scheduling, UI. Reachable only
  through Caddy over HTTPS.
- **`woodpecker-agent`** — runs each pipeline's steps as Docker containers. Caps
  at **one workflow at a time** so CI never contends with live application
  services on the same box. Scale by adding an agent host, not concurrency.
- **Caddy** — owns `:80/:443`, auto-issues Let's Encrypt, fronts the CI UI and
  every app on the shared `edge` network.
- **Loki + Alloy + Grafana** — one collector reads every container's stdout over
  a read-only Docker socket and labels it by `stack`, so each application's logs
  are queryable without SSH. Loki has no auth and is loopback-only; Grafana is
  the sole public path, behind Basic auth.

## Design principles

- **Secrets never touch git.** Committed config holds only variable *references*
  with `:?required` guards; real values live in root-only files on the host
  (`/opt/ci/*.env`) and inside Woodpecker's database volume. That separation is
  what makes this repo safe to publish.
- **Least-privilege deploys.** Deploy credentials are **repository-scoped, never
  global** — each repo's pipeline can reach only its own target, as its own
  least-privilege user. No pipeline holds a credential it doesn't need.
- **Immutable, atomic releases.** Deploys rsync a build to a SHA-named directory
  and flip an atomic `current` symlink, keeping the last few for instant rollback.
- **Pinned everything.** Server and agent images are version-pinned and upgraded
  together.

## Layout

```
host/
  bootstrap.sh         # one-time host setup: Docker, edge network, ufw, SSH, swap, fail2ban
  README.md            # platform-vs-application boundary; read-only agent user
woodpecker/
  docker-compose.yml   # CI server + agent (env-ref only, no values)
  .env.example         # documented non-secret config
  BOOTSTRAP.md         # one-time setup runbook
uptime-kuma/
  docker-compose.yml   # availability dashboard (edge network, external data volume)
  MIGRATION.md         # move from Ludo's stack, preserving monitor history
  OPERATIONS.md        # steady-state runbook: monitors, notifications, backup/restore
observability/
  docker-compose.yml   # Loki + Alloy + Grafana (external data volumes)
  loki/loki-config.yml # storage, 7-day retention, ingestion limits
  alloy/config.alloy   # docker discovery + the stack/service label scheme
  grafana/provisioning # Loki datasource, committed rather than click-configured
  .env.example         # Grafana root URL + bootstrap admin
  MIGRATION.md         # move off Ludo's two Loki/Promtail pairs
  OPERATIONS.md        # steady-state runbook: queries, onboarding a tenant, backup
caddy/
  Caddyfile            # edge proxy: global options + import of tenant snippets
  docker-compose.yml   # the proxy that owns :80/:443 (external cert volume)
  .env.example         # ACME address + values referenced by tenant snippets
  MIGRATION.md         # moving the edge proxy off an app onto the platform
  ci.aneskurtovic.caddy       # edge site for the CI UI
  uptime.aneskurtovic.caddy   # edge site for the monitoring dashboard (basic_auth via env)
  logs.aneskurtovic.caddy     # edge site for Grafana (basic_auth via env)
```

## Setup

See [`woodpecker/BOOTSTRAP.md`](woodpecker/BOOTSTRAP.md).

## License

MIT
