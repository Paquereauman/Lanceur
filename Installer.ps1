# Installe le Lanceur : tache planifiee qui lance la barre a l'ouverture de session
# et la relance toute seule (verification toutes les 5 minutes) si elle a ete fermee par erreur.
# Pas besoin des droits administrateur.
$dir = $PSScriptRoot
$ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\LanceurBarre.ps1`""

# conhost --headless : aucune fenetre noire qui clignote
$action   = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument "--headless `"$ps`" $arg" -WorkingDirectory $dir
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'LanceurBarre' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

# Ancien systeme de demarrage (raccourci) : remplace par la tache
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'LanceurBarre.lnk') -ErrorAction SilentlyContinue

# Lancement immediat (et annule un eventuel "Quitter la barre")
Remove-Item (Join-Path $env:APPDATA 'Lanceur\arret_volontaire') -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'LanceurBarre'
Write-Host 'Lanceur installe : la barre apparait dans la barre des taches (Ctrl+Alt+Espace).'
