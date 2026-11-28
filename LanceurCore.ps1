# Coeur du lanceur : liste des applis, alias, recherche, lancement, historique.
# Utilise par Lanceur.ps1 (fenetre) et LanceurBarre.ps1 (barre dans la barre des taches).

$dataDir   = Join-Path $env:APPDATA 'Lanceur'
$histFile  = Join-Path $dataDir 'historique.json'
$aliasFile = Join-Path $PSScriptRoot 'alias.txt'
$raccourcisDir = Join-Path $PSScriptRoot 'raccourcis'   # tout fichier pose ici (.lnk, .url, .exe, document...) apparait dans la recherche
New-Item -ItemType Directory -Force $dataDir, $raccourcisDir, (Join-Path $raccourcisDir ".icons") | Out-Null

# Fichiers du dossier raccourcis (sous-dossiers compris), sauf les fichiers caches type .gitkeep
# (fichiers et dossiers commencant par un point exclus : ".icons" garde les icones utilisees par tes raccourcis)
function Get-Raccourcis { @(Get-ChildItem -LiteralPath $raccourcisDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName.Substring($raccourcisDir.Length) -notmatch '\\\.' }) }
# Change quand un raccourci est ajoute, supprime, renomme ou modifie
function Get-RaccourcisStamp { (Get-Raccourcis | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';' }

$aliasEntete = @(
    '# Alias du lanceur : une ligne par alias, au format   alias = cible'
    "# La cible peut etre le nom exact d'une appli du menu Demarrer, un chemin, une URL ou une commande."
    '# Tape ":alias" dans la barre pour ouvrir la fenetre des alias.'
)

$script:hist = @{}
if (Test-Path $histFile) {
    try { (Get-Content $histFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $script:hist[$_.Name] = [int]$_.Value } } catch {}
}

if (-not (Test-Path $aliasFile)) {
    $aliasEntete + @('w = Word', 'x = Excel', 'calc = Calculator', 'note = Notepad') | Set-Content -Encoding UTF8 $aliasFile
}

# Journal : la barre definit Write-Journal ; la fenetre seule n'en a pas
function Write-JournalSiDispo([string]$m) { if (Get-Command Write-Journal -ErrorAction SilentlyContinue) { Write-Journal $m } }

# Recherche en C# : instantanee meme avec des centaines d'applis
if (-not ('LanceurSearch' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Globalization; using System.Collections.Generic;
public static class LanceurSearch {
    public static string Key(string s) {
        var d = (s ?? "").ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (char c in d) if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return sb.ToString();
    }
    static readonly char[] Sep = { ' ', '-', '_', '.', '(', ')' };
    // Correspondances fortes (>= 200) : le nom, un de ses mots ou ses initiales commencent comme le texte.
    // Correspondances faibles (< 200) : utilisees seulement s'il n'y a aucune forte.
    public static int Score(string n, string q) {
        if (n == q) return 1000;
        if (n.StartsWith(q, StringComparison.Ordinal)) return 800;
        var words = n.Split(Sep, StringSplitOptions.RemoveEmptyEntries);
        if (string.Concat(words).StartsWith(q, StringComparison.Ordinal)) return 700;   // "wifi" -> "Wi-Fi"
        // le texte commence a un mot (plusieurs mots possibles : "hidden files") ; plus le mot est tot, mieux c'est
        for (int p = n.IndexOf(q, StringComparison.Ordinal); p >= 0; p = n.IndexOf(q, p + 1, StringComparison.Ordinal))
            if (p == 0 || Array.IndexOf(Sep, n[p - 1]) >= 0)
                return 600 - 20 * Math.Min(n.Substring(0, p).Split(Sep, StringSplitOptions.RemoveEmptyEntries).Length, 5);
        var ini = new StringBuilder();
        foreach (var w in words) ini.Append(w[0]);
        if (q.Length >= 2 && ini.ToString().StartsWith(q, StringComparison.Ordinal)) return 450;   // "vsc" -> Visual Studio Code
        if (n.IndexOf(q, StringComparison.Ordinal) >= 0) return 150;   // au milieu d'un mot (faible)
        // lettres dans l'ordre (faible), a partir du debut d'un mot : "ntpd" -> Notepad,
        // mais pas "sarv" -> windowS AdministRatiVe Tools (lettres piochees n'importe ou dans un nom long)
        for (int p = 0; p < n.Length; p++) {
            if (n[p] != q[0] || (p > 0 && Array.IndexOf(Sep, n[p - 1]) < 0)) continue;
            int i = 0;
            for (int k = p; k < n.Length && i < q.Length; k++) if (n[k] == q[i]) i++;
            if (i == q.Length) return 100;
        }
        return 0;
    }
    // aliases[i] = alias separes par '|'
    // bonus[i] = decalage de classement selon le type (applis 0, taches du Panneau de configuration negatif...)
    // groups[i] = "" pour un resultat normal, ou un prefixe ("steam", "gog") : ces entrees ne sont cherchees qu'apres lui
    // ("steam dark" cherche "dark" dans les jeux Steam, "steam " les liste tous) ; ailleurs elles ne repondent qu'a leurs alias
    public static int[] Find(string[] keys, string[] aliases, int[] hits, int[] bonus, string[] groups, string text, int max) {
        string grp = "";
        string q = Key((text ?? "").TrimStart());
        foreach (var g in groups)
            if (g.Length > 0 && q.StartsWith(g + " ", StringComparison.Ordinal)) { grp = g; q = q.Substring(g.Length + 1); break; }
        q = q.Trim();
        // Trois niveaux, chacun utilise seulement si le precedent est vide :
        //   1. applis, raccourcis, Panneau de configuration, pages Parametres qui commencent comme le texte
        //   2. taches du Panneau de configuration qui commencent comme le texte (longues et nombreuses)
        //   3. correspondances faibles (milieu de mot, lettres dans l'ordre) sur les applis et raccourcis
        var res = new List<int[]>();
        var tasks = new List<int[]>();
        var weak = new List<int[]>();
        for (int i = 0; i < keys.Length; i++) {
            if (groups[i] != grp && (grp.Length > 0 || q.Length == 0)) continue;
            int s = groups[i] != grp ? 0 : q.Length == 0 ? 1 : Score(keys[i], q);
            if (q.Length > 0 && aliases[i].Length > 0)
                foreach (var a in aliases[i].Split('|')) {
                    if (a == q) s = Math.Max(s, 2000);
                    else if (a.StartsWith(q, StringComparison.Ordinal)) s = Math.Max(s, 900);
                }
            if (s <= 0) continue;
            var r = new[] { i, Math.Max(1, s + bonus[i]) + Math.Min(300, 25 * hits[i]) };
            if (q.Length == 0) { res.Add(r); continue; }
            if (s < 200) { if (bonus[i] == 0) weak.Add(r); }
            else if (bonus[i] <= -200) tasks.Add(r);
            else res.Add(r);
        }
        if (res.Count == 0) res = tasks.Count > 0 ? tasks : weak;
        // meilleur score d'abord, puis le nom le plus court (Excel avant Exceed Share)
        // (une liste complete, "steam ", est alphabetique)
        res.Sort((x, y) => y[1] != x[1] ? y[1].CompareTo(x[1])
                         : q.Length > 0 && keys[x[0]].Length != keys[y[0]].Length ? keys[x[0]].Length.CompareTo(keys[y[0]].Length)
                         : string.CompareOrdinal(keys[x[0]], keys[y[0]]));
        var o = new int[Math.Min(max, res.Count)];
        for (int i = 0; i < o.Length; i++) o[i] = res[i][0];
        return o;
    }
}
'@
}

function ConvertTo-Key([string]$s) { [LanceurSearch]::Key($s) }

# Types de resultats (petite etiquette grise a cote de ce qui n'est pas une appli) et decalage de classement :
# a qualite egale, les applis d'abord, les taches du Panneau de configuration (longues, nombreuses) en dernier.
$typeBonus = @{ 'Appli' = 0; 'Raccourci' = 0; 'Commande' = 0; 'Action' = -50; 'Panneau de config.' = -50; 'Parametres' = -50; 'Tache' = -250 }
# Jeux : type -> prefixe de recherche (ils ne sortent qu'apres "steam " / "gog ", ou par un alias)
$groupesJeux = @{ 'Steam' = 'steam'; 'GOG' = 'gog' }
$iconePanneau    = '::{26EE0668-A00A-44D7-9371-BEB064C98683}'
$iconeParametres = 'shell:AppsFolder\windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel'

# Pages courantes des Parametres (Windows n'a pas d'API pour les lister) : nom = page ms-settings
# Noms en anglais comme l'interface de Windows ; apres le | : mots francais qui les trouvent aussi.
$pagesParametres = [ordered]@{
    'Display|affichage ecran' = 'display'; 'Night light|eclairage nocturne' = 'nightlight'; 'Sound|son' = 'sound'
    'Notifications|' = 'notifications'; 'Focus assist|concentration' = 'quiethours'; 'Power & sleep|alimentation veille' = 'powersleep'
    'Storage|stockage' = 'storagesense'; 'Multitasking|multitache' = 'multitasking'; 'Clipboard|presse-papiers' = 'clipboard'
    'Remote Desktop|bureau a distance' = 'remotedesktop'; 'About this PC|a propos' = 'about'
    'Bluetooth & other devices|peripheriques' = 'bluetooth'; 'Printers & scanners|imprimantes' = 'printers'; 'Mouse|souris' = 'mousetouchpad'
    'Typing|saisie clavier' = 'typing'; 'AutoPlay|execution automatique' = 'autoplay'; 'Network status|reseau' = 'network-status'
    'Wi-Fi|' = 'network-wifi'; 'Ethernet|' = 'network-ethernet'; 'VPN|' = 'network-vpn'; 'Proxy|' = 'network-proxy'
    'Background|arriere-plan fond' = 'personalization-background'; 'Colors|couleurs' = 'colors'; 'Lock screen|ecran verrouillage' = 'lockscreen'
    'Themes|' = 'themes'; 'Fonts|polices' = 'fonts'; 'Start menu settings|menu demarrer' = 'personalization-start'
    'Taskbar settings|barre des taches' = 'taskbar'; 'Apps & features|applications desinstaller' = 'appsfeatures'
    'Default apps|applications par defaut' = 'defaultapps'; 'Startup apps|demarrage' = 'startupapps'
    'Your info|mes infos compte' = 'yourinfo'; 'Sign-in options|connexion' = 'signinoptions'; 'Date & time|date heure' = 'dateandtime'
    'Region|' = 'regionformatting'; 'Language|langue' = 'regionlanguage'; 'Speech|voix' = 'speech'
    'Game Mode|mode jeu' = 'gaming-gamemode'; 'Xbox Game Bar|' = 'gaming-gamebar'
    'Keyboard accessibility|clavier' = 'easeofaccess-keyboard'; 'Mouse pointer|pointeur' = 'easeofaccess-mousepointer'
    'Text size|taille du texte' = 'easeofaccess-display'; 'Privacy|confidentialite' = 'privacy'
    'Microphone privacy|micro' = 'privacy-microphone'; 'Camera privacy|camera webcam' = 'privacy-webcam'
    'Location privacy|localisation' = 'privacy-location'; 'Windows Update|mise a jour' = 'windowsupdate'
    'Windows Security|securite antivirus' = 'windowsdefender'; 'Backup|sauvegarde' = 'backup'; 'Troubleshoot|depannage' = 'troubleshoot'
    'Recovery|recuperation' = 'recovery'; 'Activation|' = 'activation'; 'For developers|developpeurs' = 'developers'
}

function New-Entree($name, $id, $type, $target = $null, $iconPath = $null, $shell = $null) {
    [pscustomobject]@{ Name = $name; Id = $id; Type = $type; Target = $target; IconPath = $iconPath; Shell = $shell; Key = (ConvertTo-Key $name); Aliases = @(); Idx = 0 }
}

# ---- Actions integrees ----
# Id -> noms qui les trouvent (francais et anglais), icone ("fichier.dll,index" ou element shell), ce qu'elle fait.
# Celles qui ferment tes applis ou suppriment des fichiers demandent d'abord (Oui par defaut : Entree confirme).
$sys = Join-Path $env:WINDIR 'System32'
$actions = [ordered]@{
    'action:corbeille'   = @{ Noms = @('Vider la corbeille', 'Empty Recycle Bin'); Icone = '::{645FF040-5081-101B-9F08-00AA002F954E}'; Faire = { Invoke-ViderCorbeille } }
    'action:arreter'     = @{ Noms = @('Arrêter le PC', 'Éteindre', 'Shut down'); Icone = "$sys\shell32.dll,27"
        Faire = { if (Confirm-Action 'Arrêter' "Arrêter le PC maintenant ?") { shutdown.exe /s /t 0 } } }
    'action:redemarrer'  = @{ Noms = @('Redémarrer', 'Restart', 'Reboot'); Icone = "$sys\imageres.dll,228"
        Faire = { if (Confirm-Action 'Redémarrer' "Redémarrer le PC maintenant ?") { shutdown.exe /r /t 0 } } }
    'action:deconnecter' = @{ Noms = @('Se déconnecter', 'Sign out', 'Log off'); Icone = "$sys\shell32.dll,176"
        Faire = { if (Confirm-Action 'Se déconnecter' "Fermer ta session Windows maintenant ?") { shutdown.exe /l } } }
    'action:veille'      = @{ Noms = @('Mettre en veille', 'Veille', 'Sleep'); Icone = "$sys\imageres.dll,96"
        Faire = { [void][Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) } }
    'action:verrouiller' = @{ Noms = @('Verrouiller', 'Lock'); Icone = "$sys\imageres.dll,54"
        Faire = { Start-Process rundll32.exe -ArgumentList 'user32.dll,LockWorkStation' } }
}
function Get-ActionEntrees { foreach ($id in $actions.Keys) { foreach ($n in $actions[$id].Noms) { New-Entree $n $id 'Action' $null $actions[$id].Icone } } }
# Question Oui / Non, Oui par defaut (Entree confirme)
function Confirm-Action([string]$titre, [string]$question) { [Windows.Forms.MessageBox]::Show($question, $titre, 'YesNo', 'Warning', 'Button1') -eq 'Yes' }
# Demande toujours (la confirmation de Windows peut etre desactivee), puis vide la corbeille
function Invoke-ViderCorbeille {
    $n = (New-Object -ComObject Shell.Application).Namespace(10).Items().Count
    if (-not $n) { [void][Windows.Forms.MessageBox]::Show('La corbeille est déjà vide.', 'Corbeille', 'OK', 'Information'); return }
    if (-not (Confirm-Action 'Vider la corbeille' "Supprimer définitivement $n élément$(if ($n -gt 1) { 's' }) de la corbeille ?")) { return }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

# ---- Jeux Steam et GOG ----
function Get-SteamDossier { $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath; if ($p) { $p -replace '/', '\' } }
# Dossier steamapps de chaque bibliotheque Steam (autres disques compris)
function Get-SteamBibliotheques {
    $steam = Get-SteamDossier; if (-not $steam) { return }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) { $libs += [regex]::Matches((Get-Content -LiteralPath $vdf -Raw -Encoding UTF8), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } }
    # [IO.Path]::Combine : une bibliotheque sur un disque absent (cle USB, ancien disque) est simplement ignoree
    $libs | ForEach-Object { [IO.Path]::Combine($_, 'steamapps') } | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue } | Sort-Object -Unique
}
# Jeux Steam installes (pas les runtimes de Steam) : appid -> nom
function Get-SteamJeux {
    $res = [ordered]@{}
    foreach ($dir in Get-SteamBibliotheques) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
            $id = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value; $nom = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value
            $etat = [int][regex]::Match($t, '"StateFlags"\s+"(\d+)"').Groups[1].Value
            if ($id -and $nom -and ($etat -band 4) -and $nom -notmatch '^(Steamworks|Proton|Steam Linux Runtime)' -and -not $res.Contains($id)) { $res[$id] = $nom }
        }
    }
    $res
}
# Steam garde la petite icone de chaque jeu en jpg 32x32 (sinon : l'icone de Steam)
function Get-SteamIcone([string]$steam, [string]$id) {
    $i = Get-ChildItem -LiteralPath (Join-Path $steam "appcache\librarycache\$id") -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9a-f]{40}\.jpg$' } | Select-Object -First 1
    if ($i) { $i.FullName } else { Join-Path $steam 'steam.exe' }
}
# Jeux GOG installes : inscrits dans le registre par leur installeur (seulement si le jeu est bien la). Lu via .NET : ~1 ms.
function Get-GogJeux {
    foreach ($root in 'SOFTWARE\WOW6432Node\GOG.com\Games', 'SOFTWARE\GOG.com\Games') {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($root); if (-not $k) { continue }
        foreach ($n in $k.GetSubKeyNames()) {
            $g = $k.OpenSubKey($n); if (-not $g) { continue }
            $nom = $g.GetValue('gameName'); $exe = $g.GetValue('exe'); $id = $g.GetValue('gameID'); $g.Close()
            if ($nom -and $exe -and [IO.File]::Exists($exe)) { [pscustomobject]@{ Nom = $nom; Id = $(if ($id) { $id } else { $n }); Exe = $exe } }
        }
        $k.Close()
    }
}
function Get-JeuxEntrees {
    $steam = Get-SteamDossier; $jeux = Get-SteamJeux
    foreach ($id in $jeux.Keys) { New-Entree $jeux[$id] "steam:$id" 'Steam' "steam://rungameid/$id" (Get-SteamIcone $steam $id) }
    foreach ($g in @(Get-GogJeux)) { New-Entree $g.Nom "gog:$($g.Id)" 'GOG' $g.Exe }
}
# Change quand un jeu est installe ou desinstalle (rapide : dates des dossiers steamapps + liste GOG)
function Get-JeuxStamp {
    $steam = @(foreach ($d in @(Get-SteamBibliotheques)) { [string](Get-Item -LiteralPath $d).LastWriteTimeUtc.Ticks })
    $gog = @(foreach ($g in @(Get-GogJeux)) { [string]$g.Id })
    ($steam + $gog) -join ','
}

