# hyperv-win11-deploy

Automated Windows 11 lab VM deployment on local Hyper-V, tuned for a 64 GB RAM laptop.

Two approaches:

| Approach | Use for | Location |
|---|---|---|
| **Standalone PowerShell scripts** | Fast create/destroy test labs from your own Win11 ISO | `scripts/` |
| **AutomatedLab** | Multi-VM labs (DC + clients + servers) with roles/DSC | `automatedlab/` |

## Prerequisites

- Windows 10/11 Pro or Enterprise host with Hyper-V enabled:

  ```powershell
  # Run as Administrator
  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart
  ```

- A Windows 11 ISO (volume licensing / MSDN). Place it in `C:\ISO\Win11.iso` or set `$env:WIN11_ISO`.
- PowerShell 5.1+ (built-in) — scripts avoid external dependencies on purpose.

## Quick start (standalone)

```powershell
# From an elevated PowerShell session
Set-Location .\scripts

# Create a VM: 4 vCPU / 8 GB RAM / 127 GB disk, auto-installs via unattend (no clicks)
.\New-Win11LabVM.ps1 -VMName 'LAB-01' -IsoPath C:\ISO\Win11.iso -MemoryGB 8 -ProcessorCount 4

# After install completes, checkpoint it and clone freely
.\Checkpoint-Win11LabVM.ps1 -VMName 'LAB-01' -SnapshotName 'golden'
.\New-Win11LabVM.ps1 -VMName 'LAB-02' ... # repeat for more VMs

# Tear down everything when done
.\Remove-Win11LabVM.ps1 -VMName 'LAB-01'   # deletes VM + disks + checkpoints
```

Defaults are sized for a 64 GB host: leave at least ~16 GB free for the host OS.

## Best practices baked into the scripts

1. **Generation 2 + vTPM** — Windows 11 requires TPM 2.0 and Secure Boot; the scripts add a key protector (`Set-VMKeyProtector` → `Enable-VMTPM`) so the ISO installs without bypasses.
2. **Secure Boot template** — `MicrosoftWindowsWindows11` template (not the default MicrosoftWindows).
3. **Unattend.xml** — auto locale (pt-PT fallback en-US), admin account, skip OOBE prompts. Injected via a floppy/VFD-less approach: mounted to `D:\Autounattend.xml` during first boot using an additional DVD drive.
4. **Dynamic memory** with sensible min/max instead of fixed RAM — lets you run more VMs concurrently on 64 GB.
5. **Default Switch vs NAT** — `Default Switch` gives outbound internet with changing IPs; use the included NAT setup script if you need stable IPs between guest↔host.
6. **Checkpoints before experiments** — standard/saved state checkpoints, not production ones, in a lab.
7. **Naming convention** — `LAB-<purpose>-<nn>` so bulk cleanup is trivial.
8. **Idempotent teardown** — `Remove-Win11LabVM.ps1` is safe to re-run; it skips VMs that don't exist.

## AutomatedLab path

See `automatedlab/README.md`. TL;DR:

```powershell
Install-Module AutomatedLab -Scope CurrentUser   # per-user, no admin needed
# One-time image download to LabSources
New-LabDefinition -Name Win11Lab -DefaultVirtualizationEngine HyperV
Add-Machine -Name CLIENT01 -OperatingSystem 'Windows 11 Pro' -Memory 8GB
Install-Lab
```

AutomatedLab downloads eval ISOs automatically into `%LABSOURCES%\ISOs`; point it at your own ISO by copying it there with the expected name.

## Intune / Autopilot enrollment

Para inscrever as VMs em Intune via Autopilot:

1. A VM é criada com **vTPM 2.0 + Secure Boot (template Win11)** — requisito de attestation do Windows 11; sem isto a recolha do hardware hash falha.
2. Depois da VM arrancar, recolhe o hardware hash a partir do host com PowerShell Direct (não precisa de rede no guest):

   ```powershell
   $cred = Get-Credential            # admin local dentro da guest
   .\scripts\Get-AutopilotHash.ps1 -VMName LAB-INTUNE-01 -GuestCredential $cred -RegisterOnline
   ```

3. O script guarda o CSV em `scripts/AutopilotHashes/` e, com `-RegisterOnline`, faz POST ao Microsoft Graph (`importedWindowsAutopilotDeviceIdentities`) com `groupTag = HyperV-Lab` — filtra assim estas VMs nos filtros de scope do Autopilot.
4. **Caveats importantes** (flag de risco):
   - Hardware hashes de VMs Hyper-V são aceites pelo Autopilot, mas o *attestation* TPM virtual funciona apenas em Gen 2 com key protector persistente — os scripts já tratam disto.
   - Estas VMs têm um password de lab conhecido embutido no unattend — nunca as ligues à rede corporativa/Intune production sem trocar a password ou recriar a imagem.
   - Se usas Enrollment Status Page (ESP), considera desativar hardware attestation durante testes iniciais para acelerar o OOBE.

## Repo layout

```
scripts/
  New-Win11LabVM.ps1         # create + start a fully automated Win11 Gen2 VM
  Remove-Win11LabVM.ps1      # idempotent delete (VM, disks, snapshots)
  Checkpoint-Win11LabVM.ps1  # snapshot helper (create/list/restore)
  New-LabNatSwitch.ps1       # internal switch + NAT network with stable addressing
  Unattend/autounattend.xml  # answer file template (token-substituted)
automatedlab/
  README.md
  SimpleWin11.ps1            # single client VM example
  DcAndClients.ps1           # AD DC + two Win11 clients example
```

## Notes / caveats

- The unattend sets a known local admin password — fine for throwaway labs, never reuse these images in production.
- Evaluation media activates for 90 days; volume-license keys go into `Unattend/autounattend.xml` (token `PRODUCT_KEY`) only if you choose to embed them.
