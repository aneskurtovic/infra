# Backup operations runbook

Steady state for the platform backup stack. First install is
[`README.md`](README.md); rebuilding a lost box is
[`../DISASTER-RECOVERY.md`](../DISASTER-RECOVERY.md).

Every command here runs as root on the box. `restic` needs the repository and
password, so either run the wrapper scripts (which load
`/opt/backups/backup.env` themselves) or load it first:

```bash
set -a; . /opt/backups/backup.env; set +a
export RESTIC_PASSWORD_FILE=/opt/backups/restic-password
```

## Is it working?

```bash
systemctl list-timers 'platform-backup*' --no-pager
systemctl status platform-backup.service --no-pager
restic snapshots --tag platform --host platform --compact | tail -20
```

The check that actually matters is the third one: a timer that fires and a unit
that exits 0 both describe the box's *intent*. The snapshot list is the only one
that describes the repository, which is the thing you will restore from.

From Grafana, without SSH:

```logql
{stack="platform", service="platform-backup"}
{stack="platform", service=~"platform-backup.*"} |= "WARN"
```

## Restoring one thing

### A platform volume

Stop the service first. Restoring into a volume a running container has open
gives you a container holding deleted inodes and a directory that looks right —
the failure surfaces at the next restart, long after you have declared success.

```bash
VOLUME=woodpecker-server-data

# 1. Keep what is there now. This is the step people skip and regret: if the
#    snapshot turns out to be the wrong one, the current state is already gone.
docker run --rm -v "$VOLUME:/data:ro" -v /opt/backups:/backup \
  alpine:3.22 tar -C /data -czf "/backup/$VOLUME-prerestore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" .

# 2. Pull the tree out of the snapshot into a scratch directory.
install -d -m 700 /opt/backups/restore
restic restore latest --host platform --tag platform \
  --include "/opt/backups/staging/volumes/$VOLUME" \
  --target /opt/backups/restore

# 3. LOOK AT IT before it replaces anything.
ls -la "/opt/backups/restore/opt/backups/staging/volumes/$VOLUME"

# 4. Swap it in.
docker stop "${VOLUME%-data}" 2>/dev/null || true
docker run --rm \
  -v "$VOLUME:/data" \
  -v "/opt/backups/restore/opt/backups/staging/volumes/$VOLUME:/restored:ro" \
  alpine:3.22 sh -ec 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && cp -a /restored/. /data/'
docker start "${VOLUME%-data}"
```

Step 4's `find … -exec rm -rf` rather than `rm -rf /data/*`: the glob misses
dotfiles, and every one of these volumes has them.

The container names are not always the volume name minus `-data` — check with
`docker ps -a` rather than trusting `${VOLUME%-data}` for `caddy-data`
(container `caddy`) or anything a future stack adds.

### A secret file

```bash
restic restore latest --host platform --tag platform \
  --include /opt/backups/staging/secrets/opt/ci/agent.env \
  --target /opt/backups/restore

diff /opt/backups/restore/opt/backups/staging/secrets/opt/ci/agent.env /opt/ci/agent.env
```

Secrets are staged under their own absolute path, so the restored tree reads as
a map of where each file goes back to.

### A tenant's hand-off file

```bash
restic ls latest --host platform --tag platform | grep '/handoff/'
restic restore latest --host platform --tag platform \
  --include /opt/backups/handoff/ludo --target /opt/backups/restore
```

Hand it back to the tenant. The platform restores the *file*; loading a dump
into a database is the tenant's side of the contract, and the platform has no
business knowing how.

### Browsing without restoring

```bash
restic snapshots --tag platform --host platform
restic ls <snapshot-id> | less
restic diff <older-id> <newer-id>        # what actually changed between nights
```

`restic diff` between two nights is the fastest way to answer "did this backup
capture anything at all," which a size-only check cannot.

## Restore drill

`restic check` verifies that the repository can be *read*. It says nothing about
whether what is in it is usable, and nothing at all about whether the operator
can perform a restore under pressure. The drill is the only thing that does:

```bash
/opt/backups/bin/restore-drill.sh                        # newest snapshot, CI database
/opt/backups/bin/restore-drill.sh --volume grafana-data
/opt/backups/bin/restore-drill.sh --keep                 # leave the scratch copy to poke at
```