function Import-Apps {
    # Raccourcis perso : nom = nom du fichier sans extension ("Compta.lnk" -> "Compta")
    # Dans un sous-dossier ("raccourcis\Brave\Banque.url") : etiquette = nom du sous-dossier, qui fait partie de la recherche
    $racc = @(foreach ($f in Get-Raccourcis) {
        $rel = $f.FullName.Substring($raccourcisDir.Length).TrimStart('\')
        $dossier = if ($rel.Contains('\')) { $rel.Split('\')[0] } else { $null }
        $e = New-Entree $f.BaseName $f.FullName $(if ($dossier) { $dossier } else { 'Raccourci' }) $f.FullName
        if ($dossier) { $e.Key = ConvertTo-Key "$($f.BaseName) $dossier" }
        $e
    })
    # Un raccourci qui porte le nom d'une appli la remplace (ex. "Google Calendar.lnk" qui ouvre directement Tasks) :
    # il s'affiche comme l'appli et en reprend le nombre de lancements
    $propres = @{}; foreach ($r in $racc) { $propres[(ConvertTo-Key $r.Name)] = $r }
    $list = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique | ForEach-Object {
        $mien = $propres[(ConvertTo-Key $_.Name)]
        if ($mien) {
            $mien.Type = 'Appli'; $mien.Key = ConvertTo-Key $mien.Name
            if (-not $script:hist[$mien.Id] -and $script:hist[$_.AppID]) { $script:hist[$mien.Id] = $script:hist[$_.AppID] }
            return
        }
        # Applis web installees depuis un navigateur ("Brave._crx_...", "Chrome._crx_...") : etiquette = le navigateur,
        # et le nom du navigateur fait partie de la recherche ("brave" les liste toutes)
        if ($_.AppID -match '^(Brave|Chrome|Chromium|MSEdge|Edge|Vivaldi|Opera)[^.]*\._crx_') {
            $nav = @{ 'msedge' = 'Edge' }[$Matches[1].ToLower()]; if (-not $nav) { $nav = $Matches[1] }
            $e = New-Entree $_.Name $_.AppID $nav
            $e.Key = ConvertTo-Key "$($_.Name) $nav"
            $e
        } else { New-Entree $_.Name $_.AppID 'Appli' }
    })
    $list += $racc
    $pris = @{}; foreach ($a in $list) { $pris[(ConvertTo-Key $a.Name)] = $true }
    # Actions integrees (Arreter, Redemarrer, Veille, Vider la corbeille...)
    $list += @(Get-ActionEntrees)
    # Elements (Options d'indexation, Options d'alimentation...) et taches ("Change how your mouse works"...)
    # du Panneau de configuration, comme la recherche Windows. Ouverts via leur element shell (thread STA requis : c'est le cas).
    try {
        $sh = New-Object -ComObject Shell.Application
        foreach ($src in @(@("shell:$iconePanneau\0", 'Panneau de config.'), @('shell:::{ED7BA470-8E54-465E-825C-99712043E01C}', 'Tache'))) {
            $ns = $sh.Namespace($src[0]); if (-not $ns) { continue }
            foreach ($it in $ns.Items()) {
                $k = ConvertTo-Key $it.Name
                if (-not $it.Name -or $pris[$k]) { continue }   # pas de doublon avec une appli du menu Demarrer
                $pris[$k] = $true
                $icon = if ($src[1] -eq 'Panneau de config.') { $it.Path } else { $iconePanneau }
                $list += New-Entree $it.Name $it.Path $src[1] $null $icon $it
            }
        }
    } catch { Write-JournalSiDispo "Panneau de configuration illisible : $($_.Exception.Message)" }
    foreach ($p in $pagesParametres.GetEnumerator()) {
        $nom, $fr = $p.Key -split '\|', 2
        $k = ConvertTo-Key $nom
        if ($pris[$k]) {
            # Deja present (ex. "Sound" du Panneau de configuration) : il recoit les mots francais
            if ($fr) { foreach ($x in $list) { if ($x.Key -eq $k) { $x.Key = ConvertTo-Key "$nom $fr"; break } } }
            continue
        }
        $e = New-Entree $nom "ms-settings:$($p.Value)" 'Parametres' "ms-settings:$($p.Value)" $iconeParametres
        if ($fr) { $e.Key = ConvertTo-Key "$nom $fr" }   # "son" trouve aussi "Sound"
        $list += $e
    }
    # Jeux Steam et GOG installes (cherches seulement apres "steam " / "gog ")
    try { $list += @(Get-JeuxEntrees); $script:jeuxStamp = Get-JeuxStamp }
    catch { Write-JournalSiDispo "Jeux non charges : $($_.Exception.Message)" }
    $script:baseApps = $list   # liste sans les alias : Update-Aliases la reprend en quelques ms
    $script:appsLoadedAt = Get-Date
    $script:raccourcisStamp = Get-RaccourcisStamp
    $script:menuStamp = Get-MenuDemarrerStamp
    Update-Aliases
}

# ---- Alias ----
# Lit alias.txt : liste de { Alias ; Cible } dans l'ordre du fichier
function Get-AliasPairs {
    $res = New-Object Collections.ArrayList
    foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
        [void]$res.Add([pscustomobject]@{ Alias = $Matches[1]; Cible = $Matches[2] })
    }
    , $res
}

# Ecrit alias.txt (un alias par cle : le dernier gagne) et applique les alias tout de suite
function Save-AliasPairs($pairs) {
    $vus = @{}; $out = New-Object Collections.ArrayList
    for ($i = $pairs.Count - 1; $i -ge 0; $i--) {
        $p = $pairs[$i]; $a = "$($p.Alias)".Trim(); $c = "$($p.Cible)".Trim(); $k = ConvertTo-Key $a
        if (-not $a -or -not $c -or $a.Contains('=') -or $vus[$k]) { continue }
        $vus[$k] = $true; $out.Insert(0, "$a = $c")
    }
    @($aliasEntete) + @($out) | Set-Content -Encoding UTF8 $aliasFile
    Update-Aliases
}

# Entree vers laquelle pointe une cible : nom exact d'une appli, debut de nom, sinon $null (chemin, URL, commande)
function Resolve-Cible([string]$cible, $list = $script:baseApps, $parNom = $script:parNom) {
    $cible = $cible.Trim(); if (-not $cible) { return $null }
    if ($parNom -and $parNom.ContainsKey($cible)) { return $parNom[$cible] }
    if ($cible -match '[\\/:.]') { return $null }
    $best = $null
    $kc = ConvertTo-Key $cible   # debut de nom : applis, raccourcis, pages Parametres, jeux, actions (pas les commandes)
    foreach ($a in $list) { if ($a.Type -ne 'Commande' -and $a.Key.StartsWith($kc, [StringComparison]::Ordinal) -and (-not $best -or $a.Name.Length -lt $best.Name.Length)) { $best = $a } }
    $best
}

# Nom lisible d'un site vise par une cible (URL, ou navigateur suivi d'une URL) : www.youtube.com -> YouTube,
# gemini.google.com -> Gemini, www.allkeyshop.com -> Allkeyshop. $null si la cible n'est pas un site.
$nomsConnus = @{ 'youtube' = 'YouTube'; 'github' = 'GitHub'; 'chatgpt' = 'ChatGPT'; 'linkedin' = 'LinkedIn'; 'deepseek' = 'DeepSeek'; 'allkeyshop' = 'AllKeyShop'
                 'acck' = 'AcckCloud'; 'proxy-cheap' = 'Proxy-Cheap'; 'torrentbay' = 'TorrentBay' }
# Sous-domaines sans interet pour le nom : app.proxy-cheap.com -> Proxy-Cheap, pas "App"
$sousDomainesGeneriques = 'www', 'm', 'app', 'apps', 'my', 'web', 'portal', 'dashboard', 'account', 'accounts', 'login', 'auth', 'secure', 'client', 'clients', 'extranet', 'members'
function Get-NomSite([string]$cible) {
    $prog, $arg = Split-Commande $cible
    $u = if ($prog -match '^https?://') { $prog } elseif ($arg -match '^(https?://\S+)') { $Matches[1] } else { return $null }
    try { $h = ([uri]$u).Host -replace '^www\d*\.', '' } catch { return $null }
    $parts = @($h -split '\.' | Where-Object { $_ })
    $i = 0; while ($i -lt $parts.Count - 2 -and $parts[$i] -in $sousDomainesGeneriques) { $i++ }
    $mot = $parts[$i]; if (-not $mot) { return $null }
    if ($nomsConnus[$mot]) { return $nomsConnus[$mot] }
    $mot.Substring(0, 1).ToUpper() + $mot.Substring(1)
}

# Applique alias.txt a la liste des applis deja chargee (sans relire le menu Demarrer ni le Panneau de configuration)
function Update-Aliases {
    $list = New-Object Collections.ArrayList
    $parNom = @{}
    foreach ($a in $script:baseApps) { $a.Aliases = @(); [void]$list.Add($a); if (-not $parNom.ContainsKey($a.Name)) { $parNom[$a.Name] = $a } }
    $script:parNom = $parNom
    foreach ($p in (Get-AliasPairs)) {
        $app = Resolve-Cible $p.Cible $script:baseApps $parNom
        if (-not $app) {
            if ($parNom.ContainsKey($p.Cible)) { $app = $parNom[$p.Cible] }
            else {
                # Un site s'affiche sous son nom ("YouTube"), pas sous son adresse ni le chemin du navigateur
                $nom = Get-NomSite $p.Cible; if (-not $nom) { $nom = $p.Cible }
                $app = New-Entree $nom $p.Cible $(if ($nom -ne $p.Cible) { 'Site' } else { 'Commande' }) $p.Cible
                [void]$list.Add($app); $parNom[$p.Cible] = $app
            }
        }
        $app.Aliases += (ConvertTo-Key $p.Alias)
    }
    # Tableaux pour la recherche C# (boucles simples : ~10x plus rapide que des pipelines sur 600 entrees)
    $n = $list.Count
    $keys = New-Object string[] $n; $al = New-Object string[] $n; $hits = New-Object int[] $n; $bonus = New-Object int[] $n; $grp = New-Object string[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $a = $list[$i]; $a.Idx = $i
        $keys[$i] = $a.Key; $al[$i] = $a.Aliases -join '|'; $hits[$i] = [int]$script:hist[$a.Id]; $bonus[$i] = [int]$typeBonus[$a.Type]; $grp[$i] = [string]$groupesJeux[$a.Type]
    }
    $script:apps = $list; $script:keys = $keys; $script:aliasArr = $al; $script:hits = $hits; $script:bonus = $bonus; $script:groups = $grp
    $script:aliasStamp = (Get-Item $aliasFile).LastWriteTime
}

# Change quand une appli de bureau ou une appli web (Chrome, Edge) est ajoutee ou retiree du menu Demarrer
$dossiersDemarrer = @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'))
function Get-MenuDemarrerStamp {
    (@(foreach ($d in $dossiersDemarrer) { Get-Item -LiteralPath $d -ErrorAction SilentlyContinue; Get-ChildItem -LiteralPath $d -Directory -Recurse -ErrorAction SilentlyContinue }) |
        ForEach-Object { $_.LastWriteTimeUtc.Ticks } | Measure-Object -Maximum).Maximum
}

# Recharge seulement si alias.txt, le dossier raccourcis ou le menu Demarrer a change
# (la liste complete, applis du Store comprises, est aussi rafraichie toutes les 30 min par la barre)
function Update-AppsIfStale {
    if ((Get-RaccourcisStamp) -ne $script:raccourcisStamp -or (Get-MenuDemarrerStamp) -ne $script:menuStamp -or (Get-JeuxStamp) -ne $script:jeuxStamp) { Import-Apps }
    elseif ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasStamp) { Update-Aliases }   # alias seuls : instantane
}

