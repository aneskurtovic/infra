# Woodpecker Windows agent

The Docker agent in [`../docker-compose.yml`](../docker-compose.yml) cannot build
Windows software. This directory sets up a second agent, on a Windows machine,
using Woodpecker's `local` backend.

Server-side prerequisites (Tailscale, publishing gRPC on the tailnet address)
are in [`../BOOTSTRAP.md`](../BOOTSTRAP.md) §7. Do that first — an agent cannot
register until `:9000` is reachable.

## Trust boundary — read before installing

The `local` backend runs each pipeline step **directly on the host**: same user,
same filesystem, no container. Anything a `.woodpecker` file can express, it can
do to this machine.

That is only acceptable when every repository the agent serves is trusted and no
untrusted fork can trigger it. It is why:

- the agent runs as an **ordinary user account**, never LocalSystem;
- release pipelines that handle signing material stay on hosted CI;
- the agent binary is **checksum-verified** before it is ever run.

## Adding this agent breaks every unlabelled workflow on the server

**Do this before you unpause it, not after.** Every workflow that should keep
running on Linux must say so explicitly:

```yaml
labels:
  platform: linux/amd64

steps:
  [...]
```

Woodpecker's scheduler matches one way only — *an agent must carry every label a
task lists* — so a task with **no** labels is a subset of every agent and is
eligible for all of them. Adding a second platform to the pool therefore makes
every existing repo's Linux pipelines eligible to land on Windows, where a
`services:` block fails with `unsupported step type` and a Linux image fails with
`executable file not found in %PATH%`. The pipelines read as broken builds —
nothing points at agent selection.

There is **no agent-side fix**. Because the filter only ever narrows what a
*labelled* task matches, no value of `WOODPECKER_AGENT_LABELS` lets this agent
refuse unlabelled work. The `!mandatory` prefix in the upstream docs does not
help either: 3.16.0 stores `!platform=windows/amd64` verbatim as a custom label
named `!platform` and never evaluates it — verified on this deployment on
2026-08-10, after it silently failed a production deploy.

So the checklist when onboarding this agent is: label every existing Linux
workflow first, confirm a pipeline still routes to the Linux agent, and only then
unpause. Windows-targeted workflows need `platform: windows/amd64`, which matches
this agent's default platform label with no extra configuration.

## Install

Three steps. Only the second needs elevation.

### 1. Create the agent record

In the Woodpecker UI: **Admin → Agents → Add agent**. Name it after the machine.
Copy the token; it is shown once.

### 2. Install the binary and store the token

```powershell
.\install-agent.ps1 -Version 3.16.0
```

Downloads the release, verifies it against the published `checksums.txt`,
extracts it, and prompts for the token (not echoed, never a parameter — a
parameter would land in PowerShell history). The token file's ACL is reduced to
the installing user and SYSTEM, with inheritance broken.

**Keep the agent version equal to the server version.** Woodpecker pins both and
upgrades them together.

### 3. Register the auto-start task

From an **elevated** PowerShell:

```powershell
.\install-service.ps1 -Server 100.120.41.12:9000
```

