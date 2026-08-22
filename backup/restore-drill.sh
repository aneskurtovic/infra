#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# Restore drill — restore a platform volume from the off-site repository into a
# SCRATCH docker volume and verify it, without touching anything live.
#
# This script exists because of one line in BACKLOG.md P1:
#
#   "A restore has actually been performed ... Until this happens the item is
#    not done, whatever the automation reports."
#
# Automation reporting success is evidence that a backup ran, not that it can be
# restored. The two failures this catches — a repository that snapshots
# something useless, and an operator who has never run the restore commands
# before the morning they need them — are both invisible to a green timer.
#
#   ./restore-drill.sh                             # newest snapshot, CI database
#   ./restore-drill.sh --volume grafana-data
#   ./restore-drill.sh --snapshot 4a5b6c7d --keep  # leave the scratch copy
#
# Write the result in OPERATIONS.md § "Restore drill log". An undated drill is
# indistinguishable from no drill.
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
BACKUP_HOST="${BACKUP_HOST:-platform}"
HELPER_IMAGE="${BACKUP_HELPER_IMAGE:-alpine:3.22}"

VOLUME="woodpecker-server-data"
SNAPSHOT="latest"
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volume)   VOLUME="${2:?--volume needs a value}"; shift 2 ;;
    --snapshot) SNAPSHOT="${2:?--snapshot needs a value}"; shift 2 ;;
    --keep)     KEEP=true; shift ;;
    -h|--help)  sed -n '3,30p' "$0"; exit 0 ;;
    *)          echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '%s %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '%s WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { printf '%s FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run as root"
command -v restic >/dev/null 2>&1 || die "restic is not installed — run backup/install.sh"
command -v docker >/dev/null 2>&1 || die "docker is not installed"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required — see backup/.env.example}"
export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$BACKUP_ROOT/restic-password}"

# The scratch names. Everything this script creates carries the prefix, and
# nothing without the prefix is ever written to — that invariant is what makes
# it safe to run on the live box during working hours, which is the only way a
# drill ever actually gets run.
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SCRATCH_DIR="$BACKUP_ROOT/restore-drill/$STAMP"
SCRATCH_VOLUME="restore-drill-$VOLUME-$STAMP"
SOURCE_PATH="$BACKUP_ROOT/staging/volumes/$VOLUME"

cleanup() {
  local rc=$?
  if [[ "$KEEP" == "true" ]]; then
    log "--keep: leaving $SCRATCH_DIR and volume $SCRATCH_VOLUME in place"
    log "        remove them with: rm -rf $SCRATCH_DIR && docker volume rm $SCRATCH_VOLUME"
  else
    rm -rf "$SCRATCH_DIR"
    docker volume rm "$SCRATCH_VOLUME" >/dev/null 2>&1 || true
  fi
  return $rc
}
trap cleanup EXIT

log "restore drill: volume=$VOLUME snapshot=$SNAPSHOT repository=${RESTIC_REPOSITORY%%:*}:…"

# --------------------------------------------------------------- 1. restore --
install -d -m 700 "$BACKUP_ROOT/restore-drill" "$SCRATCH_DIR"

# --include limits the restore to one volume's subtree. Without it this pulls
# every volume plus every secret, which turns a five-minute drill into one
# nobody repeats.
log "restoring $SOURCE_PATH from snapshot $SNAPSHOT"
restic restore "$SNAPSHOT" \
  --host "$BACKUP_HOST" \
  --tag platform \
  --include "$SOURCE_PATH" \
  --target "$SCRATCH_DIR"

RESTORED="$SCRATCH_DIR$SOURCE_PATH"
[[ -d "$RESTORED" ]] ||
  die "snapshot $SNAPSHOT contains no $SOURCE_PATH — either the volume was not
     backed up, or its name changed. Check: restic ls $SNAPSHOT | grep volumes/"

file_count=$(find "$RESTORED" -type f | wc -l)
byte_count=$(du -sb "$RESTORED" | cut -f1)
(( file_count > 0 )) || die "restored tree is EMPTY — this backup is not a backup"
log "restored $file_count files, $(( byte_count / 1024 )) KiB"

# ------------------------------------------------------- 2. scratch volume --
# The backlog asks for a restore "into a scratch volume", not just a directory,
# and the distinction is not pedantry: this is the step that proves ownership
# and permissions survive the round trip. A tree that restores perfectly into
# /opt and then mounts into a container the service cannot read is a restore
# that fails at exactly the wrong moment.
log "loading into scratch volume $SCRATCH_VOLUME"
docker volume create "$SCRATCH_VOLUME" >/dev/null
docker run --rm \
  --network none \
  --security-opt no-new-privileges:true \
  -v "$RESTORED:/restored:ro" \
  -v "$SCRATCH_VOLUME:/data" \
  "$HELPER_IMAGE" \
  sh -ec 'cp -a /restored/. /data/ && ls -la /data | head -20'

# ---------------------------------------------------------------- 3. verify --
# Databases are found by MAGIC BYTES, not by filename. Every one of these
# services could rename or relocate its database in a future version, and a
# drill that silently stops checking anything because a filename changed is a
# drill that reports PASS forever.
failures=0
sqlite_checked=0
while IFS= read -r -d '' candidate; do
  [[ "$(head -c 15 "$candidate" 2>/dev/null)" == "SQLite format 3" ]] || continue
  if ! command -v sqlite3 >/dev/null 2>&1; then
    warn "$(basename "$candidate") is a SQLite database but sqlite3 is not installed — integrity NOT verified"
    warn "install it (apt-get install -y sqlite3) and re-run; this is the check that matters most"
    continue
  fi
  # Opened read-WRITE, deliberately. This is a throwaway copy that is deleted
  # when the drill ends, and a real restore opens these databases the same way:
  # letting SQLite replay the write-ahead log is part of what is being tested.
  # `-readonly` would refuse a WAL database whose -shm file is absent and report
  # a failure the actual restore would not have.
  result=$(sqlite3 "$candidate" 'PRAGMA integrity_check;' 2>&1 || echo "sqlite3 failed")
  sqlite_checked=$(( sqlite_checked + 1 ))
  if [[ "$result" == "ok" ]]; then
    log "integrity_check ok: ${candidate#"$RESTORED"/}"
  else
    warn "integrity_check FAILED: ${candidate#"$RESTORED"/} -> $result"
    failures=$(( failures + 1 ))
  fi
done < <(find "$RESTORED" -type f -size +512c -print0)

log "largest files in the restored tree:"
find "$RESTORED" -type f -printf '%s\t%p\n' | sort -rn | head -5 |
  while IFS=$'\t' read -r size path; do
    printf '  %10d  %s\n' "$size" "${path#"$RESTORED"/}"
  done

echo
if (( failures > 0 )); then
  echo "RESTORE DRILL: FAIL — $failures database(s) restored corrupt"
  exit 1
fi

echo "RESTORE DRILL: PASS"
echo "  volume    $VOLUME"
echo "  snapshot  $SNAPSHOT"
echo "  files     $file_count ($(( byte_count / 1024 )) KiB)"
echo "  sqlite    $sqlite_checked database(s) passed integrity_check"
echo
echo "Record it — paste this row into backup/OPERATIONS.md § Restore drill log:"
printf '| %s | %s | %s | %s files, %s SQLite ok | PASS | |\n' \
  "$(date -u +%Y-%m-%d)" "$VOLUME" "$SNAPSHOT" "$file_count" "$sqlite_checked"
