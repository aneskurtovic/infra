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

## Which workflows reach this agent

**Only ones that ask for it.** `start-agent.ps1` sets
`WOODPECKER_AGENT_LABELS='!platform=windows/amd64'`, and the `!` prefix makes
that label mandatory — a workflow reaches this agent only if it declares:

```yaml
labels:
  platform: windows/amd64
```

This matters more than it looks. Woodpecker treats an **unlabelled** workflow as
runnable on *any* agent, so the moment a second agent of a different platform
joins, every existing repo's Linux pipelines become eligible to land on Windows —
where a `services:` block fails with `unsupported step type` and a Linux image
fails with `executable file not found in %PATH%`. Nothing warns you; the
pipelines simply start failing in a way that reads like a broken build.

Constrain the agent rather than labelling every workflow in every repo: the
per-repo approach is one forgotten file away from the same failure, and a newly
added repo is forgotten by default.

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

Registers a Scheduled Task that starts at boot whether or not anyone logs in,
restarts on failure every minute, and has no execution time limit. It stages a
copy of `start-agent.ps1` into `C:\woodpecker\` so the task does not depend on
this git checkout remaining where it is.

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
environment is the build environment**. Three problems follow, each found by
measurement on a real machine:

| Problem | Symptom if unfixed | Fix |
|---|---|---|
| No MSVC environment | Cold `whisper-rs-sys` fails at exit 101: bindgen can't find `stdio.h`, emits degraded bindings, and it surfaces as a struct layout assertion (`12_usize - 16_usize`) far from the cause | Import `vcvars64.bat` |
| `HOME`/`USERPROFILE` redirected to a throwaway `<workspace>\home` | rustup gets a blank profile with no `default_toolchain`. A repo without `rust-toolchain.toml` fails outright; one with it silently re-downloads a whole toolchain **every pipeline** | Pin `RUSTUP_HOME`, `CARGO_HOME` |
| Git Bash on `PATH` | coreutils `link` shadows MSVC `link.exe`; every native build fails at link time | `image: powershell` in the workflow |

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

`C:\woodpecker\agent.conf` holds the server-assigned agent id, so the agent is
stateful across restarts. Its default path is `/etc/woodpecker/agent.conf`, which
cannot exist on Windows; leaving it unset produces a recurring error on every
start.

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