Registers a Scheduled Task that starts at boot whether or not anyone logs in and
has no execution time limit. It stages a copy of `start-agent.ps1` into
`C:\woodpecker\` so the task does not depend on this git checkout remaining where
it is.

The task's `RestartCount`/`RestartInterval` are **not** what keeps the agent
alive — see [When the agent dies, nothing restarts
it](#when-the-agent-dies-nothing-restarts-it). `start-agent.ps1` supervises the
agent itself.

By default the task uses an **S4U logon**: Windows issues an identity token for
the account without authenticating a password, so nothing is stored anywhere and
the task still starts at boot with no interactive logon. This is also the only
option that works on a machine signed into with a Windows Hello PIN, where there
may be no usable account password at all.

S4U's one limitation is that the token carries **no network credentials**. The
agent needs local disk, local toolchains, and *outbound* TCP (gRPC to the
server, HTTPS to the forge) — none of which authenticate as this user. If a
pipeline ever needs an SMB share or another resource authenticating as this
account over the network, re-register with `-WithPassword`, which stores the
password in Credential Manager instead.

To remove: `.\install-service.ps1 -Remove`.

## What `start-agent.ps1` fixes, and why it is not a list of `$env:` lines

The local backend runs steps as children of the agent, so **the agent's
environment is the build environment**. Four problems follow, each found by
measurement on a real machine:

| Problem | Symptom if unfixed | Fix |
|---|---|---|
| No MSVC environment | Cold `whisper-rs-sys` fails at exit 101: bindgen can't find `stdio.h`, emits degraded bindings, and it surfaces as a struct layout assertion (`12_usize - 16_usize`) far from the cause | Import `vcvars64.bat` |
| `HOME`/`USERPROFILE` redirected to a throwaway `<workspace>\home` | rustup gets a blank profile with no `default_toolchain`. A repo without `rust-toolchain.toml` fails outright; one with it silently re-downloads a whole toolchain **every pipeline** | Pin `RUSTUP_HOME`, `CARGO_HOME` |
| Git Bash on `PATH` | coreutils `link` shadows MSVC `link.exe`; every native build fails at link time | `image: powershell` in the workflow |
| Agent starts before the tailnet is usable, then nothing restarts it | Agent exits 1 seconds into boot and **stays dead until a human notices** | Poll `:9000` until reachable, then supervise the agent in a loop |

The launcher refuses to start if any of these is unsatisfied. That is the point:
a preflight failure is one sentence, and the failure it replaces is a const-eval
overflow inside a dependency.

The workspace is discarded between pipelines, so **every run is a cold build**
and all of the above applies every time — not only on first use.

## Workflows must declare their labels

An **absent** `labels:` stanza is a wildcard, not a default. Woodpecker will
schedule such a workflow onto any agent with capacity — including this one.

With a single agent that is invisible. The moment this agent registers, every
unlabelled Linux workflow becomes a coin flip, and half of them will try to run
`apt`-flavoured steps on Windows. Note that `image:` does not save you: on the
`local` backend `image:` names a **shell**, not a container.

Each repository must therefore say what it needs:

```yaml
labels: { platform: linux/amd64, backend: docker }    # Linux workflows
labels: { platform: windows/amd64, backend: local }   # Windows workflows
```

That is a per-repository concern and lives in each repository's `.woodpecker/`.

## Operating it

```powershell
Get-ScheduledTask     -TaskName WoodpeckerAgent
Get-ScheduledTaskInfo -TaskName WoodpeckerAgent    # 0x41301 = running
Stop-ScheduledTask    -TaskName WoodpeckerAgent
Start-ScheduledTask   -TaskName WoodpeckerAgent
Get-ChildItem C:\woodpecker\logs | Sort LastWriteTime -Desc | Select -First 1 | Get-Content -Tail 40
```

The last ten run transcripts are kept in `C:\woodpecker\logs`.

### `Stop-ScheduledTask` does not stop the agent

It ends the launcher, but the agent is a **grandchild** of the task's process and
survives as an orphan — still connected, still holding its agent id. Start the
task again and two agents share one id, both eligible to claim work. Measured
here after one Stop/Start cycle: two `woodpecker-agent.exe` processes with
established connections to `:9000`.

`start-agent.ps1` now kills orphans before launching, so a Stop/Start cycle
self-corrects. To check by hand:

```powershell
Get-CimInstance Win32_Process -Filter "Name = 'woodpecker-agent.exe'" |
  Select-Object ProcessId, ParentProcessId, CreationDate
