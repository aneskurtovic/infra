#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# Install the platform backup stack onto the box. Idempotent — re-running is
# safe and re-heals drifted permissions.
#
#   sudo ./install.sh
#
# What it does NOT do, deliberately:
#   - it does not create /opt/backups/backup.env with real values, and it does
#     not invent a repository password. Both are secrets; this repo is public.
#   - it does not run `restic init`. Initialising a repository is a decision
#     with a password you must not lose, taken once, by a human who wrote that
#     password down somewhere off this box. See README.md.
#   - it does not start a backup. Run one by hand first and watch it.
#
# Follows the same shape as every other stack here: the repo is a checkout you
# copy FROM, not something the box depends on continuing to exist. After this
# runs, /tmp/infra can be deleted and backups keep working.
# ==========================================================================

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root (sudo $0)" >&2
  exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups}"

log() { printf '\n=== %s ===\n' "$1"; }

# ------------------------------------------------------------------ restic --
log "restic"
# From the distro, on purpose. The repo's "pinned everything" principle is about
# CONTAINER IMAGES, where an unpinned tag silently changes what runs. restic is
# a host package on the security-update path that unattended-upgrades already
# manages, and hand-pinning a binary from a release page would take it off that
# path — the opposite of the intent.
if ! command -v restic >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq restic
fi

# sqlite3 is not needed to take a backup. It is needed to VERIFY one, and the
# restore drill is the only part of this stack that proves the rest works.
if ! command -v sqlite3 >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq sqlite3 || echo "sqlite3 install failed (drill will warn instead of verifying)"
fi

restic_version=$(restic version | awk '{print $2}')
echo "restic: $restic_version"
# `check --read-data-subset=n%` — percentage form — landed in 0.15. On anything
# older the weekly maintenance run reads nothing at all and still exits 0, which
# is the worst possible outcome: a verification that reports success without
# verifying. Fail loudly here instead.
if [[ "$(printf '%s\n0.15.0\n' "$restic_version" | sort -V | head -1)" != "0.15.0" ]]; then
  echo "ERROR: restic >= 0.15 is required (--read-data-subset=n% is not supported before it)." >&2
  echo "       This box has $restic_version. Upgrade the distro package, or use" >&2
  echo "       'restic self-update' and re-run this script." >&2
  exit 1
fi

# ------------------------------------------------------------------- layout --
log "Directory layout"
# 700 root, and created BEFORE anything bind-mounts them. The staging tree holds
# every per-repository deploy secret and the ACME account key in the clear; a
# bind mount that creates a parent directory first would leave it 0755 and the
# chmod that follows would be closing a door someone already walked through.
install -d -m 700 -o root -g root \
  "$BACKUP_ROOT" \
  "$BACKUP_ROOT/bin" \
  "$BACKUP_ROOT/staging" \
  "$BACKUP_ROOT/staging/volumes" \
  "$BACKUP_ROOT/staging/secrets" \
  "$BACKUP_ROOT/handoff" \
  "$BACKUP_ROOT/restore-drill"
# Re-heal permissions on a directory an earlier manual runbook may have created.
chmod 700 "$BACKUP_ROOT"
echo "$BACKUP_ROOT: present, mode 700 root:root"

log "Scripts"
for script in backup.sh maintenance.sh restore-drill.sh; do
  install -m 700 "$SRC/$script" "$BACKUP_ROOT/bin/$script"
  echo "installed $BACKUP_ROOT/bin/$script"
done

# ------------------------------------------------------------------ secrets --
log "Secret files"
if [[ ! -f "$BACKUP_ROOT/backup.env" ]]; then
  install -m 600 "$SRC/.env.example" "$BACKUP_ROOT/backup.env"
  echo "created $BACKUP_ROOT/backup.env FROM THE EXAMPLE — it will not work until you edit it"
else
  chmod 600 "$BACKUP_ROOT/backup.env"
  echo "$BACKUP_ROOT/backup.env: already present, left alone"
fi

if [[ ! -f "$BACKUP_ROOT/restic-password" ]]; then
  install -m 600 /dev/null "$BACKUP_ROOT/restic-password"
  echo "created EMPTY $BACKUP_ROOT/restic-password"
else
  chmod 600 "$BACKUP_ROOT/restic-password"
  echo "$BACKUP_ROOT/restic-password: already present, left alone"
fi

# ------------------------------------------------------------------- systemd --
log "systemd units"
for unit in "$SRC"/systemd/*; do
  install -m 644 "$unit" "/etc/systemd/system/$(basename "$unit")"
  echo "installed $(basename "$unit")"
done
systemctl daemon-reload

# Timers are enabled but NOT started against an unconfigured repository — the
# first thing a new operator would see is a failed unit at 05:30 and no idea
# whether the stack is broken or merely unfinished.
if [[ -s "$BACKUP_ROOT/restic-password" ]] && grep -q '^RESTIC_REPOSITORY=..*' "$BACKUP_ROOT/backup.env" &&
   ! grep -q '^RESTIC_REPOSITORY=sftp:REPLACE' "$BACKUP_ROOT/backup.env"; then
  systemctl enable --now platform-backup.timer platform-backup-maintenance.timer
  echo "timers: enabled and started"
  systemctl list-timers 'platform-backup*' --no-pager || true
else
  echo "timers: installed but NOT enabled — $BACKUP_ROOT/backup.env and"
  echo "        $BACKUP_ROOT/restic-password are still unconfigured."
fi

log "Next steps"
cat <<'EOF'
  1. Put the repository password in /opt/backups/restic-password (mode 600) and
     STORE THE SAME PASSWORD OFF THIS BOX. Lose it and every snapshot is
     unreadable — there is no recovery path, by design.
  2. Fill /opt/backups/backup.env: RESTIC_REPOSITORY and whatever credentials
     that backend needs.
  3. Initialise the repository, ONCE, ever:
       set -a; . /opt/backups/backup.env; set +a
       RESTIC_PASSWORD_FILE=/opt/backups/restic-password restic init
  4. Run one backup by hand and read the output:
       /opt/backups/bin/backup.sh
  5. Enable the timers (re-running this script does it once step 2 is done):
       systemctl enable --now platform-backup.timer platform-backup-maintenance.timer
  6. Run the restore drill and write the date in backup/OPERATIONS.md:
       /opt/backups/bin/restore-drill.sh
     Until step 6 happens, this box has automation, not backups.
EOF
