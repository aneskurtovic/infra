<#
.SYNOPSIS
    Launches the Woodpecker Windows CI agent with a build-capable environment.

.DESCRIPTION
    Woodpecker's `local` backend runs every pipeline step as a CHILD of this
    process. There is no container: the agent's own environment IS the build
    environment. Three things must therefore be true of it, and each one below
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

    The local backend discards the workspace between pipelines, so every run is
    a cold build and all of the above applies on every run -- not just the first.

.PARAMETER Server
    host:port of the Woodpecker server's gRPC endpoint. On this deployment that
    is a Tailscale address; gRPC is deliberately not published publicly.

.NOTES
    The agent secret is never passed as an argument -- arguments are visible to
    any process that can enumerate command lines. It is read from a file whose
    ACL is set by install-agent.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [string]$AgentRoot    = 'C:\woodpecker',
    [string]$AgentHostname = "$($env:COMPUTERNAME.ToLower())-windows-agent",
    [int]   $MaxWorkflows = 1,
    [string]$RustupHome   = "$env:USERPROFILE\.rustup",
    [string]$CargoHome    = "$env:USERPROFILE\.cargo",
    [switch]$NoTranscript
)

$ErrorActionPreference = 'Stop'

$agentExe   = Join-Path $AgentRoot 'agent\woodpecker-agent.exe'
$secretFile = Join-Path $AgentRoot 'agent-secret.txt'
$configFile = Join-Path $AgentRoot 'agent.conf'
$logDir     = Join-Path $AgentRoot 'logs'

# --- logging ------------------------------------------------------------------
# A service with no log is a service you cannot debug. Keep the last few runs
# and no more; this is a build agent, not an audit trail.
if (-not $NoTranscript) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    Get-ChildItem $logDir -Filter 'agent-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Start-Transcript -Path (Join-Path $logDir "agent-$(Get-Date -Format 'yyyyMMdd-HHmmss').log") | Out-Null
}

try {
    # --- preflight ------------------------------------------------------------
    # Fail here with a sentence, rather than deep inside somebody's pipeline
    # with a const-eval overflow.

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

    Write-Host "INCLUDE entries : $((($env:INCLUDE -split ';') | Where-Object { $_ }).Count)"
    Write-Host "LIBCLANG_PATH   : $env:LIBCLANG_PATH"
    Write-Host "RUSTUP_HOME     : $env:RUSTUP_HOME"
    Write-Host "Starting agent  -> $Server (backend=local, max_workflows=$MaxWorkflows)"

    & $agentExe
    $exit = $LASTEXITCODE
    Write-Host "Agent exited with code $exit"
    exit $exit
}
finally {
    if (-not $NoTranscript) { Stop-Transcript | Out-Null }
}
