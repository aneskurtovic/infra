#!/usr/bin/env bash
set -euo pipefail

# ==========================================================================
# Platform backup — one run: quiesce, stage, snapshot, retain.
#
# Backs up what the PLATFORM owns and nothing else:
#
#   woodpecker-server-data   CI database: repo setup, EVERY per-repo deploy
#                            secret, build metadata. The most tedious thing on
#                            the box to reconstruct — nothing enumerates which
#                            repo holds which secret; you find out when a
#                            pipeline fails.
#   caddy-data               ACME account key + every issued certificate.
#   grafana-data             dashboards, users, API keys.
#   uptime-kuma-data         monitor definitions and their whole history.
#   host secret files        /opt/ci/*.env, /opt/caddy/caddy.env,
#                            /opt/observability/observability.env — the values
#                            the committed config only *references*.
#
# Plus the tenant hand-off directory: whatever tenants have dropped in
# /opt/backups/handoff/<tenant>/. The platform never learns what Postgres is;
# the tenant never learns what restic is. See README.md.
#
# NOT here, deliberately:
#   loki-data     7-day triage data with a working compactor; observability/
#                 OPERATIONS.md already settled that it is not worth restoring.
#   alloy-data    read positions only. Losing it re-reads recent container
#                 logs and duplicates a few lines.
#   tenant databases   a tenant produces its own consistent dump and puts it in
#                 the hand-off directory. The platform does not reach into a
#                 tenant's containers.
#
# Run by platform-backup.timer. Safe to run by hand:
#   /opt/backups/bin/backup.sh
# ==========================================================================

umask 077

# Sourced as well as loaded by systemd's EnvironmentFile=, so a hand run behaves
# exactly like a timer run. The FILE WINS over anything already in the
# environment — that is what makes the two identical, and it means
# `FOO=x backup.sh` is silently ignored for any key the file also sets. Edit the
# file. Keep its values simple and unquoted-safe: systemd's parser and the
# shell's do not agree about quoting in every corner.
ENV_FILE="${BACKUP_ENV_FILE:-/opt/backups/backup.env}"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups}"
STAGING="$BACKUP_ROOT/staging"
HANDOFF="$BACKUP_ROOT/handoff"
HELPER_IMAGE="${BACKUP_HELPER_IMAGE:-alpine:3.22}"

KEEP_DAILY="${BACKUP_KEEP_DAILY:-14}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"
HANDOFF_MAX_AGE_HOURS="${BACKUP_HANDOFF_MAX_AGE_HOURS:-30}"

# A STABLE restic "host", not $(hostname). Retention below groups snapshots by
# host, so a rebuilt box under a new hostname would otherwise start a second
# retention group: the old group stops being pruned and the new one has no
# history. The whole point of this repository is surviving a box, so the
# identity that matters is "the platform", not "this machine".
BACKUP_HOST="${BACKUP_HOST:-platform}"

log()  { printf '%s %s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '%s WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { printf '%s FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run as root (the volumes and secret files are root-only)"
command -v restic >/dev/null 2>&1 || die "restic is not installed — run backup/install.sh"
command -v docker >/dev/null 2>&1 || die "docker is not installed"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required — see backup/.env.example}"
export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$BACKUP_ROOT/restic-password}"
[[ -r "$RESTIC_PASSWORD_FILE" ]] ||
  die "cannot read $RESTIC_PASSWORD_FILE — the repository password lives there, root-only, mode 600"

# ------------------------------------------------------------------- locking --
# systemd will not start a second copy of a running oneshot unit, but a hand run
# during a timer run is entirely possible, and two restic processes against one
# repository is how you get a stale lock at 05:30 and no backups until someone
# notices. Skipping is the right outcome here, not failing: the other run is
# doing the work.
exec 9>"/run/platform-backup.lock"
if ! flock -n 9; then
  log "another backup run holds the lock — skipping this one"
  exit 0
fi

