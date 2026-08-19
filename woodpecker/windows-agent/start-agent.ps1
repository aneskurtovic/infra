<#
.SYNOPSIS
    Launches and supervises the Woodpecker Windows CI agent with a build-capable
    environment.

.DESCRIPTION
    Woodpecker's `local` backend runs every pipeline step as a CHILD of this
    process. There is no container: the agent's own environment IS the build
    environment. Four things must therefore be true of it, and each one below
    was measured on the target machine rather than assumed.

    1. The MSVC environment must be present.
       Without INCLUDE, a cold whisper-rs-sys build fails at exit 101: bindgen
       cannot find stdio.h, emits degraded bindings, and the error surfaces as a
       struct layout assertion ("attempt to compute 12_usize - 16_usize") far
       from the real cause. With vcvars64 imported, the same cold build finishes
       clean in ~42s. Not every repository needs this -- rustc and cc-rs locate
       MSVC through the registry -- but bindgen's libclang does not, and one
       agent serves every repository.

    2. RUSTUP_HOME and CARGO_HOME must point at the real installation.
       The local backend redirects each step's HOME and USERPROFILE to a
       throwaway <workspace>\home. rustup resolves its state from those, so
       without pinning, every step gets a blank profile with no default
       toolchain. A repository with no rust-toolchain.toml then fails outright;
       one that has it quietly re-downloads an entire toolchain per pipeline.

    3. PowerShell, not Git Bash.
       Under Git Bash, coreutils `link` shadows MSVC `link.exe` and every native
       build fails at link time.

    4. This script must wait for the server and restart the agent itself.
       Two measured facts force a supervision loop here rather than leaving the
       job to the agent or to Task Scheduler.

       First, the agent will not wait for the network. Its
       --connect-retry-count / --connect-retry-delay budget only engages when a
       connection is REFUSED (TCP RST). A dial that TIMES OUT -- which is what an
       unready tailnet produces -- bypasses the retry path entirely and goes
       straight to a fatal error. Measured against a blackholed address with
       WOODPECKER_CONNECT_RETRY_COUNT=20 and _DELAY=5s, the agent still died in
       5 seconds with a single "DeadlineExceeded" and no retry at all. Raising
       those knobs does not help; only waiting before launch does.

       Second, Task Scheduler will not restart it. When the launched process
       exits non-zero, the task engine records the code (event 201,
       0x80070001) and then logs event 102, "successfully finished" -- the TASK
       ran to completion, so restart-on-failure never fires. Confirmed across
       three separate boots: exactly one launch each, no retries, and the
       task's RestartCount 999 ignored every time.

       Together those two produced the outage this loop exists to prevent. On the
       8/18 boot: OS up at 09:32:51, task launched at 09:33:06 (T+15s), but
       cold-boot contention meant PowerShell did not reach its transcript until
       09:35:39 -- so the agent's first and only connect attempt happened around
       T+3min and still found no usable path to the server (FTL at 09:36:05).
       It exited 1 and nothing ever started it again. CI stayed silently dead
       for days until someone ran the task by hand.

       Note that T+3min is well past an ordinary Tailscale cold start (10-30s).
       That points at the tunnel not being up pre-logon at all -- i.e. Tailscale
       running without unattended mode, where the tunnel follows the GUI user's
       session. The wait loop below tolerates that (it picks the agent up
       whenever the tunnel appears), but `tailscale up --unattended` is what
       actually makes CI available at boot rather than after a human logs in.

    The local backend discards the workspace between pipelines, so every run is
    a cold build and points 1-3 apply on every run -- not just the first.

.PARAMETER Server
    host:port of the Woodpecker server's gRPC endpoint. On this deployment that
    is a Tailscale address; gRPC is deliberately not published publicly.
    A bare host with no port is corrected to :9000 -- the agent's own default is
    :443, which fails in a way that reads like a firewall problem.

.PARAMETER ConnectWaitMinutes
    How long to wait for the server to become reachable before giving up on a
    cycle. Giving up only restarts the wait; the task instance never exits, so a
    tailnet that arrives late is still picked up.

.NOTES
    The agent secret is never passed as an argument -- arguments are visible to
    any process that can enumerate command lines. It is read from a file whose
    ACL is set by install-agent.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [string]$AgentRoot     = 'C:\woodpecker',
    [string]$AgentHostname = "$($env:COMPUTERNAME.ToLower())-windows-agent",
    [int]   $MaxWorkflows  = 1,
    [string]$RustupHome    = "$env:USERPROFILE\.rustup",
    [string]$CargoHome     = "$env:USERPROFILE\.cargo",
    [int]   $ConnectWaitMinutes  = 15,
    [int]   $RestartDelaySeconds = 30,
    [int]   $MaxLogBytes         = 33554432,
    [switch]$NoTranscript
)

