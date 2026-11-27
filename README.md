# Lanceur

A tiny app-launcher search box that lives **inside the Windows 11 taskbar**, right next to the clock.
Type a few letters, it suggests your apps with their icons, press **Enter** to launch.

![Lanceur in the taskbar: typing "ca" suggests Calculator, Canva, Camera…](docs/screenshot.png)

Written in plain PowerShell + WinForms (with a bit of inline C#): nothing to install, it runs on the
PowerShell 5.1 that ships with Windows. The interface is in French.

## Features

- **Instant search** across every Start-menu app (classic and Microsoft Store), Control Panel items and tasks
  (Indexing Options, "Show hidden files and folders"...), common Settings pages (Display, Wi-Fi, Default apps...,
  also found by French words: `affichage`, `son`, `imprimantes`...) and anything in the `raccourcis` folder.
  Non-app results carry a small grey tag (*Parametres*, *Tache*, *Raccourci*...). It matches the start of the
  name, any word (`wifi` finds *Wi-Fi*), initials (`vsc`), or letters in order, and ignores accents.
  Ranking runs in C# (< 1 ms per keystroke).
- **App icons** in the suggestions, and the selected app's icon in the box itself.
- **Learns what you use**: frequently launched apps move to the top.
- **Aliases**: type `ch=chrome` then Enter, and `ch` now launches Google Chrome.
  Right-click a suggestion → *Donner un alias à cette appli*, or type `:alias` to open the alias manager.
- **Your own shortcuts**: drop any `.lnk`, `.url`, `.exe` or document into the `raccourcis` folder
  (right-click the bar → *Ouvrir le dossier des raccourcis*) and it shows up under its file name.
- Paths, URLs and commands work too.
- **Windows key**: tap it alone to open the bar instead of the Start menu (Win+E and other shortcuts still
  work, Ctrl+Esc opens Start). Global hotkey **Ctrl+Alt+Space** too.
- Works with the taskbar at the top or bottom of the screen.
- Icons are preloaded in the background, so suggestions always appear instantly.
- Stays on top of the taskbar (even when the Start menu opens) and repositions itself when the
  taskbar or screen changes.
- Hides with the taskbar when an app goes full screen (videos, games, slideshows) and comes back afterwards.
- Restarts automatically if it is ever closed by accident.
- Logs starts, stops, every launch and launch errors to `%APPDATA%\Lanceurarre.log`.

## Install

1. Download the repo (*Code → Download ZIP*) and unzip it anywhere.
2. Right-click `Installer.ps1` → **Run with PowerShell**. No admin rights needed.

This registers a per-user scheduled task named `LanceurBarre` that starts the bar at logon and checks
every 5 minutes that it is still running (no console window flashes).

**Uninstall**: right-click the bar → *Quitter la barre*, then run

```powershell
Unregister-ScheduledTask -TaskName LanceurBarre -Confirm:$false
```

If you quit the bar from its menu, it stays closed until the next reboot, or until you double-click
`Demarrer la barre.bat`.

**Moved the folder?** Double-click `Demarrer la barre.bat` in its new location: it notices the task points
to the old folder and re-registers it.

## Usage

| Action | Key |
|---|---|
| Focus the bar | click it, tap **Windows**, or **Ctrl+Alt+Space** |
| Open the real Start menu | **Ctrl+Esc** |
| Move through suggestions | **Up / Down** |
| Launch | **Enter** or click |
| Clear | **Ctrl+Space** (stay in the bar) or **Esc** (clear and go back to the previous window) |
| Delete the last word | **Ctrl+Backspace** |
| Create an alias | `alias=app name`, then Enter |
| Manage aliases | `:alias`, or right-click the bar |
| Refresh the app list / quit | right-click the bar |

## Settings

At the top of `LanceurBarre.ps1`:

```powershell
$Largeur       = 200     # width of the search box (logical pixels)
$MargeDroite   = 290     # only used if the clock area can't be found
$ToucheWindows = $true   # tap the Windows key alone to open the bar ($false = normal Start menu)
```

## Files

| File | Purpose |
|---|---|
| `LanceurBarre.ps1` | the search box in the taskbar |
| `LanceurCore.ps1` | app list, search engine (C#), aliases, usage history, alias manager window |
| `Lanceur.ps1` / `Lanceur.bat` | standalone pop-up window version (no taskbar box), same search engine |
| `Installer.ps1` | registers the scheduled task and starts the bar |
| `Demarrer la barre.bat` | reopens the bar, even after *Quitter la barre*, and repairs the task if the folder moved |
| `raccourcis/` | your own shortcuts and files, searchable by file name (not versioned) |
| `alias.txt` | your aliases, created on first run (not versioned) |

Usage history and the log live in `%APPDATA%\Lanceur`.

## How it works (for the curious)

- Apps come from `Get-StartApps` and are launched through `shell:AppsFolder\<AppID>`, which covers
  both desktop and Store apps.
- Icons are fetched with `IShellItemImageFactory` on the same `shell:AppsFolder` items, alpha channel kept.
- The box is a borderless WinForms window owned by `Shell_TrayWnd`, so Windows keeps it above the taskbar.
- The suggestion list is a `WS_EX_NOACTIVATE` window that also answers `WM_MOUSEACTIVATE` with `MA_NOACTIVATE`,
  so neither typing nor clicking a suggestion ever takes the focus away from the box.
- The scheduled task asks Explorer to start the bar (`Shell.Application.ShellExecute`) instead of running it
  directly: a process started by Task Scheduler is treated as a background process and can't always take the focus.
