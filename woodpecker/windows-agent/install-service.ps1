<#
.SYNOPSIS
    Registers the Woodpecker Windows agent as an auto-starting Scheduled Task.

.DESCRIPTION
    Creates a task that starts the agent at boot, before and independently of
    any interactive logon, and restarts it if it dies.

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

    Windows stores the supplied password in Credential Manager under the task.
    Registering a "logged on or not" task requires the "Log on as batch job"
    right, which local administrators hold -- hence the elevation check.

.EXAMPLE
    .\install-service.ps1 -Server 100.120.41.12:9000

.EXAMPLE
    .\install-service.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$AgentRoot = 'C:\woodpecker',
    [string]$TaskName  = 'WoodpeckerAgent',
    [string]$User      = "$env:USERDOMAIN\$env:USERNAME",
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

Write-Host ''
Write-Host "The task runs as $User and must start without an interactive logon,"
Write-Host 'so Windows needs that account password to store in Credential Manager.'
$password = Read-Host -AsSecureString "Password for $User"
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
           [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
if (-not $plain) { throw 'No password entered.' }

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Replaced existing task '$TaskName'."
}

Register-ScheduledTask `
    -TaskName    $TaskName `
    -Action      $action `
    -Trigger     $trigger `
    -Settings    $settings `
    -User        $User `
    -Password    $plain `
    -RunLevel    Limited `
    -Description 'Woodpecker CI agent (local backend). Managed by infra/woodpecker/windows-agent.' | Out-Null

Write-Host "Registered '$TaskName'."

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
