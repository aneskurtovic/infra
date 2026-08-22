#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# Platform host bootstrap — one-time, app-agnostic setup for a fresh box.
#
# Everything here is shared by EVERY application on the host: Docker and its
# daemon defaults, the `edge` network the TLS proxy uses to reach app
# containers, the firewall, SSH hardening, swap, kernel settings, time sync, the
# journal cap, weekly Docker disk reclamation, fail2ban, and unattended security
# upgrades.
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

# ------------------------------------------------------------ daemon.json --
# Written BEFORE the daemon is first started, so a fresh box never runs a single
# container under the defaults this replaces.
#
# Two settings, both closing a gap measured on the live box (BACKLOG.md P8):
#
#   log-driver/log-opts — every long-running container already sets its own
#     limits in its compose file. The uncovered set is Woodpecker STEP
#     containers, created through the Docker API with `logopts=map[]`: the
#     daemon default, which is unbounded. Measured steps were kilobytes, so this
#     guards against one pathological build looping on stderr, not against
#     normal CI.
#
#   live-restore — `Live Restore Enabled: false` today, which means a daemon
#     restart takes every container on the box down with it. On a single-host
#     platform where the proxy owns :80/:443, that is a full outage every time
#     Docker is upgraded.
DOCKER_DAEMON_JSON='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}'

install -d -m 755 /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  printf '%s\n' "$DOCKER_DAEMON_JSON" >/etc/docker/daemon.json
  echo "daemon.json: written"
  docker_daemon_json_changed=true
elif [[ "$(cat /etc/docker/daemon.json)" == "$DOCKER_DAEMON_JSON" ]]; then
  echo "daemon.json: already correct"
  docker_daemon_json_changed=false
else
  # NOT overwritten, deliberately, and this is the one place this script stops
  # re-healing drift. daemon.json is host-wide and is where registry mirrors,
  # DNS, storage-driver and address-pool settings also live; silently replacing
  # someone's file with ours could break networking on a box we cannot see.
  echo "WARNING: /etc/docker/daemon.json exists and differs from the platform's." >&2
  echo "         LEFT ALONE. Merge by hand, then re-run. Difference:" >&2
  diff <(printf '%s\n' "$DOCKER_DAEMON_JSON") /etc/docker/daemon.json >&2 || true
  docker_daemon_json_changed=false
fi

# Validate before anything acts on it. A malformed daemon.json does not fail
# loudly at reload — it fails at the NEXT daemon start, which is typically a
# reboot, which is typically not when someone is watching.
if [[ "$docker_daemon_json_changed" == "true" ]] && dockerd --validate --config-file=/etc/docker/daemon.json 2>/dev/null; then
  echo "daemon.json: validated"
elif [[ "$docker_daemon_json_changed" == "true" ]]; then
  echo "WARNING: could not validate daemon.json (old dockerd, or invalid config)." >&2
  echo "         Check 'dockerd --validate --config-file=/etc/docker/daemon.json'." >&2
fi

systemctl enable --now docker

# Apply it with RELOAD, never restart. `systemctl restart docker` stops every
# container on the box — including the proxy that owns :80/:443 — which is
# exactly the outage `live-restore` above exists to prevent, and it would be
# absurd to cause it while turning that setting on.
#
# Reload is enough for both settings. Note what it does NOT do: containers keep
# the log options they were created with, so existing ones only pick up the new
# default when they are next recreated. New CI step containers get it
# immediately, which is the set that was actually uncovered.
if [[ "$docker_daemon_json_changed" == "true" ]]; then
  systemctl reload docker && echo "docker: config reloaded (no containers restarted)" ||
    echo "WARNING: 'systemctl reload docker' failed; config applies at next daemon start" >&2
fi

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
log "Swap (2 GiB)"
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

# ------------------------------------------------------------ kernel state --
# Everything here was ALREADY CORRECT on the production box on 2026-08-19 — by
# Ubuntu default, not because anything in this repo said so. That is fine until
# a distro upgrade or a different provider image changes a default and the
# platform silently loses a property it never knew it had (BACKLOG.md P20).
#
# Nothing below is a tuning guess. Every value is the one that was measured on
# the box; the `default.*` lines mirror their measured `all.*` sibling so an
# interface added later inherits the same behaviour. P20's own rule: pin what is
# already correct, do not invent values.
#
# This replaced a real latent bug. The old version wrote 99-platform.conf ONLY
# inside an `if swappiness != 10` branch, so on a box where the runtime value
# was already 10 — set by hand, or by another file — the drop-in was never
# created and the setting did not survive a reboot. The file is now written
# unconditionally; that is what "idempotent" has to mean for a persisted
# setting, not "written the first time it looked wrong".
log "Kernel settings (sysctl)"
cat >/etc/sysctl.d/99-platform.conf <<'EOF'
# Managed by infra/host/bootstrap.sh. Edit there, not here.

