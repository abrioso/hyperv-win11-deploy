<#
.SYNOPSIS
    Collects the Autopilot hardware hash from a running lab VM and (optionally) registers it in Intune.

.DESCRIPTION
    Run from the Hyper-V host. Uses PowerShell Direct (no network needed, just credentials of a local
    admin inside the guest) to run Get-WindowsAutopilotInfo inside the VM, pull the hash back to the
    host, and optionally POST it to the Graph API for Autopilot enrollment.

    Requires: guest at OOBE or logged-in desktop; host has Microsoft.Graph.Intune or Graph scopes
    DeviceManagementServiceConfig.ReadWrite.All.

.PARAMETER VMName
    Target VM name on this Hyper-V host.

.PARAMETER GuestCredential
    Local admin credential inside the guest.

.PARAMETER OutputFile
    Where to save the CSV hash. Default: .\AutopilotHashes\<VMName>.csv

.PARAMETER RegisterOnline
    Also register the device in Autopilot via Microsoft Graph (prompts for consent first time).

.EXAMPLE
    $cred = Get-Credential
    .\Get-AutopilotHash.ps1 -VMName LAB-INTUNE-01 -GuestCredential $cred -RegisterOnline

.REFERENCES
    https://learn.microsoft.com/autopilot/add-devices
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(Mandatory)]
    [pscredential]$GuestCredential,

    [string]$OutputFile = (Join-Path (Join-Path $PSScriptRoot 'AutopilotHashes') "$VMName.csv"),

    [switch]$RegisterOnline
)

$ErrorActionPreference = 'Stop'

$inGuestScript = @'
Set-ExecutionPolicy Bypass -Scope Process -Force
if (-not (Get-Command Get-WindowsAutopilotInfo -ErrorAction SilentlyContinue)) {
    Install-Script Get-WindowsAutopilotInfo -Force
}
Get-WindowsAutopilotInfo -OutputFile C:\Windows\Temp\autopilot.csv -Online:$false
'@

Invoke-Command -VMName $VMName -Credential $GuestCredential -ScriptBlock ([scriptblock]::Create($inGuestScript))

New-Item -ItemType Directory -Path (Split-Path $OutputFile) -Force | Out-Null
Copy-Item -FromSession ($null) -ErrorAction SilentlyContinue # placeholder; use PSSession copy below

$s = New-PSSession -VMName $VMName -Credential $GuestCredential
Copy-Item -FromSession $s -Path 'C:\Windows\Temp\autopilot.csv' -Destination $OutputFile -Force
Remove-PSSession $s

Write-Host "Hardware hash saved to: $OutputFile"
Import-Csv $OutputFile | Select-Object SerialNumber, 'Windows Product ID', 'Hardware Hash' | Format-List

if ($RegisterOnline) {
    if (-not (Get-Module Microsoft.Graph.Authentication -ListAvailable)) {
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    }
    Connect-MgGraph -Scopes 'DeviceManagementServiceConfig.ReadWrite.All'
    foreach ($row in (Import-Csv $OutputFile)) {
        $body = @{
            '@odata.type'          = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
            serialNumber           = $row.SerialNumber
            productKey             = $row.'Windows Product ID'
            hardwareIdentifier     = $row.'Hardware Hash'
            groupTag               = 'HyperV-Lab'
            assignedUserPrincipalName = $null
        } | ConvertTo-Json
        Invoke-MgGraphRequest -Method POST `
            -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' `
            -Body $body -ContentType 'application/json'
        Write-Host "Registered $($row.SerialNumber) in Autopilot."
    }
}