# Toujours entourer le resultat de @(...) : avec un seul resultat, PowerShell 5.1 renvoie l'objet seul
function Find-Apps([string]$text, [int]$max = 15) {
    $idx = [LanceurSearch]::Find($script:keys, $script:aliasArr, $script:hits, $script:bonus, $script:groups, $text, $max)
    @(foreach ($i in $idx) { $script:apps[$i] })
}

function Get-AppLabel($a) {
    if ($a.Aliases.Count) { return $a.Name + '    [' + ($a.Aliases -join ', ') + ']' }
    $a.Name
}

# Lance l'appli (ou, si $app est vide, le texte tape : chemin, URL, commande). Renvoie $true si OK.
# Cible -> programme et arguments. Un chemin qui existe, une URL ou un lien (ms-settings:...) reste entier ;
# sinon : programme puis arguments, par exemple  "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" https://www.youtube.com
function Split-Commande([string]$cible) {
    $x = [Environment]::ExpandEnvironmentVariables($cible.Trim())
    if ((Test-Path -LiteralPath $x -ErrorAction SilentlyContinue) -or ($x -match '^[a-z][a-z0-9+.-]*:' -and $x -notmatch '^[a-z]:\\')) { return @($x, '') }
    if ($x -match '^"([^"]+)"\s*(.*)$') { return @($Matches[1], $Matches[2].Trim()) }
    if ($x -match '^(\S+)\s+(.+)$') { return @($Matches[1], $Matches[2].Trim()) }
    @($x, '')
}
# Lance une cible (chemin, URL, ou programme avec arguments)
function Start-Cible([string]$cible) {
    $prog, $args2 = Split-Commande $cible
    if ($args2) { Start-Process -FilePath $prog -ArgumentList $args2 } else { Start-Process -FilePath $prog }
}