It restores into a scratch directory *and* a scratch docker volume — the volume
step is what proves ownership and permissions survive the round trip — finds
SQLite databases by magic bytes rather than filename, and runs
`PRAGMA integrity_check` on each. Nothing it creates is named without the
`restore-drill-` prefix, so it is safe to run on the live box in working hours,
which is the only kind of drill that gets repeated.

**Run it quarterly, and after any change to `backup.sh` or the volume list.**

### Restore drill log

`BACKLOG.md` **P1** is not done until there is a dated row here. An undated
drill is indistinguishable from no drill.

| Date | Volume | Snapshot | Verified | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| — | — | — | — | **never performed** | The stack is committed; nothing has been run on the box |

## When something fails

### `repository is not reachable or not initialised`

Connectivity, credentials, or the password — in that order of likelihood. It is
**not** a missing repository unless this box has genuinely never been set up.

Do not run `restic init` to make the message go away. It creates an empty second
repository at whatever URL is currently configured, every later run succeeds
into it, and the real history sits somewhere else untouched until the day you
need it. The script refuses to auto-init for exactly this reason.

```bash
restic cat config          # the actual error, unwrapped
restic snapshots           # if this works, the repository is fine
```

### `unable to create lock in backend`

A previous run died without releasing its lock — an OOM kill, a reboot, a
`systemctl stop` mid-run.

```bash
systemctl is-active platform-backup.service platform-backup-maintenance.service
restic list locks
restic unlock            # only once you have confirmed nothing is running
```

Confirm nothing is running **first**. `restic unlock` while another process
holds the repository is how two writers meet.

### `check` fails

Take it seriously; this is the alarm the weekly run exists to raise.

```bash
restic check --read-data           # full read, slow, and worth it here
```

Do **not** delete snapshots to make it pass. If damage is confined to specific
packs, `restic repair packs` and `restic repair index` recover what is
recoverable; if the storage backend has lost data, the honest response is a
fresh repository and the knowledge that the old snapshots are gone — which is
information you want *now*, not the morning you need them.

### The nightly run left a container stopped

It should not: the script restarts anything it stopped even when it aborts. If
it somehow did, the journal says `CRITICAL: … is STILL STOPPED`.

```bash
journalctl -u platform-backup.service -n 100 --no-pager
docker start woodpecker-server        # or whichever it names
```

### A tenant is stale

```
WARN: hand-off: tenant 'ludo' newest file is 74h old (threshold 30h)
```

That is the tenant's dump job, not the platform's backup. Tell the tenant. The
platform's own snapshot that night was fine, which is why this is a warning and
not a failure.

## Costs and limits

- **Disk on the box.** The staging tree is a full uncompressed copy of the
  backed-up volumes — roughly **300 MB** at 2026-08 sizes. It is kept between
  runs deliberately: restic scans it far faster when most files are unchanged.
- **Off-site.** Deduplicated and compressed; the first snapshot is the
  expensive one, and later nights are close to the delta. `restic stats
  --mode raw-data` after a few weeks is the real number.
- **RPO: up to ~24 h** for platform state, plus whatever a tenant's own dump
  schedule adds on top of it.
- **This does not alert.** A failed run is queryable in Loki and invisible
  everywhere else. `BACKLOG.md` **P3** (a notification path) and **P4** (metrics
  and alert rules) are what close that, and neither is this stack's job.

## Changing what gets backed up

The volume list is the `TARGETS` array at the top of `backup.sh`, one
`volume:container:stop|live` line each. Adding a stack means adding a line —
and then running the drill, because a backup nobody has restored from is a
claim, not a capability.

Two rules that are not obvious:

- **New volume holding a database → `stop`.** `live` is reserved for the case
  where stopping costs more than a torn file, and `caddy` is the only one on
  this box that qualifies.
- **Never add a tenant's volume here.** A tenant hands over a dump; the platform
  does not reach into tenant containers. An entry like `ludo-postgres-data:…` in
  this list is the tenant boundary inverted, which is the mistake `BACKLOG.md`
  opens by naming.

## Legacy manual archives

`/opt/backups` may hold `*.tar.gz` files from the manual procedures in
`woodpecker/BOOTSTRAP.md` and `uptime-kuma/OPERATIONS.md`. They are **not** in
the snapshots — the run only sweeps `staging/` and `handoff/` — so they sit on
the disk they were meant to protect against, consuming space.

Keep the manual procedures: taking an archive immediately before an upgrade is
still the right move, and it does not depend on the network or the repository
password. Delete the accumulated ones once the first restore drill has passed
and this stack has taken over the nightly job.
