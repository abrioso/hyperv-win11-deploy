<#
.SYNOPSIS
    Creates and starts a fully automated Windows 11 Gen 2 Hyper-V VM.

.DESCRIPTION
    - Gen 2 VM with vTPM and Secure Boot (Windows 11 template) so Win11 installs without registry bypasses.
    - Dynamic memory sized for a 64 GB host.
    - Injects an Autounattend.xml onto an extra DVD drive so setup runs unattended.
    - Idempotent: refuses to overwrite an existing VM unless -Force.

.PARAMETER VMName
    Name of the VM. Suggested convention: LAB-<purpose>-<nn>

.PARAMETER IsoPath
    Path to the Windows 11 ISO. Defaults to $env:WIN11_ISO or C:\ISO\Win11.iso

.PARAMETER MemoryGB
    Startup memory in GB. Dynamic memory range becomes [2GB .. 32GB].

.PARAMETER ProcessorCount
    Number of virtual processors.

.PARAMETER DiskGB
    Size of the VHDX in GB (dynamic).

.PARAMETER SwitchName
    Virtual switch to attach. Default: 'Default Switch' (outbound NAT, zero config).

.PARAMETER AdminPassword
    Local admin password baked into the unattend. CHANGE IT for anything sensitive.

.PARAMETER Force
    Remove an existing VM with the same name first.

.EXAMPLE
    .\New-Win11LabVM.ps1 -VMName 'LAB-INTUNE-01' -MemoryGB 8
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [string]$IsoPath = $(if ($env:WIN11_ISO) { $env:WIN11_ISO } else { 'C:\ISO\Win11.iso' }),

    [ValidateRange(4, 48)]
    [int]$MemoryGB = 8,

    [ValidateRange(1, 16)]
    [int]$ProcessorCount = 4,

    [ValidateRange(64, 512)]
    [int]$DiskGB = 127,

    [string]$SwitchName = 'Default Switch',

    [string]$AdminPassword = 'Lab-Only-ChangeMe!',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

#region sanity checks
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell module not available. Enable the Hyper-V feature first.'
}
if (-not (Test-Path $IsoPath)) {
    throw "ISO not found at '$IsoPath'. Pass -IsoPath or set `$env:WIN11_ISO."
}
if ([Security.Principal.WindowsIdentity]::GetCurrent().Owner -ne [Security.Principal.WindowsIdentity]::GetAnonymous()) {
    # cheap admin check
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run this script from an elevated PowerShell session.' }
}
#endregion

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    if ($Force) {
        & "$PSScriptRoot\Remove-Win11LabVM.ps1" -VMName $VMName -Confirm:$false
    } else {
        throw "A VM named '$VMName' already exists. Use -Force to replace it."
    }
}

$vmPath   = Join-Path (Get-VMHost).VirtualHardDiskPath $VMName
$vhdPath  = Join-Path $vmPath "$VMName.vhdx"
$unattend = Join-Path $PSScriptRoot 'Unattend\autounattend.xml'

New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

# Token-substitute the unattend template into a temp ISO payload
$tempDir = Join-Path $env:TEMP "unattend-$VMName"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$xml = Get-Content $unattend -Raw
$xml = $xml.Replace('{{ADMIN_PASSWORD}}', [System.Security.SecurityElement]::Escape($AdminPassword))
Set-Content -Path (Join-Path $tempDir 'autounattend.xml') -Value $xml -Encoding UTF8

# Build a small data ISO with oscdimg if available, otherwise fall back to a VFD-less approach:
# New-VHD + Mount + copy works too, but Gen2 has no floppy; simplest reliable carrier is a data DVD.
$dataIso = Join-Path $env:TEMP "unattend-$VMName.iso"
$oscdimg = Get-ChildItem "$env:ProgramFiles*\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($oscdimg) {
    & $oscdimg.FullName -n -m $tempDir $dataIso | Out-Null
} else {
    # No ADK? Use New-IsoFile community approach inline (CDFs parser)
    Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/MicrosoftDocs/windows-powershell-docs/main/docset/winserver2019/packagemanagement/New-IsoFile.ps1') | Out-Null
    Get-ChildItem $tempDir | New-IsoFile -Path $dataIso -Media DVDPLUSRW92 | Out-Null
}

Write-Verbose "Creating Gen 2 VM '$VMName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
       -NewVHDPath $vhdPath -NewVHDSizeBytes ($DiskGB * 1GB) `
       -SwitchName $SwitchName | Out-Null

Set-VMProcessor -VMName $VMName -Count $ProcessorCount
Set-VMMemory   -VMName $VMName -DynamicMemoryEnabled $true -MinimumBytes 2GB -MaximumBytes 32GB
Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'

# Windows 11 hard requirements: Secure Boot (Win11 template) + vTPM 2.0
Set-VMFirmware -VMName $VMName -SecureBootTemplate MicrosoftWindowsWindows11
Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
Enable-VMTPM -VMName $VMName

Add-VMDvdDrive -VMName $VMName -Path $IsoPath
Add-VMDvdDrive -VMName $VMName -Path $dataIso
$bootDvd  = Get-VMDvdDrive -VMName $VMName | Where-Object Path -eq $IsoPath
$unatDvd  = Get-VMDvdDrive -VMName $VMName | Where-Object Path -eq $dataIso

# Boot order: install ISO first, unattend ISO second, disk third
Set-VMFirmware -VMName $VMName -FirstBootDevice $bootDvd
Set-VMFirmware -VMName $VMName -BootOrder $bootDvd, $unatDvd, (Get-VMHardDiskDrive -VMName $VMName)

if ($PSCmdlet.ShouldProcess($VMName, 'Start VM')) {
    Start-VM -Name $VMName
    vmconnect.exe localhost $VMName   # open console to watch it go
}

Write-Host @"
VM '$VMName' created and started.
  Setup runs fully unattended (Autounattend.xml). First boot takes ~15-30 min.
  When done: .\Checkpoint-Win11LabVM.ps1 -VMName $VMName -SnapshotName golden

Intune/Autopilot next step (inside the guest):
  Set-ExecutionPolicy Bypass -Scope Process -Force
  Install-Script Get-WindowsAutopilotInfo   # or run scripts/Get-AutopilotHash.ps1 from the host
"@