function Invoke-Launch($app, [string]$text) {
    $text = $text.Trim()
    try {
        if ($text -eq ':alias') { Show-AliasManager; return $true }
        if ($app) {
            Write-JournalSiDispo "Lancement : $($app.Name) [$($app.Type) $($app.Id)]"
            if ($app.Type -eq 'Action') { & $actions[$app.Id].Faire }                              # action integree
            elseif ($app.Shell) { $app.Shell.InvokeVerb() }                                              # Panneau de configuration
            elseif ($app.Type -eq 'Parametres') { [void][Diagnostics.Process]::Start($app.Target) }   # page ms-settings:
            elseif ($app.Target) { Start-Cible $app.Target }
            else { Start-Process explorer.exe "shell:AppsFolder\$($app.Id)" }
            $script:hist[$app.Id] = [int]$script:hist[$app.Id] + 1
            $script:hits[$app.Idx] = $script:hist[$app.Id]
            try { $script:hist | ConvertTo-Json | Set-Content -Encoding UTF8 $histFile } catch {}
            return $true
        }
        if ($text) { Write-JournalSiDispo "Lancement : $text"; Start-Process $text; return $true }
    } catch {
        Write-JournalSiDispo "Echec du lancement : $(if ($app) { "$($app.Name) [$($app.Id)]" } else { $text }) : $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show("Impossible de lancer : $(if ($app) { $app.Name } else { $text })", 'Lanceur') | Out-Null
    }
    $false
}