$ErrorActionPreference = 'Stop'

$agentExe   = Join-Path $AgentRoot 'agent\woodpecker-agent.exe'
$secretFile = Join-Path $AgentRoot 'agent-secret.txt'
$configFile = Join-Path $AgentRoot 'agent.conf'
$logDir     = Join-Path $AgentRoot 'logs'

function Write-Stamped([string]$Message) {
    Write-Host "$(Get-Date -Format 'HH:mm:ss') $Message"
}

# --- logging ------------------------------------------------------------------
# A service with no log is a service you cannot debug. Keep the last few runs
# and no more; this is a build agent, not an audit trail.
#
# Because this process now lives for as long as the machine is up, a single
# transcript would grow without bound and the keep-last-10 rotation below would
# never bound anything again. So the transcript is also rolled at cycle
# boundaries once the current file exceeds MaxLogBytes.
$script:transcriptPath = $null

function Start-AgentTranscript {
    if ($NoTranscript) { return }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Get-ChildItem $logDir -Filter 'agent-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $script:transcriptPath = Join-Path $logDir "agent-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Start-Transcript -Path $script:transcriptPath | Out-Null
}

function Update-AgentTranscript {
    if ($NoTranscript -or -not $script:transcriptPath) { return }
    $current = Get-Item -LiteralPath $script:transcriptPath -ErrorAction SilentlyContinue
    if ($current -and $current.Length -ge $MaxLogBytes) {
        Write-Stamped "Transcript reached $([int]($current.Length / 1MB)) MB; rolling to a new file."
        Stop-Transcript | Out-Null
        Start-AgentTranscript
    }
}

# --- reachability -------------------------------------------------------------
# TcpClient rather than Test-NetConnection: the latter emits a warning record on
# every failure (noise in a loop that expects to fail) and offers no short
# connect timeout.

function Test-ServerReachable {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 5000)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# --- server address -----------------------------------------------------------
# The agent's --server default port is :443, so a bare host silently dials the
# wrong port and the resulting "connection refused" names a port nobody
# configured -- which sends you looking at firewalls instead.
#
# IPv6 needs care: in a bare literal (fd7a::1) every colon belongs to the
# address, so a naive ":<digits> at the end" test reads ':1' as a port. Adding a
# port to such an address also requires bracketing it.

function Resolve-ServerAddress {
    param([string]$Address)

    if ($Address -match '^unix://') {
        return [pscustomobject]@{ Server = $Address; HostName = $null; Port = 0 }
    }

    if ($Address.StartsWith('[')) {
        if ($Address -match '^\[(.+)\]:(\d+)$') {
            return [pscustomobject]@{ Server = $Address; HostName = $matches[1]; Port = [int]$matches[2] }
        }
        if ($Address -match '^\[(.+)\]$') {
            Write-Stamped "Server '$Address' has no port; using ${Address}:9000 (the agent would otherwise assume :443)."
            return [pscustomobject]@{ Server = "${Address}:9000"; HostName = $matches[1]; Port = 9000 }
        }
        throw "Cannot parse server address: $Address"
    }

    $colons = ($Address.ToCharArray() | Where-Object { $_ -eq ':' }).Count

    if ($colons -gt 1) {
        $bracketed = "[${Address}]:9000"
        Write-Stamped "Server '$Address' is a bare IPv6 literal with no port; using $bracketed."
        return [pscustomobject]@{ Server = $bracketed; HostName = $Address; Port = 9000 }
    }

    if ($colons -eq 1 -and $Address -match '^(.+):(\d+)$') {
        return [pscustomobject]@{ Server = $Address; HostName = $matches[1]; Port = [int]$matches[2] }
    }

    Write-Stamped "Server '$Address' has no port; using ${Address}:9000 (the agent would otherwise assume :443)."
    return [pscustomobject]@{ Server = "${Address}:9000"; HostName = $Address; Port = 9000 }
}

