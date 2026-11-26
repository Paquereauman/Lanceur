# Lanceur

Une petite barre de recherche posée **dans la barre des tâches de Windows 11**, juste à gauche de l'horloge.
Tu tapes quelques lettres, elle propose les applis avec leur icône, **Entrée** lance.

Écrit en PowerShell + WinForms : rien à installer, ça tourne avec le PowerShell 5.1 fourni avec Windows.

## Fonctions

- **Recherche instantanée** dans toutes les applis du menu Démarrer (classiques et Microsoft Store) :
  début du nom, mot du nom, initiales, lettres dans l'ordre, sans tenir compte des accents.
- **Icônes** des applis dans les suggestions et dans la barre.
- **Les applis les plus utilisées remontent** en tête.
- **Alias** : tape `ch=chrome` puis Entrée pour que `ch` lance Google Chrome.
  Clic droit sur une suggestion → *Donner un alias à cette appli*, ou `:alias` pour la fenêtre de gestion.
- On peut aussi taper un chemin, une URL ou une commande.
- Raccourci clavier global **Ctrl+Alt+Espace**.
- Se recale toute seule si la barre des tâches change (démarrage, changement d'écran).

## Installation

1. Télécharge le dépôt (bouton *Code → Download ZIP*) et décompresse-le où tu veux.
2. Clic droit sur `Installer.ps1` → **Exécuter avec PowerShell**.

La barre démarre tout de suite et à chaque ouverture de session.
Pour l'enlever : clic droit sur la barre → *Quitter la barre*, puis supprime le raccourci `LanceurBarre` dans
`shell:startup` (tape-le dans la barre d'adresse de l'Explorateur).

## Utilisation

| Action | Touche |
|---|---|
| Ouvrir la barre | clic dedans, ou **Ctrl+Alt+Espace** |
| Choisir | **Haut / Bas** |
| Lancer | **Entrée** ou clic |
| Effacer | **Échap** |
| Créer un alias | `alias=nom de l'appli` puis Entrée |
| Gérer les alias | `:alias`, ou clic droit sur la barre |

## Réglages

En haut de `LanceurBarre.ps1` :

```powershell
$Largeur     = 200   # largeur de la barre
$MargeDroite = 290   # utilisé seulement si la zone de l'horloge est introuvable
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `LanceurBarre.ps1` | la barre dans la barre des tâches |
| `LanceurCore.ps1` | liste des applis, recherche (en C#), alias, historique |
| `Lanceur.ps1` / `Lanceur.bat` | version fenêtre classique (sans la barre) |
| `Installer.ps1` | démarrage automatique + lancement |
| `alias.txt` | tes alias, créé au premier lancement (non versionné) |

L'historique d'utilisation est stocké dans `%APPDATA%\Lanceur`.
