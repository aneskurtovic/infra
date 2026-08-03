#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# Platform host bootstrap — one-time, app-agnostic setup for a fresh box.
#
# Everything here is shared by EVERY application on the host: Docker, the
# `edge` network the TLS proxy uses to reach app containers, the firewall,
# SSH hardening, swap, fail2ban, and unattended security upgrades.
#
# Application repos own only their own concerns: their /opt/<app> tree, their
# private networks, their compose stacks. Nothing app-specific belongs here.
#
# Idempotent: safe to re-run. Run as root on Ubuntu 22.04/24.04.
#   sudo ./bootstrap.sh
#
# Optional read-only agent user (see README.md):
#   CLAUDE_RO_PUBKEY='ssh-ed25519 AAAA... comment' sudo -E ./bootstrap.sh
# ==========================================================================

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------- packages --
log "Base packages"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  apt-transport-https ca-certificates curl gnupg lsb-release \
  git vim wget ufw acl

# ------------------------------------------------------------------ docker --
log "Docker Engine + Compose v2 + Buildx"

# The APT repo is set up on EVERY run, not only on a fresh host. It used to sit
# inside the `! command -v docker` branch below, which meant a host that already
# had Docker from any other source — a provider image, get.docker.com, Ubuntu's
# `docker.io` — never got Docker's repo and therefore could never `apt-get
# install docker-buildx-plugin`. Observed in prod 2026-08-03: engine 29.2.1 and
# the compose plugin present, buildx absent, `docker.list` missing entirely.
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
docker_list="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
if [[ "$(cat /etc/apt/sources.list.d/docker.list 2>/dev/null)" != "$docker_list" ]]; then
  echo "$docker_list" >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
fi

# Engine packages stay guarded. Installing docker-ce over an engine that came
# from somewhere else can replace packages and bounce the daemon, taking every
# running container with it — not something a re-run of this script should ever
# do to a live host.
if ! command -v docker >/dev/null 2>&1; then
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  echo "docker: engine installed"
else
  echo "docker: engine already installed (left alone)"
fi

# CLI plugins ARE ensured every run. They are standalone binaries under
# /usr/libexec/docker/cli-plugins — adding them neither restarts the daemon nor
# touches a running container, so this is safe on a live host in a way the
# engine packages are not.
#
# Buildx is not optional: current Docker Compose uses Bake as its default
# builder, and without buildx every `compose build` silently degrades to the
# deprecated legacy builder with only a WARN line.
apt-get install -y -qq docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

if ! docker buildx version >/dev/null 2>&1; then
  echo "WARNING: docker buildx is still unavailable after installing docker-buildx-plugin." >&2
  echo "         'docker compose build' will fall back to the deprecated legacy builder." >&2
  echo "         Check that /etc/apt/sources.list.d/docker.list resolves for this release." >&2
fi

# ----------------------------------------------------------------- network --
# The ONE shared network. The edge proxy joins it and reverse-proxies to each
# app's container by name (e.g. `reverse_proxy portfolio:8080`), so adding a
# site is: run a container on `edge` + drop a Caddy snippet. External, so no
# `compose down` can delete it out from under the other stacks.
log "Shared edge network"
docker network inspect edge >/dev/null 2>&1 || docker network create edge
echo "edge: present"

# ---------------------------------------------------------------- firewall --
# Only the proxy's ports and SSH. Application containers are never published
# directly — they are reached through the edge network by the proxy.
log "Firewall (ufw)"
ufw --force enable
ufw allow 22/tcp    >/dev/null  # SSH
ufw allow 80/tcp    >/dev/null  # HTTP (ACME + redirect)
ufw allow 443/tcp   >/dev/null  # HTTPS
ufw allow 443/udp   >/dev/null  # HTTP/3 (QUIC)
ufw reload
ufw status verbose | head -12

# --------------------------------------------------------------------- ssh --
# Deploy pipelines SSH in with keys, so key-based root login must keep working:
# `prohibit-password` allows key auth while refusing passwords outright.
log "SSH hardening"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh 2>/dev/null || systemctl restart sshd
echo "ssh: root=key-only, passwords disabled"

# -------------------------------------------------------------------- swap --
# Small boxes ship with 0 swap; a build spike then OOM-kills live services.
# Swappiness 10 keeps the DB in RAM and only swaps under real pressure.
log "Swap (2 GiB) + swappiness"
if swapon --show 2>/dev/null | grep -q '/swapfile'; then
  echo "swap: already active"
else
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile 2>/dev/null ||
      dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null && echo "swap: enabled" || echo "swap: swapon failed (non-fatal)"
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi
if [ "$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)" != "10" ]; then
  sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
  echo 'vm.swappiness=10' >/etc/sysctl.d/99-platform.conf
  echo "swap: swappiness -> 10"
fi

# ---------------------------------------------------------------- fail2ban --
log "fail2ban (SSH jail)"
apt-get install -y -qq fail2ban
cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban || true
echo "fail2ban: sshd jail active"

# ------------------------------------------------------- unattended-upgrade --
log "Unattended security upgrades"
apt-get install -y -qq unattended-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
echo "unattended-upgrades: enabled"

# ---------------------------------------------------- read-only agent user --
# Genuine least-privilege identity for automation/agents: NOT in the docker
# group (the socket is root-equivalent), NO sudo, no readable secrets. It can
# read logs via systemd-journal and whatever ACLs an app grants it — nothing
# more. Physically cannot mutate or escalate.
#
# Opt-in: set CLAUDE_RO_PUBKEY to the PUBLIC half of a dedicated key.
if [ -n "${CLAUDE_RO_PUBKEY:-}" ]; then
  log "Read-only agent user (claude_ro)"
  id claude_ro >/dev/null 2>&1 || useradd --create-home --shell /bin/bash claude_ro
  usermod -aG systemd-journal claude_ro
  install -d -m 700 -o claude_ro -g claude_ro /home/claude_ro/.ssh
  printf '%s\n' "${CLAUDE_RO_PUBKEY}" >/home/claude_ro/.ssh/authorized_keys
  chmod 600 /home/claude_ro/.ssh/authorized_keys
  chown claude_ro:claude_ro /home/claude_ro/.ssh/authorized_keys
  echo "claude_ro: ready (journal read-only; grant log ACLs per app)"
else
  echo "claude_ro: skipped (set CLAUDE_RO_PUBKEY to enable)"
fi

log "Host bootstrap complete"
cat <<'EOF'
Next:
  1. Bring up the edge proxy (it owns :80/:443 and joins `edge`).
  2. Bring up platform services: woodpecker/ and uptime-kuma/.
  3. For each application: create its own /opt/<app> tree + compose stack on
     `edge`, and drop a Caddy site snippet in /opt/caddy-sites/.
EOF