# --- orphaned agents ----------------------------------------------------------
# Stop-ScheduledTask ends the launcher but NOT the agent the launcher started:
# the agent is a grandchild of the task's process and survives as an orphan,
# keeping its gRPC session and its server-assigned agent id. Starting the task
# again then leaves TWO agents sharing one id, both eligible to claim work.
# Measured on this deployment after a single Stop/Start cycle: two
# woodpecker-agent.exe processes, both with established connections to :9000.
#
# It also breaks the documented upgrade flow, where the orphan keeps
# woodpecker-agent.exe locked while install-agent.ps1 tries to replace it.
#
# Only genuine orphans are killed. An agent with a live parent belongs to another
# launcher -- MultipleInstances IgnoreNew should have prevented that, so report
# it rather than fight over it.

function Stop-OrphanedAgents {
    $agents = @(Get-CimInstance Win32_Process -Filter "Name = 'woodpecker-agent.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $agents) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.ParentProcessId)" -ErrorAction SilentlyContinue
        if ($parent) {
            Write-Stamped "WARNING: agent PID $($proc.ProcessId) already runs under $($parent.Name) (PID $($proc.ParentProcessId)); leaving it alone."
            continue
        }
        Write-Stamped "Orphaned agent PID $($proc.ProcessId) found (parent gone); terminating so two agents cannot share one agent id."
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Stamped "Terminated orphaned agent PID $($proc.ProcessId)."
        } catch {
            # A session that cannot signal the orphan is worse than useless
            # silently: say exactly what to run. Starting anyway is still the
            # better failure -- a duplicate agent beats no CI at all.
            Write-Stamped "WARNING: could not terminate orphaned agent PID $($proc.ProcessId): $($_.Exception.Message)"
            Write-Stamped "         From an ELEVATED PowerShell: Stop-Process -Id $($proc.ProcessId) -Force"
        }
    }
}

function Wait-ForServer {
    param([string]$HostName, [int]$Port, [int]$WaitMinutes)
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    $attempt  = 0
    while ($true) {
        $attempt++
        if (Test-ServerReachable -HostName $HostName -Port $Port) {
            Write-Stamped "${HostName}:${Port} is reachable (attempt $attempt)."
            return $true
        }
        if ((Get-Date) -gt $deadline) {
            Write-Stamped "${HostName}:${Port} still unreachable after $WaitMinutes min / $attempt attempts."
            return $false
        }
        # Every 6th attempt is roughly every 30s of waiting -- enough to show
        # progress in the transcript without burying the interesting lines.
        if ($attempt -eq 1 -or $attempt % 6 -eq 0) {
            Write-Stamped "Waiting for ${HostName}:${Port} (attempt $attempt) ..."
        }
        Start-Sleep -Seconds 5
    }
}

Start-AgentTranscript

