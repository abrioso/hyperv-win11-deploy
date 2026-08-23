<#
.SYNOPSIS
    One-shot bootstrap for this repo's prerequisites on a Windows host.

.DESCRIPTION
    Checks (and installs where safe) everything New-Win11LabVM.ps1 needs:

      1. Elevation + Windows edition support (Pro/Enterprise/Education; Home has no Hyper-V)
      2. CPU virtualization (VT-x/AMD-V) and SLAT
      3. Hyper-V feature (installs it if missing, warns about the required restart)
      4. Hyper-V PowerShell module
      5. Windows 11 ISO:
           - found at -IsoPath / $env:WIN11_ISO / C:\ISO\Win11.iso -> use it
           - otherwise, with -DownloadEvalIso, downloads the official evaluation ISO
             from Microsoft into C:\ISO\ (large file, ~6 GB)
      6. Writes the resolved ISO path to a user environment variable WIN11_ISO so
         the other scripts pick it up automatically.

    Idempotent: every step skips work that is already done.

.PARAMETER IsoPath
    Existing Win11 ISO to validate and register. Optional.

.PARAMETER DownloadEvalIso
    Download the Windows 11 enterprise evaluation ISO (90 days) from Microsoft
    if no valid ISO was found. Requires internet; ~6 GB.

.PARAMETER IsoDir
    Directory for downloaded/stored ISOs. Default: C:\ISO

.EXAMPLE
    # Check-only run first:
    .\Enable-LabBootstrap.ps1

    # Full bootstrap incl. eval ISO download:
    .\Enable-LabBootstrap.ps1 -DownloadEvalIso
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [switch]$DownloadEvalIso,
    [string]$IsoDir = $(if ($PSScriptRoot) { Join-Path (Split-Path $PSScriptRoot -Parent) 'iso' } else { 'C:\ISO' })
)

$ErrorActionPreference = 'Stop'
$script:needsRestart = $false

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok  ([string]$msg) { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Warn2 ([string]$msg) { Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "    [FAIL] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------- 1. elevation
Write-Step 'Checking elevation'
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '    Not elevated — relaunching elevated (UAC prompt)...' -ForegroundColor Yellow

    # Rebuild the argument list, preserving the original switches/parameters
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        switch -Wildcard ($k) {
            'DownloadEvalIso' { $argList += "-DownloadEvalIso" }
            default           { $argList += "-$k `"$($PSBoundParameters[$k])`"" }
        }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0   # the elevated instance takes over; this one hands off cleanly
}
Write-Ok "Running as $($identity.Name)"

# ------------------------------------------------------- 2. edition + hardware
Write-Step 'Checking Windows edition'
$osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
if ($osCaption -match 'Home') {
    Write-Fail "$osCaption cannot run Hyper-V (needs Pro/Enterprise/Education)."
    exit 1
}
Write-Ok $osCaption

Write-Step 'Checking virtualization support (VT-x / AMD-V, SLAT)'
$cv = Get-CimInstance Win32_ComputerSystem
$proc = Get-CimInstance Win32_Processor
if ($cv.HypervisorPresent) {
    Write-Ok 'A hypervisor is already present (Hyper-V running).'
} elseif (-not ($proc.VirtualizationFirmwareEnabled -or $proc.SecondLevelAddressTranslationExtensions)) {
    Write-Fail 'Virtualization disabled in firmware. Enable VT-x/AMD-V (and SLAT) in BIOS/UEFI.'
    exit 1
} else {
    Write-Ok 'CPU virtualization available.'
}

# ------------------------------------------------------------ 3. Hyper-V feature
Write-Step 'Checking Hyper-V feature'
$hyperV = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
if (-not $hyperV) {
    Write-Warn2 'Microsoft-Hyper-V-All not found; trying client components individually.'
    $featureNames = 'Microsoft-Hyper-V', 'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Management-PowerShell'
} else {
    $featureNames = 'Microsoft-Hyper-V-All'
}

foreach ($name in $featureNames) {
    $f = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
    switch ($f.State) {
        'Enabled'    { Write-Ok "$name enabled" }
        'Disabled'   {
            Write-Warn2 "$name disabled — enabling (restart required afterwards)"
            $r = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
            if ($r.RestartNeeded) { $script:needsRestart = $true }
        }
        default      { Write-Fail "$name state '$($f.State)' — install manually via 'optionalfeatures.exe'" }
    }
}

Write-Step 'Checking Hyper-V PowerShell module'
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    Write-Ok 'Hyper-V module loaded.'
} else {
    Write-Warn2 'Module not importable yet — normal until after the post-install restart.'
    $script:needsRestart = $true
}

# ------------------------------------------------------------------- 4. the ISO
Write-Step 'Locating Windows 11 ISO'

$candidates = @($IsoPath, $env:WIN11_ISO, (Join-Path $IsoDir 'Win11.iso'), (Join-Path $IsoDir 'Win11_24H2_English_x64.iso')) |
    Where-Object { $_ }

$iso = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) {
        $sizeGB = [math]::Round((Get-Item $c).Length / 1GB, 1)
        if ($sizeGB -lt 3) {
            Write-Warn2 "'$c' exists but is only ${sizeGB} GB — too small for a Win11 ISO, skipping."
            continue
        }
        $iso = $c
        break
    }
}

if (-not $iso -and $DownloadEvalIso) {
    New-Item -ItemType Directory -Path $IsoDir -Force | Out-Null

    # Microsoft changes the exact eval URL per release; resolve the current one
    # from the official download page rather than hard-coding a dead link.
    Write-Host '    Resolving current Windows 11 enterprise evaluation download...'
    $page = Invoke-WebRequest -Uri 'https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise' -UseBasicParsing
    $link = ($page.Links | Where-Object href -match '\.iso$' | Select-Object -First 1).href
    if (-not $link) {
        Write-Fail 'Could not resolve an ISO link on the Eval Center page (layout may have changed).'
        Write-Host '    Download manually from https://www.microsoft.com/evalcenter/evaluate-windows-11-enterprise'
        Write-Host "    and save it as $(Join-Path $IsoDir 'Win11.iso')"
    } else {
        $dest = Join-Path $IsoDir 'Win11_eval.iso'
        Write-Host "    Downloading (~6 GB) to $dest ..."
        Invoke-WebRequest -Uri $link -OutFile $dest -UseBasicParsing
        $iso = $dest
    }
}

if ($iso) {
    Write-Ok "ISO found: $iso"
    # Persist for the other scripts (user scope — no elevation needed later)
    [Environment]::SetEnvironmentVariable('WIN11_ISO', $iso, 'User')
    $env:WIN11_ISO = $iso
    Write-Ok 'WIN11_ISO user environment variable set.'
} else {
    Write-Warn2 'No valid ISO yet. Either:'
    Write-Host  '      - re-run with -DownloadEvalIso, or'
    Write-Host  "      - copy your own volume-license ISO to $(Join-Path $IsoDir 'Win11.iso') and re-run."
}

# --------------------------------------------------------------------- summary
Write-Host ''
Write-Step 'Summary'
if ($script:needsRestart) {
    Write-Warn2 'A RESTART IS REQUIRED before VMs can be created. After rebooting, re-run this script to confirm everything is green.'
} else {
    Write-Ok 'Host prerequisites satisfied.'
    Write-Host "    Next step: .\New-Win11LabVM.ps1 -VMName 'LAB-01'"
}
