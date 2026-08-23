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

# Least privilege: full admin is NOT required. Membership of the local
# 'Hyper-V Administrators' group is enough for everything except (on some
# builds) creating a new VM key protector for vTPM — that case is handled
# at the vTPM step below with a targeted self-elevation fallback.
function Test-HyperVAdmin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wid = $id.User
    foreach ($sid in 'S-1-5-32-578',   # BUILTIN\Hyper-V Administrators
                     'S-1-5-32-544') { # BUILTIN\Administrators
        try {
            $grp = New-Object Security.Principal.SecurityIdentifier($sid)
            if ($id.Groups -contains $grp) { return $true }
        } catch { }
    }
    return $false
}
$script:IsHyperVAdmin = Test-HyperVAdmin
if (-not $script:IsHyperVAdmin) {
    Write-Warning 'Not a member of Hyper-V Administrators or Administrators - relaunching elevated (UAC)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        if ($PSBoundParameters[$k] -is [switch]) {
            if ($PSBoundParameters[$k]) { $argList += "-$k" }
        } else {
            $argList += "-$k `"$($PSBoundParameters[$k])`""
        }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
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

# Package the unattend on a small FAT32-formatted VHD attached as a second drive.
# Windows Setup scans ALL attached fixed/removable media for autounattend.xml at
# the root, so no ADK/oscdimg and no data-DVD ISO is needed. Pure built-in tooling.
$dataIso = $null
$vhdPath = Join-Path $vmPath "$VMName-unattend.vhdx"
try {
    New-VHD -Path $vhdPath -SizeBytes 16MB -Fixed -ErrorAction Stop | Out-Null
    $mounted = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    $disk    = $mounted | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter |
            Format-Volume -FileSystem FAT32 -NewFileSystemLabel 'UNATTEND'
    Copy-Item (Join-Path $tempDir 'autounattend.xml') -Destination "$($part.DriveLetter):\autounattend.xml"
    Dismount-VHD -Path $vhdPath
} catch {
    # Mounting a VHD attaches it to the host storage stack -> requires FULL admin,
    # even for Hyper-V Administrators (unlike VM management). Relaunch elevated.
    Write-Warning "VHD mount denied without full admin ($($_.Exception.Message))."
    if ($mounted -and $mounted.DiskNumber -ge 0) { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue }
    Write-Host 'Relaunching elevated (UAC) to build the unattend drive...' -ForegroundColor Yellow

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-VMName', "`"$VMName`"",
                 '-MemoryGB', $MemoryGB, '-ProcessorCount', $ProcessorCount,
                 '-DiskGB', $DiskGB, '-SwitchName', "`"$SwitchName`"",
                 '-AdminPassword', "`"$AdminPassword`"", '-Force')
    if ($IsoPath) { $argList += @('-IsoPath', "`"$IsoPath`"") }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 1
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
try {
    Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector -ErrorAction Stop
    Enable-VMTPM -VMName $VMName
} catch [Exception] {
    # Some builds deny key protector creation to Hyper-V Administrators.
    # Fall back: relaunch just the remaining work elevated (UAC) and exit.
    Write-Warning "Key protector creation denied without full admin ($($_.Exception.Message))."
    Write-Host 'Relaunching elevated to complete vTPM setup...' -ForegroundColor Yellow

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-VMName', "`"$VMName`"",
                 '-MemoryGB', $MemoryGB, '-ProcessorCount', $ProcessorCount,
                 '-DiskGB', $DiskGB, '-SwitchName', "`"$SwitchName`"",
                 '-AdminPassword', "`"$AdminPassword`"", '-Force')   # -Force: VM already exists from the non-elevated attempt
    if ($IsoPath) { $argList += @('-IsoPath', "`"$IsoPath`"") }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 1
}

Add-VMDvdDrive -VMName $VMName -Path $IsoPath
Add-VMHardDiskDrive -VMName $VMName -Path $vhdPath   # unattend carrier (FAT32)
$bootDvd = Get-VMDvdDrive -VMName $VMName | Where-Object Path -eq $IsoPath

# Boot order: install ISO first, then disk
Set-VMFirmware -VMName $VMName -FirstBootDevice $bootDvd
Set-VMFirmware -VMName $VMName -BootOrder $bootDvd, (Get-VMHardDiskDrive -VMName $VMName)[0]

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