# ---------------------------------------------------------------- quiescing --
#
# Every volume here is copied while its service is STOPPED, one at a time, and
# started again immediately. That is deliberately the same procedure the manual
# runbooks already prescribe (woodpecker/BOOTSTRAP.md, uptime-kuma/OPERATIONS.md)
# rather than a second, subtler one:
#
#   - Three of these four volumes hold a live SQLite database. Copying its files
#     while it writes can yield an archive that restores into a corrupt state,
#     and a backup you cannot restore is worse than none because it is believed.
#   - It is correct WITHOUT knowing what is inside the volume. The platform
#     deliberately does not learn each service's storage engine — that knowledge
#     is exactly what the tenant hand-off contract exists to avoid needing.
#
# The cost is seconds of downtime per service, at 05:30, on services with no
# SLA. If a CI workflow is mid-run when the server stops, the agent reconnects;
# the workflow may still fail and need restarting. That is the accepted cost of
# a copy that restores.
#
# caddy is the ONE exception and is copied live. It owns :80/:443 — stopping it
# takes every site on the box down, monitoring and CI included, which is a far
# worse trade than a torn file in a certificate store that Caddy would re-issue
# on its own. The part of caddy-data that is genuinely irreplaceable, the ACME
# account key, is written once at first start and never again.
#
#   volume : container : stop|live
TARGETS=(
  "woodpecker-server-data:woodpecker-server:stop"
  "uptime-kuma-data:uptime-kuma:stop"
  "grafana-data:grafana:stop"
  "caddy-data:caddy:live"
)

# The values the committed config only references. Missing files are skipped
# with a warning — a fresh box legitimately has fewer of these — but a warning
# is right, because "the secret file is gone" and "the secret file was never
# backed up" look identical after the disk dies.
SECRET_PATHS=(
  /opt/ci/.env
  /opt/ci/server-oauth.env
  /opt/ci/agent.env
  /opt/caddy/caddy.env
  /opt/observability/observability.env
)

# NOT backed up: /opt/backups/backup.env and the restic password file. Both are
# the keys to this repository, and storing them inside it is both circular and a
# gift to anyone who cracks it. They belong in a password manager, off this box.
# DISASTER-RECOVERY.md opens by saying so.

# --------------------------------------------------------------- safety net --
# Only ever one container is stopped at a time, so one variable is enough — and
# a single variable cannot drift out of sync with reality the way a list can.
CURRENT_STOPPED=""
cleanup() {
  local rc=$?
  if [[ -n "$CURRENT_STOPPED" ]]; then
    warn "run ended with $CURRENT_STOPPED stopped — restarting it"
    docker start "$CURRENT_STOPPED" >/dev/null ||
      printf 'CRITICAL: %s is STILL STOPPED and could not be restarted — start it by hand NOW\n' \
        "$CURRENT_STOPPED" >&2
  fi
  return $rc
}
trap cleanup EXIT

started_at=$(date +%s)
log "platform backup starting (repository: ${RESTIC_REPOSITORY%%:*}:…, host label: $BACKUP_HOST)"

# Never auto-init. `restic init` against a typo'd or unmounted repository URL
# happily creates a brand-new empty repository, the run "succeeds", and the real
# history sits somewhere else untouched until the day you need it.
if ! restic cat config >/dev/null 2>&1; then
  die "repository is not reachable or not initialised: $RESTIC_REPOSITORY
     If this box has never been set up:  restic init
     If it has, this is a connectivity, credential, or password failure — fix
     that. Do NOT run 'restic init' to make this message go away; it would
     create an empty second repository and hide the real one."
fi

install -d -m 700 "$STAGING" "$STAGING/volumes" "$STAGING/secrets" "$HANDOFF"

# ---------------------------------------------------------------------- disk --
# Not this script's problem to solve, and reported anyway. Weekly reclamation
# (platform-docker-cleanup) was the only thing on this box producing a disk
# reading, and weekly is a poor sampling interval against ~890 MB/day of CI
# churn. This runs every night and is already disk-aware — it stages ~300 MB —
# so it is the cheapest place to get a daily number.
#
# The Grafana rule `platform-disk-high` keys on the literal string "WARN: disk".
# Keep that prefix stable if you reword the message.
DISK_WARN_PCT="${BACKUP_DISK_WARN_PCT:-85}"
disk_pct=$(df --output=pcent "$BACKUP_ROOT" | tail -1 | tr -dc '0-9')
disk_free=$(df -h --output=avail "$BACKUP_ROOT" | tail -1 | tr -d ' ')
if (( disk_pct > DISK_WARN_PCT )); then
  warn "disk: ${disk_pct}% used, ${disk_free} free (threshold ${DISK_WARN_PCT}%)"
else
  log "disk: ${disk_pct}% used, ${disk_free} free"
fi

