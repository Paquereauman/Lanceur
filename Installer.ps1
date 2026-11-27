# Installe le Lanceur : tache planifiee qui lance la barre a l'ouverture de session
# et la relance toute seule (verification toutes les 5 minutes) si elle a ete fermee par erreur.
# Pas besoin des droits administrateur.
$dir = $PSScriptRoot
$ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\LanceurBarre.ps1`""

# La tache ne lance pas la barre elle-meme : elle demande a l'Explorateur de le faire (Shell.Application.ShellExecute).
# Un processus lance directement par le Planificateur est traite comme un processus d'arriere-plan : un clic
# sur la barre ne lui donnerait pas toujours le focus. Lance par l'Explorateur, il se comporte comme une appli normale.
# ShellExecute show = 0 : cache des le depart. conhost --headless : aucune fenetre noire qui clignote.
$start = "(New-Object -ComObject Shell.Application).ShellExecute('$ps', '$($arg -replace "'", "''")', '$($dir -replace "'", "''")', 'open', 0)"
$enc   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($start))
$action   = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument "--headless `"$ps`" -NoProfile -EncodedCommand $enc" -WorkingDirectory $dir
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
Write-Host 'Lanceur installe : la barre apparait dans la barre des taches (touche Windows ou Ctrl+Alt+Espace).'
