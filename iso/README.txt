Place your Windows 11 ISO here (e.g. Win11.iso from volume licensing / MSDN).

Enable-LabBootstrap.ps1 checks this folder first and registers any valid ISO
(>= 3 GB) it finds in the WIN11_ISO environment variable for the other scripts.

With -DownloadEvalIso, the official evaluation ISO is downloaded INTO this folder.
