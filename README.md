# Lanceur

A tiny app-launcher search box that lives **inside the Windows 11 taskbar**, right next to the clock.
Type a few letters, it suggests your apps with their icons, press **Enter** to launch.

![Lanceur in the taskbar: typing "ca" suggests Calculator, Canva, Camera…](docs/screenshot.png)

Written in plain PowerShell + WinForms (with a bit of inline C#): nothing to install, it runs on the
PowerShell 5.1 that ships with Windows. The interface is in French.

## Features

- **Instant search** across every Start-menu app (classic and Microsoft Store): matches the start of the
  name, any word, initials, or letters in order, and ignores accents. Ranking runs in C# (< 1 ms per keystroke).
- **App icons** in the suggestions, and the selected app's icon in the box itself.
- **Learns what you use**: frequently launched apps move to the top.
- **Aliases**: type `ch=chrome` then Enter, and `ch` now launches Google Chrome.
  Right-click a suggestion → *Donner un alias à cette appli*, or type `:alias` to open the alias manager.
- Paths, URLs and commands work too.
- Global hotkey **Ctrl+Alt+Space**.
- Stays on top of the taskbar (even when the Start menu opens) and repositions itself when the
  taskbar or screen changes.
- Restarts automatically if it is ever closed by accident.

## Install

1. Download the repo (*Code → Download ZIP*) and unzip it anywhere.
2. Right-click `Installer.ps1` → **Run with PowerShell**. No admin rights needed.

This registers a per-user scheduled task named `LanceurBarre` that starts the bar at logon and checks
every 5 minutes that it is still running (no console window flashes).

**Uninstall**: right-click the bar → *Quitter la barre*, then run

```powershell
Unregister-ScheduledTask -TaskName LanceurBarre -Confirm:$false
```

If you quit the bar from its menu, it stays closed until the next reboot.

## Usage

| Action | Key |
|---|---|
| Focus the bar | click it, or **Ctrl+Alt+Space** |
| Move through suggestions | **Up / Down** |
| Launch | **Enter** or click |
| Clear | **Esc** |
| Create an alias | `alias=app name`, then Enter |
| Manage aliases | `:alias`, or right-click the bar |
| Refresh the app list / quit | right-click the bar |

## Settings

At the top of `LanceurBarre.ps1`:

```powershell
$Largeur     = 200   # width of the search box (logical pixels)
$MargeDroite = 290   # only used if the clock area can't be found
```

## Files

| File | Purpose |
|---|---|
| `LanceurBarre.ps1` | the search box in the taskbar |
| `LanceurCore.ps1` | app list, search engine (C#), aliases, usage history, alias manager window |
| `Lanceur.ps1` / `Lanceur.bat` | standalone pop-up window version (no taskbar box) |
| `Installer.ps1` | registers the scheduled task and starts the bar |
| `alias.txt` | your aliases, created on first run (not versioned) |

Usage history and the log live in `%APPDATA%\Lanceur`.

## How it works (for the curious)

- Apps come from `Get-StartApps` and are launched through `shell:AppsFolder\<AppID>`, which covers
  both desktop and Store apps.
- Icons are fetched with `IShellItemImageFactory` on the same `shell:AppsFolder` items, alpha channel kept.
- The box is a borderless WinForms window owned by `Shell_TrayWnd`, so Windows keeps it above the taskbar.
- The suggestion list is a `WS_EX_NOACTIVATE` window, so it never steals the keyboard from the box.