# Keep the database in RAM; swap only under genuine pressure.
vm.swappiness = 10

# Asserted, not inherited. The three `all.*`/`tcp_syncookies` values are exactly
# what was measured on 2026-08-19; the two `default.*` lines mirror their
# measured sibling so an interface added later starts out the same.
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
EOF
sysctl -p /etc/sysctl.d/99-platform.conf >/dev/null 2>&1 ||
  echo "WARNING: some sysctls in 99-platform.conf were not applied" >&2
echo "sysctl: 99-platform.conf applied"

# File-descriptor limits are DELIBERATELY not set here. P20 lists them as the
# one item in its group that is "not merely inherited, it is unexamined" — and
# pinning a number nobody has measured against a symptom nobody has seen is the
# exact thing that item's "Not this" forbids. Report them instead, so the next
# person on the box has the measurement without knowing to look for it.
printf 'fds: fs.file-max=%s  dockerd LimitNOFILE=%s\n' \
  "$(cat /proc/sys/fs/file-max 2>/dev/null || echo '?')" \
  "$(systemctl show docker -p LimitNOFILE --value 2>/dev/null || echo '?')"

# --------------------------------------------------------------- time sync --
# Asserted for the same reason as the sysctls above: correct today by distro
# default. Certificate validation, log correlation across Loki, and TOTP all
# quietly depend on it.
log "Time synchronisation"
timedatectl set-ntp true 2>/dev/null || true
# `|| true` on both: `set -o pipefail` is in force, so a failing head would take
# the whole bootstrap down over a status line.
{ timedatectl show -p NTP -p NTPSynchronized --value 2>/dev/null || true; } | tr '\n' ' ' || true
echo ""

# ----------------------------------------------------------------- journald --
# 2.4 GB and entirely default on 2026-08-19: every line of journald.conf
# commented out, so the cap is journald's implicit 10% of the filesystem —
# ~3.8 GB here, of which it had used two thirds. That is a tenth of the volume
# permanently spent on logs Alloy also ships to Loki.
#
# The driver is relentless SSH scanning, which fail2ban bans but cannot stop
# from being logged. 500 M is generous against that.
#
# A DROP-IN, not an edit of journald.conf: the distro owns that file, and a
# script that rewrites it fights the package manager on every upgrade.
log "Journal size cap"
install -d -m 755 /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-platform.conf <<'EOF'
# Managed by infra/host/bootstrap.sh. Edit there, not here.
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
EOF
systemctl restart systemd-journald 2>/dev/null || true
# The cap only bounds FUTURE growth; journald does not retroactively shrink to a
# new SystemMaxUse until it next rotates. Vacuum once so the 2.4 GB is actually
# returned rather than sitting there until enough new logs arrive to trigger it.
{ journalctl --vacuum-size=500M 2>&1 || true; } | tail -1 || true
echo "journald: capped at 500M"

# NOT deleted here: /var/log/dmesg.0 (92 MB) and btmp/btmp.1 (49 MB of failed
# logins). They are logrotate's, not journald's, and a bootstrap script that
# deletes log files someone might be reading is doing more than it was asked to.
# BACKLOG.md P12 tracks reclaiming them deliberately.

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

# -------------------------------------------------- docker disk reclamation --
# The platform's own disk safety. Until now the ONLY mechanism preventing disk
# exhaustion on this box was `ludo-docker-cleanup.timer` — a systemd timer
# installed by a TENANT's deploy script. A change in that application's repo
# could silently remove the platform's sole reclamation path, and the platform
# would not find out until the disk filled. That is the tenant boundary
# inverted: the platform depending on an application for its own survival
# (BACKLOG.md P2).
#
# Measured 2026-08-19: disk 26 G / 38 G (72%), build cache regrowing 2.675 GB in
# 3 days ≈ 890 MB/day of CI churn. The weekly sawtooth is stable WHILE the timer
# works — and roughly 12 days from a full disk if it stops.
#
# This does not remove the tenant's timer. It makes it irrelevant: whichever
# runs first reclaims, the other finds nothing to do, and deleting the tenant's
# changes nothing about platform safety. That is the actual goal.
#
# Written inline rather than shipped as files next to this script, matching how
# this file already installs the fail2ban jail and the apt config: bootstrap.sh
# stays one thing you can copy to a fresh box and run.
log "Docker disk reclamation (platform-owned)"

