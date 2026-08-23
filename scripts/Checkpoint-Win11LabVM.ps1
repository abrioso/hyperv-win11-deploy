<#
.SYNOPSIS
    Checkpoint helper: create / list / restore / delete checkpoints on a lab VM.
.EXAMPLE
    .\Checkpoint-Win11LabVM.ps1 -VMName LAB-01 -SnapshotName golden
    .\Checkpoint-Win11LabVM.ps1 -VMName LAB-01 -List
    .\Checkpoint-Win11LabVM.ps1 -VMName LAB-01 -Restore golden
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory)]
    [string]$VMName,

    [Parameter(ParameterSetName = 'Create', Position = 0)]
    [string]$SnapshotName,

    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    [Parameter(ParameterSetName = 'Restore')]
    [string]$Restore,

    [Parameter(ParameterSetName = 'Delete')]
    [string]$Delete
)

$ErrorActionPreference = 'Stop'

switch ($PSCmdlet.ParameterSetName) {
    'Create' {
        if (-not $SnapshotName) { $SnapshotName = "snap-$(Get-Date -Format yyyyMMdd-HHmm)" }
        # Labs use standard checkpoints; production checkpoints are for prod guests.
        Checkpoint-VM -Name $VMName -SnapshotName $SnapshotName
        Write-Host "Checkpoint '$SnapshotName' created on '$VMName'."
    }
    'List' {
        Get-VMSnapshot -VMName $VMName |
            Select-Object Name, CreationTime, @{n='SizeGB';e={[math]::Round($_.MemoryAssigned/1GB,1)}} |
            Format-Table -AutoSize
    }
    'Restore' {
        Restore-VMSnapshot -Name $Restore -VMName $VMName -Confirm:$false
        Write-Host "'$VMName' restored to '$Restore'."
    }
    'Delete' {
        Get-VMSnapshot -VMName $VMName | Where-Object Name -eq $Delete | Remove-VMSnapshot -Confirm:$false
        Write-Host "Checkpoint '$Delete' removed."
    }
}