try {
    # --- normalise the server address -----------------------------------------
    $resolved  = Resolve-ServerAddress -Address $Server
    $Server    = $resolved.Server
    $probeHost = $resolved.HostName
    $probePort = $resolved.Port

    # --- preflight ------------------------------------------------------------
    # Fail here with a sentence, rather than deep inside somebody's pipeline
    # with a const-eval overflow. Done once rather than per cycle: none of it
    # changes while the machine is up, and it is the slow part of startup.

    if (-not (Test-Path $agentExe))   { throw "Agent binary missing: $agentExe. Run install-agent.ps1 first." }
    if (-not (Test-Path $secretFile)) { throw "Secret file missing: $secretFile. Run install-agent.ps1 first." }
    if (-not (Test-Path $RustupHome)) { throw "RUSTUP_HOME does not exist: $RustupHome" }
    if (-not (Test-Path $CargoHome))  { throw "CARGO_HOME does not exist: $CargoHome" }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found. Install Visual Studio Build Tools." }

    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $vsPath) { throw 'No Visual Studio installation with the MSVC x64 toolset was found.' }

    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vsPath" }

    # --- import the MSVC environment ------------------------------------------
    # A .bat cannot be sourced into PowerShell: it mutates the environment of
    # the cmd.exe that runs it, and that cmd.exe then exits. So run it, dump the
    # resulting environment, and copy it into this process -- which every step
    # inherits.
    Write-Host "Importing MSVC environment from $vcvars"
    cmd /c "`"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') {
            Set-Item -Path "env:$($matches[1])" -Value $matches[2] -ErrorAction SilentlyContinue
        }
    }

    if (-not $env:INCLUDE) { throw 'INCLUDE is empty after importing vcvars64 -- refusing to start.' }
    if (-not $env:LIB)     { throw 'LIB is empty after importing vcvars64 -- refusing to start.' }

    # bindgen needs libclang; the toolchain preflight in some repositories also
    # requires CLANG_PATH to name the clang.exe beside it.
    if (-not $env:LIBCLANG_PATH) { throw 'LIBCLANG_PATH is unset (needed by whisper-rs bindgen).' }
    if (-not $env:CLANG_PATH) {
        $candidate = Join-Path $env:LIBCLANG_PATH 'clang.exe'
        if (Test-Path $candidate) {
            $env:CLANG_PATH = $candidate
            Write-Host "CLANG_PATH was unset; derived $candidate"
        } else {
            throw "CLANG_PATH is unset and no clang.exe sits beside LIBCLANG_PATH ($env:LIBCLANG_PATH)."
        }
    }

    # --- tool homes -----------------------------------------------------------
    $env:RUSTUP_HOME = $RustupHome
    $env:CARGO_HOME  = $CargoHome

    # --- agent configuration --------------------------------------------------
    $env:WOODPECKER_SERVER       = $Server
    $env:WOODPECKER_AGENT_SECRET = (Get-Content -LiteralPath $secretFile -Raw).Trim()
    if (-not $env:WOODPECKER_AGENT_SECRET) { throw "Secret file is empty: $secretFile" }

    # WireGuard already encrypts the hop and the server serves plaintext gRPC on
    # its tailnet address. TLS here would need a certificate for an address that
    # is only reachable inside the tailnet.
    $env:WOODPECKER_GRPC_SECURE   = 'false'
    $env:WOODPECKER_BACKEND       = 'local'

    # Deliberately NO WOODPECKER_AGENT_LABELS here. Agent labels cannot restrict
    # what this agent accepts: the filter runs one way only — "an agent must be
    # assigned every tag listed in a task" — so a task with no labels is a subset
    # of every agent and matches all of them. Setting a label here (including the
    # `!mandatory` form, which 3.16.0 stores verbatim as a custom label named
    # `!platform` and never evaluates) changes nothing and reads as protection
    # that does not exist. Routing is a WORKFLOW-side responsibility; see README.
    $env:WOODPECKER_MAX_WORKFLOWS = "$MaxWorkflows"
    $env:WOODPECKER_HOSTNAME      = $AgentHostname
    # Defaults to /etc/woodpecker/agent.conf, which cannot exist on Windows.
    # Holds the server-assigned agent id so the agent is stateful across restarts.
    $env:WOODPECKER_AGENT_CONFIG_FILE = $configFile

    # Retry a LOST connection forever instead of giving up after the default 2m.
    # This is a different code path from the initial connect, which ignores its
    # own retry settings on a timeout (see point 4 above). Without this, any
    # tailnet blip longer than two minutes ends the agent -- and since Task
    # Scheduler will not restart a non-zero exit, that ends CI until a human
    # notices.
    $env:WOODPECKER_RETRY_TIMEOUT = '0'

    Write-Host "INCLUDE entries : $((($env:INCLUDE -split ';') | Where-Object { $_ }).Count)"
    Write-Host "LIBCLANG_PATH   : $env:LIBCLANG_PATH"
    Write-Host "RUSTUP_HOME     : $env:RUSTUP_HOME"
    Write-Host "Server          : $Server (backend=local, max_workflows=$MaxWorkflows)"

    # --- supervise ------------------------------------------------------------
    # Never returns. Task Scheduler owns this process's lifetime: the task is
    # registered with ExecutionTimeLimit 0 and MultipleInstances IgnoreNew, so
    # exactly one instance runs until the machine goes down.
    while ($true) {
        if ($probeHost -and -not (Wait-ForServer -HostName $probeHost -Port $probePort -WaitMinutes $ConnectWaitMinutes)) {
            # Deliberately not fatal. The likeliest cause at boot is a tailnet
            # that has not come up yet, and exiting here would reproduce the
            # original outage exactly. A full wait window has already elapsed,
            # so this cannot spin.
            Write-Stamped 'Giving up on this cycle and waiting again rather than exiting.'
            Update-AgentTranscript
            continue
        }

        Stop-OrphanedAgents

        Write-Stamped "Starting agent -> $Server"
        & $agentExe
        $exit = $LASTEXITCODE

        Write-Stamped "Agent exited with code $exit; restarting in ${RestartDelaySeconds}s."
        Start-Sleep -Seconds $RestartDelaySeconds
        Update-AgentTranscript
    }
}
finally {
    if (-not $NoTranscript) { Stop-Transcript | Out-Null }
}
