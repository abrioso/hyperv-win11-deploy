<#
.SYNOPSIS
    Creates an internal switch with NAT so guests get stable IPs and the host can reach them.

.DESCRIPTION
    'Default Switch' is fine for outbound internet but re-addresses on reboot.
    This script gives you a persistent 192.168.100.0/24 NAT network:
      host   = 192.168.100.1
      guests = DHCP-less static or your own DHCP; simplest: set static IPs in the guest.

.EXAMPLE
    .\New-LabNatSwitch.ps1 -SwitchName LabNAT -NatNetwork 192.168.100.0/24
#>
[CmdletBinding()]
param(
    [string]$SwitchName = 'LabNAT',
    [string]$NatNetwork = '192.168.100.0/24',
    [string]$NatName    = 'LabNatNetwork'
)

$ErrorActionPreference = 'Stop'

# Idempotent: skip if already correct
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Write-Host "Switch '$SwitchName' already exists — skipping creation."
} else {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
}

$gwIp  = ($NatNetwork -replace '\.\d+/\d+', '.1')
$prefixLen = [int]($NatNetwork -split '/')[1]

$adapter = Get-NetAdapter | Where-Object Name -eq "vEthernet ($SwitchName)"
if (-not $adapter) { throw "Adapter for switch '$SwitchName' not found." }

if (-not (Get-NetIPAddress -IPAddress $gwIp -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -IPAddress $gwIp -PrefixLength $prefixLen `
        -InterfaceIndex $adapter.ifIndex | Out-Null
}

if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatNetwork | Out-Null
}

Write-Host @"
NAT lab network ready.
  Switch : $SwitchName (attach VMs to this)
  Gateway: $gwIp/$prefixLen on the host
  Guests : use e.g. 192.168.100.10-250, gateway $gwIp, DNS 192.168.100.1 or 1.1.1.1
"@