# Ajoute (ou remplace) un alias dans alias.txt
function Add-Alias([string]$alias, [string]$cible) {
    $alias = $alias.Trim(); $cible = $cible.Trim()
    if (-not $alias -or -not $cible) { return }
    $pairs = Get-AliasPairs
    [void]$pairs.Add([pscustomobject]@{ Alias = $alias; Cible = $cible })
    Save-AliasPairs $pairs
}

# ---- Fenetre des alias (reprise du systeme de basedhound, en francais) ----
# Ajouter en haut ; double-clic (ou F2) sur un alias ou une cible pour le modifier sur place ; la croix (ou Suppr) supprime.
# Tout est enregistre aussitot. La barre reste utilisable pendant que la fenetre est ouverte : on essaie l'alias tout de suite.
# Les gestionnaires d'evenements tournent pendant ShowDialog : ils voient les variables de Show-AliasManager ($f, $grid...).

$aliasCouleurs = @{
    Fond = [Drawing.Color]::FromArgb(32, 32, 32); Champ = [Drawing.Color]::FromArgb(45, 45, 45); ChampSurvol = [Drawing.Color]::FromArgb(58, 58, 58)
    Accent = [Drawing.Color]::FromArgb(60, 90, 140); AccentSurvol = [Drawing.Color]::FromArgb(76, 110, 166)
    Ligne = [Drawing.Color]::FromArgb(52, 52, 52); LigneSel = [Drawing.Color]::FromArgb(42, 46, 54)
    Texte = [Drawing.Color]::FromArgb(232, 232, 232); Discret = [Drawing.Color]::FromArgb(150, 150, 150)
    Alias = [Drawing.Color]::FromArgb(140, 180, 245); Suppr = [Drawing.Color]::FromArgb(232, 80, 90); Attention = [Drawing.Color]::FromArgb(230, 180, 90)
}
$aliasPolice = New-Object Drawing.Font('Segoe UI', 10)
$aliasVide   = New-Object Drawing.Bitmap(1, 1)   # case d'icone vide
$aliasCroix  = [string][char]0x2715

