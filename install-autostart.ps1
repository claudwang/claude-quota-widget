# Creates a Startup shortcut so the widget launches at login.
# Run manually:  powershell -ExecutionPolicy Bypass -File install-autostart.ps1
# Remove later:  delete "ClaudeQuotaWidget.lnk" from shell:startup
$ErrorActionPreference = 'Stop'
$ws = New-Object -ComObject WScript.Shell
$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'ClaudeQuotaWidget.lnk'
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'wscript.exe'
$lnk.Arguments = '"' + (Join-Path $PSScriptRoot 'launch.vbs') + '"'
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Save()
Write-Output ("Created: " + $lnkPath)
