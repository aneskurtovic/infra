<#
.SYNOPSIS
    Registers the Woodpecker Windows agent as an auto-starting Scheduled Task.

.DESCRIPTION
    Creates a task that starts the agent at boot, before and independently of
    any interactive logon.

    Keeping the agent alive is start-agent.ps1's job, not this task's. Task
    Scheduler does not restart an action that exits non-zero (see the settings
    block below), so the launcher waits for the server and supervises the agent
    in a loop instead.

    Why a Scheduled Task rather than a Windows service:
    the agent is a console application. Making it a true service needs a
    third-party wrapper (NSSM, WinSW) -- another unsigned binary running at
    boot on a host that already runs CI without isolation. A Scheduled Task is
    built in, supports "run whether user is logged on or not", restart-on-fail,
    and boot triggers, and is auditable with one Get-ScheduledTask call.

    The task runs as a NAMED USER, not LocalSystem, and this is deliberate. The
    local backend executes pipeline steps as the agent's account; under
    LocalSystem, anything in a .woodpecker file would run with full machine
    privileges. Running as the ordinary desktop user keeps CI at the same
    privilege level as the person who would otherwise run these builds by hand.

    By default the task uses an S4U (Service-for-User) logon: Windows issues an
    identity token for the account without authenticating a password, so the
    task starts at boot with no interactive logon and NO CREDENTIAL STORED
    ANYWHERE. This is also the only option that works cleanly on a machine
    signed into with a Windows Hello PIN, where the user may not know or have a
    usable account password.

    The cost of S4U is that the token carries no network credentials: the task
    cannot reach SMB shares or anything authenticating as this user over the
    network. A build agent needs local disk, local toolchains and OUTBOUND TCP
    (gRPC to the server, HTTPS to the forge), none of which use that identity.

    -WithPassword switches to a classic password logon instead, which does grant
    network credentials. Windows stores the password in Credential Manager.

    Either way, registration needs the "Log on as batch job" right, which local
    administrators hold -- hence the elevation check.

.EXAMPLE
    .\install-service.ps1 -Server 100.120.41.12:9000

.EXAMPLE
    .\install-service.ps1 -Server 100.120.41.12:9000 -WithPassword

.EXAMPLE
    .\install-service.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$AgentRoot = 'C:\woodpecker',
    [string]$TaskName  = 'WoodpeckerAgent',
    [string]$User      = "$env:USERDOMAIN\$env:USERNAME",
    [switch]$WithPassword,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (Run as administrator).' }

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    } else {
        Write-Host "No scheduled task named '$TaskName'."
    }
    return
}

if (-not $Server) { throw 'Provide -Server <host:port>, e.g. 100.120.41.12:9000' }

# --- stage the launcher next to the runtime -----------------------------------
# Copied rather than referenced in place: a task pointing into a git checkout
# breaks the moment the checkout is moved, renamed, or on a branch that does not
# contain the file.

$sourceLauncher = Join-Path $PSScriptRoot 'start-agent.ps1'
$targetLauncher = Join-Path $AgentRoot 'start-agent.ps1'
if (-not (Test-Path $sourceLauncher)) { throw "Launcher not found: $sourceLauncher" }
New-Item -ItemType Directory -Force -Path $AgentRoot | Out-Null
Copy-Item -LiteralPath $sourceLauncher -Destination $targetLauncher -Force
Write-Host "Staged launcher at $targetLauncher"

if (-not (Test-Path (Join-Path $AgentRoot 'agent\woodpecker-agent.exe'))) {
    throw "Agent binary missing under $AgentRoot. Run install-agent.ps1 first."
}
if (-not (Test-Path (Join-Path $AgentRoot 'agent-secret.txt'))) {
    throw "Agent secret missing under $AgentRoot. Run install-agent.ps1 first."
}

# --- task definition ----------------------------------------------------------

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    "-File `"$targetLauncher`" -Server $Server"
)

$trigger = New-ScheduledTaskTrigger -AtStartup

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew

# ExecutionTimeLimit 0 = run indefinitely. The default is 3 days, after which
# Windows would kill a perfectly healthy agent and leave no obvious trace.
# MultipleInstances IgnoreNew stops a restart from racing a running agent.
#
# RestartCount/RestartInterval are NOT what keeps the agent alive, despite how
# they read. Task Scheduler applies them when it cannot launch the action or
# ends it itself -- NOT when the launched process exits non-zero. In that case
# the engine records the exit code (event 201) and then logs event 102,
# "successfully finished", because the task did run to completion. Measured on
# this deployment across three boots: the agent exited 1 within seconds each
# time and was never restarted, leaving CI dead for days.
#
# Staying alive is therefore start-agent.ps1's job -- it waits for the server to
# be reachable before launching the agent and relaunches it whenever it exits.
# These two settings are kept only for the launch-failure case they do cover.

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Replaced existing task '$TaskName'."
}

$description = 'Woodpecker CI agent (local backend). Managed by infra/woodpecker/windows-agent.'

if ($WithPassword) {
    Write-Host ''
    Write-Host "The task runs as $User without an interactive logon, so Windows needs"
    Write-Host 'that account password to store in Credential Manager.'
    $secure = Read-Host -AsSecureString "Password for $User"
    $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    if (-not $plain) { throw 'No password entered.' }

    Register-ScheduledTask `
        -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -User $User -Password $plain -RunLevel Limited -Description $description | Out-Null

    Write-Host "Registered '$TaskName' with a stored password logon."
} else {
    # S4U: an identity token for $User with no password authentication, so the
    # task runs at boot with nothing stored. Required on a machine signed into
    # with a Windows Hello PIN, where there may be no usable account password.
    # Trade-off: no network credentials -- fine for local builds and outbound
    # connections, not for SMB or anything authenticating as this user remotely.
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description $description | Out-Null

    Write-Host "Registered '$TaskName' with an S4U logon (no password stored)."
}

# --- verify -------------------------------------------------------------------

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5
$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName

Write-Host ''
Write-Host "State          : $($task.State)"
Write-Host "Last run       : $($info.LastRunTime)"
Write-Host "Last result    : 0x$('{0:X}' -f $info.LastTaskResult)  (0x41301 = still running, which is what you want)"
Write-Host "Logs           : $AgentRoot\logs"
Write-Host ''
Write-Host 'Confirm the agent shows a recent last-contact time in Admin -> Agents.'
