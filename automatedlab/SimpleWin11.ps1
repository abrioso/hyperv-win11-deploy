# Simple single Windows 11 client VM via AutomatedLab
New-LabDefinition -Name Win11Simple -DefaultVirtualizationEngine HyperV

Add-LabVirtualNetworkDefinition -Name LabNet -HyperVProperties @{ SwitchType = 'Internal' }
Add-LabVirtualNetworkDefinition -Name 'Default Switch' -HyperVProperties @{ SwitchType = 'External' }

Add-Machine -Name LAB-AL-01 `
            -OperatingSystem 'Windows 11 Pro' `
            -Memory 8GB -Processors 4 `
            -DiskSize 127GB

Install-Lab

Show-LabDeploymentSummary -Detailed