function Get-AliasEchelle { $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k = $g.DpiX / 96; $g.Dispose(); $k }
function apx([double]$v) { [int]($v * $script:aliasK) }

# Chemin a coins arrondis (rayon r)
function New-CheminArrondi([int]$w, [int]$h, [int]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $p.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $p.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90); $p.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
    $p.CloseFigure(); $p
}
$aliasArrondir = {
    $r = apx 6
    if ($this.Width -lt $r * 2 -or $this.Height -lt $r * 2) { return }
    $this.Region = New-Object Drawing.Region (New-CheminArrondi $this.Width $this.Height $r)
}

# ---- Briques ----
function New-AliasBouton([string]$texte, $fond, $survol) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $texte; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $fond; $b.FlatAppearance.MouseOverBackColor = $survol; $b.FlatAppearance.MouseDownBackColor = $survol
    $b.ForeColor = [Drawing.Color]::White; $b.Cursor = 'Hand'; $b.Add_Resize($aliasArrondir)
    $b
}
# Champ : zone de texte sans bordure dans un panneau arrondi, centree verticalement
function New-AliasChamp {
    $p = New-Object Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.BackColor = $aliasCouleurs.Champ; $p.Margin = New-Object Windows.Forms.Padding(0, 0, (apx 8), 0); $p.Cursor = 'IBeam'
    $t = New-Object Windows.Forms.TextBox
    $t.BorderStyle = 'None'; $t.BackColor = $aliasCouleurs.Champ; $t.ForeColor = $aliasCouleurs.Texte; $t.Font = $aliasPolice
    $p.Controls.Add($t)
    $p.Add_Resize({ $tb = $this.Controls[0]; $tb.SetBounds((apx 10), [int](($this.Height - $tb.Height) / 2), $this.Width - (apx 20), $tb.Height) })
    $p.Add_Resize($aliasArrondir)
    $p.Add_Click({ $this.Controls[0].Focus() })
    $p
}
function New-AliasEntete {
    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = apx 82; $head.Padding = New-Object Windows.Forms.Padding((apx 20), (apx 16), (apx 20), 0)
    $sous = New-Object Windows.Forms.Label
    $sous.Dock = 'Top'; $sous.Height = apx 24; $sous.ForeColor = $aliasCouleurs.Discret; $sous.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $sous.Text = 'Tape un alias dans la barre pour ouvrir sa cible : une appli, un dossier, une URL ou une commande.'
    $titre = New-Object Windows.Forms.Label
    $titre.Dock = 'Top'; $titre.Height = apx 34; $titre.Text = 'Alias'; $titre.ForeColor = [Drawing.Color]::White
    $titre.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
    $head.Controls.AddRange(@($sous, $titre))
    $head
}
# Ligne d'ajout : [alias] [cible] [Ajouter]
function New-AliasLigneAjout {
    $row = New-Object Windows.Forms.TableLayoutPanel
    $row.Dock = 'Top'; $row.Height = apx 58; $row.Padding = New-Object Windows.Forms.Padding((apx 20), (apx 8), (apx 20), (apx 10))
    $row.ColumnCount = 3; $row.RowCount = 1
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 30)))
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 70)))
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (apx 96))))
    [void]$row.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $chAlias = New-AliasChamp; $chCible = New-AliasChamp
    $btn = New-AliasBouton 'Ajouter' $aliasCouleurs.Accent $aliasCouleurs.AccentSurvol
    $btn.Dock = 'Fill'; $btn.Margin = New-Object Windows.Forms.Padding(0)
    $row.Controls.Add($chAlias, 0, 0); $row.Controls.Add($chCible, 1, 0); $row.Controls.Add($btn, 2, 0)
    @{ Panel = $row; Alias = $chAlias.Controls[0]; Cible = $chCible.Controls[0]; Ajouter = $btn }
}
function New-AliasGrille {
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.BackgroundColor = $aliasCouleurs.Fond; $grid.BorderStyle = 'None'; $grid.GridColor = $aliasCouleurs.Ligne
    $grid.CellBorderStyle = 'SingleHorizontal'; $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'
    $grid.EnableHeadersVisualStyles = $false; $grid.ColumnHeadersBorderStyle = 'None'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'; $grid.ColumnHeadersHeight = apx 32
    $grid.RowTemplate.Height = apx 42; $grid.EditMode = 'EditProgrammatically'
    $c = $grid.DefaultCellStyle
    $c.BackColor = $aliasCouleurs.Fond; $c.ForeColor = $aliasCouleurs.Texte; $c.Font = $aliasPolice
    $c.SelectionBackColor = $aliasCouleurs.LigneSel; $c.SelectionForeColor = [Drawing.Color]::White
    $c.Padding = New-Object Windows.Forms.Padding((apx 4), 0, 0, 0)
    $h = $grid.ColumnHeadersDefaultCellStyle
    $h.BackColor = $aliasCouleurs.Fond; $h.ForeColor = $aliasCouleurs.Discret; $h.SelectionBackColor = $aliasCouleurs.Fond
    $h.Font = New-Object Drawing.Font('Segoe UI', 9); $h.Padding = New-Object Windows.Forms.Padding((apx 4), 0, 0, 0)
    # Colonnes : icone, alias, cible, croix
    $icon = New-Object Windows.Forms.DataGridViewImageColumn
    $icon.HeaderText = ''; $icon.AutoSizeMode = 'None'; $icon.Width = apx 46; $icon.ImageLayout = 'Zoom'; $icon.ReadOnly = $true
    $icon.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding((apx 14), (apx 11), (apx 4), (apx 11)); $icon.DefaultCellStyle.NullValue = $aliasVide
    $alias = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $alias.HeaderText = 'ALIAS'; $alias.FillWeight = 30
    $alias.DefaultCellStyle.ForeColor = $aliasCouleurs.Alias; $alias.DefaultCellStyle.SelectionForeColor = $aliasCouleurs.Alias
    $alias.DefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $cible = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $cible.HeaderText = 'CIBLE'; $cible.FillWeight = 70
    $del = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $del.HeaderText = ''; $del.AutoSizeMode = 'None'; $del.Width = apx 46; $del.ReadOnly = $true
    $del.DefaultCellStyle.Alignment = 'MiddleCenter'; $del.DefaultCellStyle.ForeColor = $aliasCouleurs.Discret; $del.DefaultCellStyle.SelectionForeColor = $aliasCouleurs.Discret
    $grid.Columns.AddRange([Windows.Forms.DataGridViewColumn[]]@($icon, $alias, $cible, $del))
    foreach ($col in $grid.Columns) { $col.SortMode = 'NotSortable'; $col.Resizable = 'False' }
    $grid
}
function New-AliasMessageVide {
    $l = New-Object Windows.Forms.Label
    $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.ForeColor = $aliasCouleurs.Discret; $l.BackColor = $aliasCouleurs.Fond
    $l.Text = "Aucun alias pour l'instant.`nAjoute-en un ci-dessus, par exemple  ch  " + [char]0x2192 + "  Google Chrome."
    $l
}
# Pied : "Ouvrir alias.txt" a gauche, Termine a droite
function New-AliasPied {
    $foot = New-Object Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = apx 60; $foot.Padding = New-Object Windows.Forms.Padding((apx 20), (apx 12), (apx 20), (apx 14))
    $fini = New-AliasBouton 'Terminé' $aliasCouleurs.Champ $aliasCouleurs.ChampSurvol
    $fini.Dock = 'Right'; $fini.Width = apx 96
    $ouvrir = New-Object Windows.Forms.LinkLabel
    $ouvrir.Dock = 'Left'; $ouvrir.AutoSize = $false; $ouvrir.Width = apx 200; $ouvrir.TextAlign = 'MiddleLeft'; $ouvrir.Text = 'Ouvrir alias.txt'
    $ouvrir.LinkColor = $aliasCouleurs.Discret; $ouvrir.ActiveLinkColor = [Drawing.Color]::White; $ouvrir.LinkBehavior = 'HoverUnderline'
    $foot.Controls.AddRange(@($fini, $ouvrir))
    @{ Panel = $foot; Fini = $fini; Ouvrir = $ouvrir }
}

