<#
.SYNOPSIS
    Installs (or upgrades) the Woodpecker Windows agent binary and its secret.

.DESCRIPTION
    Downloads the pinned agent release, verifies it against the release
    checksums file, extracts it, and stores the agent token in a file readable
    only by the installing user and SYSTEM.

    Idempotent: safe to re-run to upgrade the binary. Re-running does not
    overwrite an existing secret unless -ResetSecret is passed.

    Server and agent MUST be the same version. Woodpecker pins both and upgrades
    them together; a mismatched agent is not a supported configuration.

.EXAMPLE
    .\install-agent.ps1 -Version 3.16.0

.NOTES
    The token is prompted for, never taken as a parameter -- a parameter would
    land in the PowerShell history file and in any transcript of the session.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$AgentRoot = 'C:\woodpecker',
    [switch]$ResetSecret
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0

$agentDir   = Join-Path $AgentRoot 'agent'
$secretFile = Join-Path $AgentRoot 'agent-secret.txt'
$zipPath    = Join-Path $AgentRoot "woodpecker-agent_windows_amd64-$Version.zip"
$sumPath    = Join-Path $AgentRoot "checksums-$Version.txt"
$base       = "https://github.com/woodpecker-ci/woodpecker/releases/download/v$Version"

New-Item -ItemType Directory -Force -Path $AgentRoot, $agentDir | Out-Null

# --- download -----------------------------------------------------------------

Write-Host "Downloading woodpecker-agent v$Version"
Invoke-WebRequest -Uri "$base/woodpecker-agent_windows_amd64.zip" -OutFile $zipPath -UseBasicParsing
Invoke-WebRequest -Uri "$base/checksums.txt" -OutFile $sumPath -UseBasicParsing

# --- verify -------------------------------------------------------------------
#
# The agent runs pipeline steps directly on this host with no container. A
# tampered binary here is a full host compromise, so the checksum is a gate,
# not a formality.

$actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
$line   = Select-String -Path $sumPath -Pattern 'woodpecker-agent_windows_amd64\.zip' | Select-Object -First 1
if (-not $line) { throw "No checksum entry for the Windows agent in $sumPath" }
$expected = (($line.Line -split '\s+')[0]).ToLower()

if ($expected -ne $actual) {
    throw "CHECKSUM MISMATCH`n  expected $expected`n  actual   $actual`nRefusing to install."
}
Write-Host "Checksum OK ($actual)"

# --- extract ------------------------------------------------------------------

Expand-Archive -Path $zipPath -DestinationPath $agentDir -Force
$reported = & (Join-Path $agentDir 'woodpecker-agent.exe') --version
Write-Host "Installed: $reported"
if ($reported -notmatch [regex]::Escape($Version)) {
    throw "Binary reports '$reported' but $Version was requested."
}

# --- secret -------------------------------------------------------------------

if ((Test-Path $secretFile) -and -not $ResetSecret) {
    Write-Host "Secret file already present; leaving it alone (pass -ResetSecret to replace)."
} else {
    Write-Host ''
    Write-Host 'Create the agent in the Woodpecker UI (Admin -> Agents) and paste its token.'
    Write-Host 'It is not echoed.'
    $secure = Read-Host -AsSecureString 'Agent token'
    $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    if (-not $plain) { throw 'No token entered.' }

    # -NoNewline: a trailing newline is tolerated by the launcher's .Trim(), but
    # writing the file exactly as intended avoids relying on that.
    Set-Content -LiteralPath $secretFile -Value $plain -NoNewline -Encoding ascii
}

# --- lock down the secret -----------------------------------------------------
# Break inheritance and grant only the installing user and SYSTEM. Without
# SetAccessRuleProtection the file silently keeps whatever the parent grants,
# which on a default profile includes Administrators.

$me  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('SYSTEM', 'FullControl', 'Allow')))
$acl.SetOwner((New-Object Security.Principal.NTAccount($me)))
Set-Acl -LiteralPath $secretFile -AclObject $acl

Write-Host ''
Write-Host 'Secret file ACL:'
(Get-Acl $secretFile).Access |
    Select-Object IdentityReference, FileSystemRights, AccessControlType |
    Format-Table -AutoSize

Write-Host "Done. Next: install-service.ps1 -Server <tailnet-ip:9000>"