```

More than one row means a duplicate. Killing it needs a shell **in the same
logon session or elevated** — the task's S4U token puts the agent out of reach of
an ordinary interactive session, which fails with `Access is denied`:

```powershell
Stop-Process -Id <pid> -Force        # from an elevated PowerShell
```

This also matters when upgrading: an orphan keeps `woodpecker-agent.exe` locked
while `install-agent.ps1` tries to replace it.

`C:\woodpecker\agent.conf` holds the server-assigned agent id, so the agent is
stateful across restarts. Its default path is `/etc/woodpecker/agent.conf`, which
cannot exist on Windows; leaving it unset produces a recurring error on every
start.

## When the agent dies, nothing restarts it

This cost several days of dead Windows CI once. Both of the mechanisms that look
like they cover it do not:

**The agent does not wait for the network.** `--connect-retry-count` /
`--connect-retry-delay` only engage when the connection is *refused* (TCP RST).
A dial that **times out** — which is exactly what an unready tailnet produces —
skips the retry path and goes straight to a fatal error. Measured against a
blackholed address with `WOODPECKER_CONNECT_RETRY_COUNT=20` and `_DELAY=5s`, the
agent still died in 5 seconds with one `DeadlineExceeded` and no retry. Raising
those knobs does nothing; only waiting before launch does.

**Task Scheduler does not restart a non-zero exit.** It applies
`RestartCount`/`RestartInterval` when it cannot launch the action or ends it
itself — not when the process exits non-zero. Then it records the exit code in
event 201 and logs event 102, *"successfully finished"*, because the task did run
to completion. Confirmed across three boots: one launch each, no retries.

Together those produced a silent outage. On the boot that caused it: OS up at
09:32:51, task launched 09:33:06 (T+15s), but cold-boot contention delayed
PowerShell so the agent's first and only connect attempt landed around **T+3min**
— and still found no usable path to the server (fatal at 09:36:05). It exited 1
and nothing started it again.

T+3min is well past an ordinary Tailscale cold start (10–30s), which is the
strongest evidence that the tunnel was not up *pre-logon at all* — see
[unattended mode](#tailscale-must-survive-a-logout) below.

`start-agent.ps1` therefore polls the server's `:9000` until it answers before
launching the agent, and relaunches the agent whenever it exits. It also sets
`WOODPECKER_RETRY_TIMEOUT=0` so a *lost* connection retries forever instead of
giving up after the default 2 minutes.

### Diagnosing it

```powershell
# "Ready" + a non-zero last result = dead, not idle. 0x41301 = healthy.
Get-ScheduledTaskInfo -TaskName WoodpeckerAgent

# Authoritative launch history — look for one launch per boot and no retries.
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational'} |
  Where-Object { $_.Message -match 'WoodpeckerAgent' } |
  Select-Object -First 20 TimeCreated, Id

# Is the server actually reachable from this machine right now?
Test-NetConnection 100.120.41.12 -Port 9000
```

A healthy agent holds established connections to the server and answers its own
healthcheck:

```powershell
Get-NetTCPConnection -RemoteAddress 100.120.41.12 -RemotePort 9000
Invoke-WebRequest http://127.0.0.1:3000/healthz -UseBasicParsing
```

### Tailscale must survive a logout

By default Tailscale on Windows is **not** in unattended mode: the tunnel follows
the GUI user's session. A machine sitting at the login screen after a reboot
therefore has no tailnet, so the agent cannot reach `:9000` and waits — CI comes
up when a human logs in, not at boot.

```powershell
& 'C:\Program Files\Tailscale\tailscale.exe' up --unattended
```

The trade-off is exactly what it says: the machine stays joined to the tailnet
while nobody is logged in. On a dedicated build box that is the point. On a
personal desktop it is a posture decision worth making deliberately.

Without it the agent still self-heals — the wait loop picks it up whenever the
tunnel appears — so this is the difference between *"CI is up at boot"* and *"CI
is up once I log in"*, not between working and broken.

## Upgrading

Server and agent move together.

```powershell
Stop-ScheduledTask -TaskName WoodpeckerAgent
.\install-agent.ps1 -Version <new-version>      # re-run is safe; keeps the token
.\install-service.ps1 -Server <host:port>       # re-stages the launcher
```

## What this does not do

- **No isolation between pipelines.** Sequential, same user, same disk.
  `WOODPECKER_MAX_WORKFLOWS=1` means one at a time, which is a scheduling
  property, not a security one.
- **No toolchain provisioning.** The agent inherits whatever the machine has:
  Rust (MSVC), Visual Studio Build Tools, LLVM with `LIBCLANG_PATH`, Node. It
  checks for them and refuses to start if they are missing, but installs
  nothing.
- **No secret isolation.** A repository enabled on this instance can read
  anything the agent's user can read.