cat >/usr/local/sbin/platform-docker-cleanup <<'CLEANUP'
#!/usr/bin/env bash
set -euo pipefail

# Managed by infra/host/bootstrap.sh. Edit there, not here.
#
# Weekly reclamation of build cache and unused images. Runs as
# platform-docker-cleanup.service; its output goes to the journal under that
# identifier, which Alloy ships to Loki — so the disk sawtooth is queryable in
# Grafana as {stack="platform", service="platform-docker-cleanup"} instead of
# needing an SSH and a df, which is how the 72% figure had to be found.

DISK_WARN_PCT="${DISK_WARN_PCT:-85}"

usage_pct() { df --output=pcent / | tail -1 | tr -dc '0-9'; }
avail()     { df -h --output=avail / | tail -1 | tr -d ' '; }

before=$(usage_pct)
echo "disk before: ${before}% used, $(avail) free"
docker system df

# `-a` removes UNUSED cache and images only; a running build's cache and any
# image backing a container are held. No age filter on the builder cache: that
# is what the measured, working sawtooth uses, and keeping a week of cache would
# retain ~6 GB of the ~890 MB/day churn instead of reclaiming it.
docker builder prune -af
docker image prune -af --filter "until=168h"

# VOLUMES ARE NEVER PRUNED HERE, and that is not an oversight. A stopped
# container's volume looks unused and holds a database; the leaked volumes worth
# removing are identified and removed deliberately (BACKLOG.md P12). Nor is
# `docker system prune` used — it reaches networks too.

after=$(usage_pct)
echo "disk after: ${after}% used, $(avail) free"
docker system df

if (( after > DISK_WARN_PCT )); then
  echo "WARN: disk at ${after}% after normal reclamation (threshold ${DISK_WARN_PCT}%) — escalating"
  # Drop the age filter: at this point keeping a week of images to speed up CI
  # is the wrong trade against running out of space.
  docker image prune -af
  final=$(usage_pct)
  echo "disk after escalation: ${final}% used, $(avail) free"
  if (( final > DISK_WARN_PCT )); then
    echo "WARN: disk STILL at ${final}% — reclamation is no longer keeping up with growth"
  fi
fi
CLEANUP
chmod 700 /usr/local/sbin/platform-docker-cleanup

cat >/etc/systemd/system/platform-docker-cleanup.service <<'EOF'
[Unit]
Description=Platform Docker disk reclamation (build cache + unused images)
Documentation=https://github.com/aneskurtovic/infra/blob/main/host/README.md
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/platform-docker-cleanup
SyslogIdentifier=platform-docker-cleanup
Nice=15
IOSchedulingClass=idle
TimeoutStartSec=1h

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/platform-docker-cleanup.timer <<'EOF'
[Unit]
Description=Weekly platform Docker disk reclamation
Documentation=https://github.com/aneskurtovic/infra/blob/main/host/README.md

[Timer]
# Sunday 03:00 — ahead of everything else already on this box: the tenant's
# 04:00 Postgres dump, its own 05:00 cleanup, the 05:30 platform backup, and
# 07:00 backup maintenance. Running first means the backup stages onto a disk
# that has just been reclaimed.
OnCalendar=Sun *-*-* 03:00:00
RandomizedDelaySec=10m
# A box that was off on Sunday still reclaims when it comes back. Without this,
# one missed week silently becomes two.
Persistent=true
Unit=platform-docker-cleanup.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now platform-docker-cleanup.timer >/dev/null 2>&1 ||
  echo "WARNING: could not enable platform-docker-cleanup.timer" >&2
echo "platform-docker-cleanup: weekly timer enabled (Sun 03:00)"

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
  2. Bring up platform services: woodpecker/, uptime-kuma/, observability/.
  3. Install the backup stack: backup/install.sh. Nothing above is backed up
     until it runs, and nothing is proven until its restore drill has.
  4. For each application: create its own /opt/<app> tree + compose stack on
     `edge`, and drop a Caddy site snippet in /opt/caddy-sites/.

Installed here and worth knowing about:
  - platform-docker-cleanup.timer  weekly, Sun 03:00 — the platform's own disk
    reclamation. It does not depend on, and is not replaced by, any tenant's
    cleanup timer.
  - /etc/docker/daemon.json        log limits for CI step containers + live
    restore, so a daemon restart no longer takes every site down.
  - journald capped at 500M, vacuumed once on install.
EOF
