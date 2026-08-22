#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# Weekly repository maintenance: prune, then verify.
#
# Split out of backup.sh on purpose. The nightly run must stay short, because
# it stops CI and the dashboards while it works; prune rewrites pack files and
# check re-reads data, and neither has any reason to hold that downtime open.
#
# ORDER IS LOAD-BEARING: prune first, check second. Pruning removes the data
# that `forget` orphaned; checking afterwards verifies the repository as it will
# actually be restored from. Checking first would verify a state that no longer
# exists ten seconds later.
#
# Run by platform-backup-maintenance.timer. Safe to run by hand:
#   /opt/backups/bin/maintenance.sh
# ==========================================================================

umask 077

ENV_FILE="${BACKUP_ENV_FILE:-/opt/backups/backup.env}"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups}"
# How much of the repository's actual data to re-read each week. Structure is
# always checked in full; this is the expensive part — it downloads the packs it
# reads. 10% of a small repository is minutes and costs little egress, and over
# ten weeks it has read everything, which a 0% check never does. A `check` that
# never reads data cannot detect bit rot at the storage provider, which is one
# of the two failures this whole item exists to survive.
READ_DATA_SUBSET="${BACKUP_CHECK_READ_DATA_SUBSET:-10%}"

log()  { printf '%s %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run as root"
command -v restic >/dev/null 2>&1 || die "restic is not installed — run backup/install.sh"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required — see backup/.env.example}"
export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$BACKUP_ROOT/restic-password}"

# Shares the nightly run's lock. A prune that starts while a backup is running
# is not dangerous — restic locks the repository itself — but it would make the
# backup wait with CI stopped, which is the one thing this split exists to avoid.
exec 9>"/run/platform-backup.lock"
if ! flock -n 9; then
  log "a backup run holds the lock — skipping maintenance this week"
  exit 0
fi

started_at=$(date +%s)

log "pruning"
restic prune

log "checking structure + ${READ_DATA_SUBSET} of the data"
# NOTE: a failure here is the alarm this repository exists to raise. It exits
# non-zero, systemd marks the unit failed, and the message lands in the journal
# under SyslogIdentifier=platform-backup-maintenance — which Alloy ships to Loki,
# so it is queryable in Grafana as:
#   {stack="platform", service="platform-backup-maintenance"}
# Do not "fix" a failing check by deleting snapshots. Read
# OPERATIONS.md § "When check fails" first.
restic check --read-data-subset="$READ_DATA_SUBSET"

log "repository statistics:"
restic stats --mode raw-data || true

log "maintenance complete in $(( $(date +%s) - started_at ))s"