# ---- Comportement ----
# Icone d'un alias : celle de l'appli, du dossier, du fichier ou du programme qu'il ouvre
function Get-AliasIcone([string]$alias) {
    if (-not (Get-Command Get-AppIcon -ErrorAction SilentlyContinue)) { return $aliasVide }
    $k = ConvertTo-Key $alias
    foreach ($a in $script:apps) { if ($a.Aliases -contains $k) { $img = Get-AppIcon $a; if ($img) { return $img } else { break } } }
    $aliasVide
}
# Cible introuvable (ni appli, ni chemin, ni URL, ni programme) : en orange
function Test-AliasCible([string]$c) {
    $a = Resolve-Cible $c; if ($a -and $a.Type -ne 'Commande') { return $true }
    $x = [Environment]::ExpandEnvironmentVariables($c.Trim())
    if ($x -match '^[a-z][a-z0-9+.-]*:' -and $x -notmatch '^[a-z]:\\') { return $true }   # URL, ms-settings:, mailto:...
    if ($x -match '^www\.') { return $true }
    if (Test-Path -LiteralPath $x -ErrorAction SilentlyContinue) { return $true }
    $prog = (Split-Commande $c)[0]
    (Test-Path -LiteralPath $prog -ErrorAction SilentlyContinue) -or [bool](Get-Command $prog -CommandType Application -ErrorAction SilentlyContinue)
}
function Set-AliasLigneEtat($r) {
    $ok = Test-AliasCible "$($r.Cells[2].Value)"
    $col = if ($ok) { $aliasCouleurs.Texte } else { $aliasCouleurs.Attention }
    $r.Cells[2].Style.ForeColor = $col; $r.Cells[2].Style.SelectionForeColor = $col
    $r.Cells[2].ToolTipText = if ($ok) { '' } else { 'Cible introuvable : ni appli, ni dossier, ni fichier, ni URL, ni programme' }
}
function Import-AliasGrille {
    $grid.Rows.Clear()
    foreach ($p in (Get-AliasPairs)) { $i = $grid.Rows.Add((Get-AliasIcone $p.Alias), $p.Alias, $p.Cible, $aliasCroix); Set-AliasLigneEtat $grid.Rows[$i] }
    $grid.ClearSelection(); $vide.Visible = $grid.Rows.Count -eq 0
    $script:aliasFenStamp = (Get-Item $aliasFile).LastWriteTime
}
# Enregistre la grille dans alias.txt et applique les alias tout de suite (~30 ms, sans relire le menu Demarrer)
function Save-AliasGrille {
    $pairs = New-Object Collections.ArrayList
    foreach ($r in $grid.Rows) { [void]$pairs.Add([pscustomobject]@{ Alias = "$($r.Cells[1].Value)"; Cible = "$($r.Cells[2].Value)" }) }
    Save-AliasPairs $pairs
    foreach ($r in $grid.Rows) { $r.Cells[0].Value = Get-AliasIcone "$($r.Cells[1].Value)"; Set-AliasLigneEtat $r }
    $vide.Visible = $grid.Rows.Count -eq 0
    $script:aliasFenStamp = (Get-Item $aliasFile).LastWriteTime
}
# L'alias tape en haut : ajoute (remplace un alias du meme nom), puis selectionne
function Add-AliasLigne {
    $a = $aliasBox.Text.Trim(); $t = $cibleBox.Text.Trim()
    if (-not $a) { $aliasBox.Focus(); return }
    if ($a.Contains('=')) { $aliasBox.SelectAll(); $aliasBox.Focus(); return }
    if (-not $t) { $cibleBox.Focus(); return }
    $k = ConvertTo-Key $a
    foreach ($r in @($grid.Rows)) { if ((ConvertTo-Key "$($r.Cells[1].Value)") -eq $k) { $grid.Rows.Remove($r) } }
    $i = $grid.Rows.Add($aliasVide, $a, $t, $aliasCroix)
    Save-AliasGrille
    $aliasBox.Text = ''; $cibleBox.Text = ''; $aliasBox.Focus()
    $grid.ClearSelection(); $grid.Rows[$i].Selected = $true; $grid.FirstDisplayedScrollingRowIndex = $i
}
# Fin de modification : alias ou cible vide = ligne supprimee (juste apres la fin de l'edition), sinon enregistree
function Complete-AliasEdition([int]$row) {
    $r = $grid.Rows[$row]
    if (-not "$($r.Cells[1].Value)".Trim() -or -not "$($r.Cells[2].Value)".Trim()) {
        $script:aliasLigneASupprimer = $r
        $grid.BeginInvoke([Action]{ $grid.Rows.Remove($script:aliasLigneASupprimer); $script:aliasLigneASupprimer = $null; Save-AliasGrille }) | Out-Null
    } else { Save-AliasGrille }
}
# Colonne croix : rouge au survol, supprime au clic
function Set-AliasCroixSurvol([int]$row, [bool]$on) {
    $c = $grid.Rows[$row].Cells[3]
    $col = if ($on) { $aliasCouleurs.Suppr } else { $aliasCouleurs.Discret }
    $c.Style.ForeColor = $col; $c.Style.SelectionForeColor = $col
    $grid.Cursor = if ($on) { 'Hand' } else { 'Default' }
}
# Echap : vide d'abord le champ en cours, ferme la fenetre quand il est vide
function Undo-AliasChamp {
    $tb = $f.ActiveControl -as [Windows.Forms.TextBox]
    if ($tb -and $tb.Text) { $tb.Text = '' } else { $f.Close() }
}
function Register-AliasEvenements {
    $ligne.Ajouter.Add_Click({ Add-AliasLigne })
    $entree = { param($s, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Add-AliasLigne } }
    $aliasBox.Add_KeyDown($entree); $cibleBox.Add_KeyDown($entree)

    $grid.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -in 1, 2) { $grid.BeginEdit($true) } })
    $grid.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -eq 'F2' -and $grid.CurrentCell -and $grid.CurrentCell.ColumnIndex -in 1, 2) { $grid.BeginEdit($true); $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Delete' -and $grid.CurrentRow) { $grid.Rows.Remove($grid.CurrentRow); Save-AliasGrille; $e.Handled = $true }
    })
    $grid.Add_CellEndEdit({ param($s, $e) Complete-AliasEdition $e.RowIndex })
    $grid.Add_EditingControlShowing({ param($s, $e)
        $tb = $e.Control -as [Windows.Forms.TextBox]; if (-not $tb) { return }
        $tb.BackColor = $aliasCouleurs.Champ; $tb.ForeColor = $aliasCouleurs.Texte; $tb.AutoCompleteMode = 'None'
    })
    $grid.Add_CellMouseEnter({ param($s, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { Set-AliasCroixSurvol $e.RowIndex $true } })
    $grid.Add_CellMouseLeave({ param($s, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { Set-AliasCroixSurvol $e.RowIndex $false } })
    $grid.Add_CellClick({ param($s, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { $grid.Rows.RemoveAt($e.RowIndex); $grid.Cursor = 'Default'; Save-AliasGrille } })

    $pied.Ouvrir.Add_LinkClicked({ Start-Process notepad.exe "`"$aliasFile`"" })
    $pied.Fini.Add_Click({ $f.Close() })
    $f.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -ne 'Escape' -or $grid.IsCurrentCellInEditMode) { return }
        $e.SuppressKeyPress = $true
        Undo-AliasChamp
    })
    # alias.txt modifie a la main pendant ce temps : on recharge
    $f.Add_Activated({ if ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasFenStamp) { Update-Aliases; Import-AliasGrille } })
    $f.Add_Shown({
        [void][LanceurCue]::Set($aliasBox.Handle, 'Alias'); [void][LanceurCue]::Set($cibleBox.Handle, 'Appli, dossier, URL ou commande')
        foreach ($c in $grid.Controls) { [LanceurCue]::Sombre($c.Handle) }
        if ($preset) { $cibleBox.Text = $preset }
        $f.Activate(); $aliasBox.Focus()
        # ShowDialog a desactive la barre : on la reactive pour pouvoir essayer un nouvel alias tout de suite
        foreach ($nom in 'bar', 'pop') { $w = Get-Variable -Name $nom -Scope Script -ValueOnly -ErrorAction SilentlyContinue; if ($w -is [Windows.Forms.Form]) { [LanceurCue]::Activer($w.Handle) } }
    })
}

# ---- La fenetre ----
# $preset : nom d'une appli a pre-remplir comme cible
function Show-AliasManager([string]$preset) {
    # Deja ouverte (":alias" retape...) : on la ramene devant au lieu d'en ouvrir une autre
    if ($script:aliasFen -and $script:aliasFen.Visible) {
        if ($preset) { $script:aliasFenCible.Text = $preset; $script:aliasFenAlias.Focus() }
        $script:aliasFen.Activate(); return
    }
    $script:aliasK = Get-AliasEchelle
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Alias'; $f.ShowIcon = $false; $f.KeyPreview = $true
    $f.StartPosition = 'CenterScreen'; $f.AutoScaleMode = 'None'
    $f.Size = New-Object Drawing.Size((apx 640), (apx 560)); $f.MinimumSize = New-Object Drawing.Size((apx 460), (apx 360))
    $f.BackColor = $aliasCouleurs.Fond; $f.ForeColor = $aliasCouleurs.Texte; $f.Font = $aliasPolice
    $ligne = New-AliasLigneAjout
    $aliasBox = $ligne.Alias; $cibleBox = $ligne.Cible
    $grid = New-AliasGrille
    $vide = New-AliasMessageVide
    $hote = New-Object Windows.Forms.Panel
    $hote.Dock = 'Fill'; $hote.Padding = New-Object Windows.Forms.Padding((apx 20), 0, (apx 20), 0)
    $hote.Controls.AddRange(@($grid, $vide))
    $pied = New-AliasPied
    $f.Controls.AddRange(@($hote, $ligne.Panel, (New-AliasEntete), $pied.Panel))   # Fill en premier : ancre en dernier, prend la place restante
    Register-AliasEvenements
    Copy-Item $aliasFile "$aliasFile.bak" -Force -ErrorAction SilentlyContinue   # filet de securite
    Update-AppsIfStale
    Import-AliasGrille
    [void]$f.Handle; [LanceurCue]::Style($f.Handle)
    $script:aliasFen = $f; $script:aliasFenCible = $cibleBox; $script:aliasFenAlias = $aliasBox
    try { [void]$f.ShowDialog((New-Object LanceurBureau)) } finally { $script:aliasFen = $null }
}

# Texte d'aide grise (EM_SETCUEBANNER), barre de titre sombre et coins arrondis, barres de defilement sombres,
# reactivation d'une fenetre, et proprietaire "bureau" (la fenetre des alias ne bloque pas la barre)
if (-not ('LanceurCue' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class LanceurCue {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string ids);
    [DllImport("user32.dll")] static extern bool EnableWindow(IntPtr h, bool on);
    public static bool Set(IntPtr box, string text) { SendMessage(box, 0x1501, new IntPtr(1), text ?? ""); return true; }
    public static void Sombre(IntPtr h) { SetWindowTheme(h, "DarkMode_Explorer", null); }
    public static void Activer(IntPtr h) { EnableWindow(h, true); }
    public static void Style(IntPtr h) {
        int on = 1; if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4);   // barre de titre sombre
        int round = 2; DwmSetWindowAttribute(h, 33, ref round, 4);                                              // coins arrondis (Windows 11)
    }
}
public class LanceurBureau : IWin32Window {
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    public IntPtr Handle { get { return GetDesktopWindow(); } }
}
'@
}

Import-Apps