# ------------------------------------------------------------------- volumes --
for target in "${TARGETS[@]}"; do
  IFS=: read -r volume container mode <<<"$target"

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    warn "volume $volume does not exist on this box — skipping"
    continue
  fi

  was_running=false
  if [[ "$mode" == "stop" ]]; then
    # Only restart what WE stopped. A container an operator deliberately left
    # down must still be down when this finishes.
    if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo false)" == "true" ]]; then
      was_running=true
      log "stopping $container for a consistent copy of $volume"
      docker stop "$container" >/dev/null
      CURRENT_STOPPED="$container"
    else
      log "$container is not running — copying $volume as-is"
    fi
  fi

  log "staging $volume"
  # Copied as a plain directory tree, NOT as a tar.gz, and that matters: restic
  # deduplicates by content, so an unchanged 112 MB database costs almost
  # nothing on the second night. A fresh tarball differs in every byte after the
  # first change, so fourteen daily generations of tarballs would cost fourteen
  # full copies. The manual runbooks tar because they have nowhere to put a tree.
  #
  # --network none: this helper needs no network, ever.
  docker run --rm \
    --network none \
    --security-opt no-new-privileges:true \
    -v "$volume:/data:ro" \
    -v "$STAGING/volumes:/staging" \
    "$HELPER_IMAGE" \
    sh -ec 'rm -rf "/staging/$1" && mkdir -p "/staging/$1" && cp -a /data/. "/staging/$1/"' \
    sh "$volume"

  if [[ "$was_running" == "true" ]]; then
    docker start "$container" >/dev/null
    CURRENT_STOPPED=""
    log "$container restarted"
  fi
done

# ------------------------------------------------------------------- secrets --
rm -rf "${STAGING:?}/secrets"
install -d -m 700 "$STAGING/secrets"
for path in "${SECRET_PATHS[@]}"; do
  if [[ -r "$path" ]]; then
    # Staged under its own absolute path, so a restore reads as a map of where
    # each file goes back to: staging/secrets/opt/ci/agent.env -> /opt/ci/agent.env
    install -D -m 600 "$path" "$STAGING/secrets$path"
    log "staged secret $path"
  else
    warn "secret file $path is missing or unreadable — not in this snapshot"
  fi
done
# `install -D` creates the intermediate directories itself, and not necessarily
# at 700. The whole tree is unreachable below /opt/backups (700) either way, but
# a staging tree holding every deploy secret is not the place to rely on one
# ancestor's mode being right.
find "$STAGING/secrets" -type d -exec chmod 700 {} +

# ------------------------------------------------------------------ hand-off --
# The platform sweeps whatever tenants left here; it does not produce it, and a
# tenant that has stopped producing is a real failure the platform cannot fix
# but must not hide. Stale is a warning, never fatal: one tenant's broken cron
# must not stop the platform's own backup.
shopt -s nullglob
handoff_dirs=("$HANDOFF"/*/)
shopt -u nullglob
if [[ ${#handoff_dirs[@]} -eq 0 ]]; then
  log "hand-off: no tenant directories yet (see backup/README.md for the contract)"
fi
for dir in "${handoff_dirs[@]}"; do
  tenant=$(basename "$dir")
  newest=$(find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  if [[ -z "$newest" ]]; then
    warn "hand-off: tenant '$tenant' has an empty directory — nothing to sweep"
    continue
  fi
  age_h=$(( ( $(date +%s) - ${newest%.*} ) / 3600 ))
  if (( age_h > HANDOFF_MAX_AGE_HOURS )); then
    warn "hand-off: tenant '$tenant' newest file is ${age_h}h old (threshold ${HANDOFF_MAX_AGE_HOURS}h) — that tenant's dump job is not running"
  else
    log "hand-off: tenant '$tenant' newest file is ${age_h}h old"
  fi
done

# ------------------------------------------------------------------ snapshot --
log "snapshotting"
restic backup \
  --tag platform \
  --host "$BACKUP_HOST" \
  --exclude-caches \
  --one-file-system \
  "$STAGING" "$HANDOFF"

# ----------------------------------------------------------------- retention --
# forget only — no --prune. Pruning rewrites pack files and is the expensive,
# lock-heavy half; it runs weekly in platform-backup-maintenance.service next to
# the integrity check. Forgetting daily keeps the snapshot list honest without
# making every night's run as slow as the worst night's.
#
# --group-by is pinned to host,tags rather than left at its default (host,paths)
# because the paths DO change: /opt/backups/handoff appears in the argument list
# the day a tenant first uses it. On the default grouping that silently starts a
# second retention group whose older sibling then keeps every snapshot forever.
log "applying retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"
restic forget \
  --tag platform \
  --host "$BACKUP_HOST" \
  --group-by host,tags \
  --keep-daily  "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY"

log "recent snapshots:"
restic snapshots --tag platform --host "$BACKUP_HOST" --latest 3 --compact || true

log "platform backup complete in $(( $(date +%s) - started_at ))s"
