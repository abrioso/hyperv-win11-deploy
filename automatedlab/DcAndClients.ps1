# AD DC + two Windows 11 clients (domain-joined) — good base for testing
# Intune / hybrid join / Group Policy interplay.
New-LabDefinition -Name Win11DcClients -DefaultVirtualizationEngine HyperV

Add-LabVirtualNetworkDefinition -Name LabNet -AddressSpace 192.168.110.0/24

# Domain definition
Add-LabDomainDefinition -Name lab.local -AdminUser Install -AdminPassword 'Lab-Only-ChangeMe!'

Add-Machine -Name DC01 `
            -OperatingSystem 'Windows Server 2022 Datacenter (Desktop Experience)' `
            -Roles RootDC `
            -DomainName lab.local `
            -Memory 4GB -Processors 2 -DiskSize 60GB

Add-Machine -Name CLIENT01,CLIENT02 `
            -OperatingSystem 'Windows 11 Pro' `
            -DomainName lab.local `
            -Memory 8GB -Processors 4 -DiskSize 127GB

Install-Lab

Show-LabDeploymentSummary -Detailed

# Post-deploy: collect Autopilot hashes for the clients if you want to enroll them
# $cred = New-Object pscredential('.\labadmin', ('Lab-Only-ChangeMe!' | ConvertTo-SecureString -AsPlainText -Force))
# foreach ($vm in 'CLIENT01','CLIENT02') {
#     & "$PSScriptRoot\..\scripts\Get-AutopilotHash.ps1" -VMName $vm -GuestCredential $cred
# }
