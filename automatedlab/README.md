# AutomatedLab examples

Multi-VM lab definitions. AutomatedLab handles ISO download, unattend, roles, and DSC for you.

## Install

```powershell
Install-Module AutomatedLab -Scope CurrentUser -AllowClobber
# One-time: tell it where to keep ISOs and VMs
Set-PSFConfig -Module AutomatedLab -Name MachineUserName     -Value 'labadmin'
Set-PSFConfig -Module AutomatedLab -Name MachineUserPassword -Value ('Lab-Only-ChangeMe!' | ConvertTo-SecureString -AsPlainText -Force)
```

Copy your Win11 ISO into `%LABSOURCES%\ISOs\` (create the folder first with `New-LabSourcesFolder`)
so `Get-LabOperatingSystem` can find it, e.g. as `Win11_24H2_x64.iso`.

## Examples

- `SimpleWin11.ps1` — one Windows 11 client VM, ~8 GB RAM.
- `DcAndClients.ps1` — AD DS domain controller + two Win11 clients joined to the domain,
  useful for testing Intune/Group Policy coexistence or hybrid join.

## Notes

- AutomatedLab enables nested virtualization when needed (`-EnableWindowsPowerShell` not required;
  use `-VMProcessorCount` and add `-EnableNestedVirtualization` on roles like Hyper-V).
- For Autopilot hash collection inside an AutomatedLab VM you can reuse
  `../scripts/Get-AutopilotHash.ps1` — PowerShell Direct works identically.
