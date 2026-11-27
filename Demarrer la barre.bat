@echo off
rem Rouvre la barre du lanceur, meme apres "Quitter la barre".
rem Si la tache LanceurBarre manque ou pointe vers un autre dossier (dossier Lanceur deplace),
rem elle est reinstallee depuis ici par Installer.ps1, qui lance aussi la barre.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
  "$d = '%~dp0'.TrimEnd('\');" ^
  "Remove-Item (Join-Path $env:APPDATA 'Lanceur\arret_volontaire') -ErrorAction SilentlyContinue;" ^
  "$t = Get-ScheduledTask -TaskName LanceurBarre -ErrorAction SilentlyContinue;" ^
  "if ($t -and $t.Actions[0].WorkingDirectory -eq $d) { Start-ScheduledTask -TaskName LanceurBarre }" ^
  "else { & (Join-Path $d 'Installer.ps1') | Out-Null }"
