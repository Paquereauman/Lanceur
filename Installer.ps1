# Installe le Lanceur : demarrage automatique a l'ouverture de session + lancement immediat.
$dir = $PSScriptRoot
$ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\LanceurBarre.ps1`""

$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'LanceurBarre.lnk'))
$s.TargetPath = $ps
$s.Arguments = $arg
$s.WorkingDirectory = $dir
$s.WindowStyle = 7
$s.IconLocation = "$env:WINDIR\System32\shell32.dll,22"
$s.Save()

Start-Process $ps -ArgumentList $arg -WindowStyle Hidden
Write-Host 'Lanceur installe : la barre apparait dans la barre des taches (Ctrl+Alt+Espace).'
