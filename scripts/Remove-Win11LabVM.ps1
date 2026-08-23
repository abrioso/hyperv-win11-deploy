<#
.SYNOPSIS
    Idempotent removal of a lab VM: VM, checkpoints, VHDX and temp unattend ISO.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$VMName
)

$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "VM '$VMName' not found — nothing to do."
    return
}

# Checkpoints must be removed before the VM or the VHDX stays locked
Get-VMSnapshot -VMName $VMName | Remove-VMSnapshot -Confirm:$false

if ($vm.State -ne 'Off') {
    Stop-VM -Name $VMName -Force -TurnOff -Confirm:$false
}

$vhds = Get-VMHardDiskDrive -VMName $VMName | ForEach-Object Path

Remove-VM -Name $VMName -Force -Confirm:$false

foreach ($vhd in $vhds) {
    if ($vhd -and (Test-Path $vhd)) {
        Remove-Item $vhd -Force -Confirm:$false
        Write-Verbose "Deleted $vhd"
    }
}

# Clean up the temp unattend payload
$tmpDir = Join-Path $env:TEMP "unattend-$VMName"
if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }

Write-Host "VM '$VMName' removed."
