# Coeur du lanceur : liste des applis, alias, recherche, lancement, historique.
# Utilise par Lanceur.ps1 (fenetre) et LanceurBarre.ps1 (barre dans la barre des taches).

$dataDir   = Join-Path $env:APPDATA 'Lanceur'
$histFile  = Join-Path $dataDir 'historique.json'
$aliasFile = Join-Path $PSScriptRoot 'alias.txt'
$raccourcisDir = Join-Path $PSScriptRoot 'raccourcis'   # tout fichier pose ici (.lnk, .url, .exe, document...) apparait dans la recherche
New-Item -ItemType Directory -Force $dataDir, $raccourcisDir | Out-Null

# Fichiers du dossier raccourcis (sous-dossiers compris), sauf les fichiers caches type .gitkeep
function Get-Raccourcis { @(Get-ChildItem -LiteralPath $raccourcisDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') }) }
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
    public static int[] Find(string[] keys, string[] aliases, int[] hits, int[] bonus, string text, int max) {
        string q = Key((text ?? "").Trim());
        // Trois niveaux, chacun utilise seulement si le precedent est vide :
        //   1. applis, raccourcis, Panneau de configuration, pages Parametres qui commencent comme le texte
        //   2. taches du Panneau de configuration qui commencent comme le texte (longues et nombreuses)
        //   3. correspondances faibles (milieu de mot, lettres dans l'ordre) sur les applis et raccourcis
        var res = new List<int[]>();
        var tasks = new List<int[]>();
        var weak = new List<int[]>();
        for (int i = 0; i < keys.Length; i++) {
            int s = q.Length == 0 ? 1 : Score(keys[i], q);
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
        res.Sort((x, y) => y[1] != x[1] ? y[1].CompareTo(x[1])
                         : keys[x[0]].Length != keys[y[0]].Length ? keys[x[0]].Length.CompareTo(keys[y[0]].Length)
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
$typeBonus = @{ 'Appli' = 0; 'Raccourci' = 0; 'Commande' = 0; 'Panneau de config.' = -50; 'Parametres' = -50; 'Tache' = -250 }
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

function Import-Apps {
    $list = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique | ForEach-Object {
        # Applis web installees depuis un navigateur ("Brave._crx_...", "Chrome._crx_...") : etiquette = le navigateur,
        # et le nom du navigateur fait partie de la recherche ("brave" les liste toutes)
        if ($_.AppID -match '^(Brave|Chrome|Chromium|MSEdge|Edge|Vivaldi|Opera)[^.]*\._crx_') {
            $nav = @{ 'msedge' = 'Edge' }[$Matches[1].ToLower()]; if (-not $nav) { $nav = $Matches[1] }
            $e = New-Entree $_.Name $_.AppID $nav
            $e.Key = ConvertTo-Key "$($_.Name) $nav"
            $e
        } else { New-Entree $_.Name $_.AppID 'Appli' }
    })
    $pris = @{}; foreach ($a in $list) { $pris[$a.Key] = $true }
    # Raccourcis perso : nom = nom du fichier sans extension ("Compta.lnk" -> "Compta")
    # Dans un sous-dossier ("raccourcis\Brave\Banque.url") : etiquette = nom du sous-dossier, qui fait partie de la recherche
    foreach ($f in Get-Raccourcis) {
        $rel = $f.FullName.Substring($raccourcisDir.Length).TrimStart('\')
        $dossier = if ($rel.Contains('\')) { $rel.Split('\')[0] } else { $null }
        $e = New-Entree $f.BaseName $f.FullName $(if ($dossier) { $dossier } else { 'Raccourci' }) $f.FullName
        if ($dossier) { $e.Key = ConvertTo-Key "$($f.BaseName) $dossier" }
        $list += $e
    }
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
    foreach ($a in $list) { if (-not $a.Target -and $a.Name -like "$cible*" -and (-not $best -or $a.Name.Length -lt $best.Name.Length)) { $best = $a } }
    $best
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
            else { $app = New-Entree $p.Cible $p.Cible 'Commande' $p.Cible; [void]$list.Add($app); $parNom[$p.Cible] = $app }
        }
        $app.Aliases += (ConvertTo-Key $p.Alias)
    }
    # Tableaux pour la recherche C# (boucles simples : ~10x plus rapide que des pipelines sur 600 entrees)
    $n = $list.Count
    $keys = New-Object string[] $n; $al = New-Object string[] $n; $hits = New-Object int[] $n; $bonus = New-Object int[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $a = $list[$i]; $a.Idx = $i
        $keys[$i] = $a.Key; $al[$i] = $a.Aliases -join '|'; $hits[$i] = [int]$script:hist[$a.Id]; $bonus[$i] = [int]$typeBonus[$a.Type]
    }
    $script:apps = $list; $script:keys = $keys; $script:aliasArr = $al; $script:hits = $hits; $script:bonus = $bonus
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
    if ((Get-RaccourcisStamp) -ne $script:raccourcisStamp -or (Get-MenuDemarrerStamp) -ne $script:menuStamp) { Import-Apps }
    elseif ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasStamp) { Update-Aliases }   # alias seuls : instantane
}

# Toujours entourer le resultat de @(...) : avec un seul resultat, PowerShell 5.1 renvoie l'objet seul
function Find-Apps([string]$text, [int]$max = 15) {
    $idx = [LanceurSearch]::Find($script:keys, $script:aliasArr, $script:hits, $script:bonus, $text, $max)
    @(foreach ($i in $idx) { $script:apps[$i] })
}

function Get-AppLabel($a) {
    if ($a.Aliases.Count) { return $a.Name + '    [' + ($a.Aliases -join ', ') + ']' }
    $a.Name
}

# Lance l'appli (ou, si $app est vide, le texte tape : chemin, URL, commande). Renvoie $true si OK.
function Invoke-Launch($app, [string]$text) {
    $text = $text.Trim()
    try {
        if ($text -eq ':alias') { Show-AliasManager; return $true }
        if ($app) {
            Write-JournalSiDispo "Lancement : $($app.Name) [$($app.Type) $($app.Id)]"
            if ($app.Shell) { $app.Shell.InvokeVerb() }                                              # Panneau de configuration
            elseif ($app.Type -eq 'Parametres') { [void][Diagnostics.Process]::Start($app.Target) }   # page ms-settings:
            elseif ($app.Target) { Start-Process $app.Target }
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

# Lit des alias colles en masse : une ligne par alias, "alias = cible", "alias : cible", "alias<Tab>cible" ou "alias -> cible"
function ConvertFrom-AliasText([string]$texte) {
    foreach ($l in ($texte -split "`r?`n")) {
        $l = $l.Trim(); if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -match '^(.+?)\s*(?:=|->|→|:|\t)\s*(.+)$') { [pscustomobject]@{ Alias = $Matches[1].Trim(); Cible = $Matches[2].Trim(); Ok = $true; Ligne = $l } }
        else { [pscustomobject]@{ Alias = ''; Cible = ''; Ok = $false; Ligne = $l } }
    }
}

# Propose des alias pour les applis les plus utilisees qui n'en ont pas : initiales ("Visual Studio Code" -> vsc), sinon debut du nom
function Get-AliasSuggestions([int]$max = 20) {
    $pris = @{}; foreach ($p in (Get-AliasPairs)) { $pris[(ConvertTo-Key $p.Alias)] = $true }
    $res = @()
    foreach ($a in ($script:apps | Where-Object { -not $_.Aliases.Count -and $_.Type -notin 'Tache', 'Commande' -and [int]$script:hist[$_.Id] -gt 0 } |
                    Sort-Object { -[int]$script:hist[$_.Id] })) {
        $mots = @((ConvertTo-Key $a.Name) -split '[^a-z0-9]+' | Where-Object { $_ })
        if (-not $mots) { continue }
        $cands = @()
        if ($mots.Count -ge 2) { $cands += -join ($mots | ForEach-Object { $_[0] }) }
        $cands += $mots[0].Substring(0, [Math]::Min(3, $mots[0].Length)), $mots[0].Substring(0, [Math]::Min(4, $mots[0].Length))
        $choix = $cands | Where-Object { $_.Length -ge 2 -and -not $pris[$_] } | Select-Object -First 1
        if (-not $choix) { continue }
        $pris[$choix] = $true
        $res += "$choix = $($a.Name)"
        if ($res.Count -ge $max) { break }
    }
    $res
}

# ---- Fenetre des alias ----
# Ajout rapide (Entree, Entree, alias suivant...), ajout en masse avec apercu, filtre, suppression multiple.
# Tout est enregistre a chaque changement, et la barre en tient compte aussitot.
# $preset : nom d'une appli a pre-remplir comme cible (clic droit sur une suggestion)
function Show-AliasManager([string]$preset) {
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k = $g.DpiX / 96; $g.Dispose()
    function px([double]$v) { [int]($v * $k) }
    $cBg = [Drawing.Color]::FromArgb(32, 32, 32); $cPanel = [Drawing.Color]::FromArgb(45, 45, 45)
    $cText = [Drawing.Color]::Gainsboro; $cDim = [Drawing.Color]::FromArgb(150, 150, 150)
    $cAccent = [Drawing.Color]::FromArgb(60, 90, 140); $cOk = [Drawing.Color]::FromArgb(120, 200, 120); $cWarn = [Drawing.Color]::FromArgb(230, 180, 90)
    $font = New-Object Drawing.Font('Segoe UI', 10); $fontTitre = New-Object Drawing.Font('Segoe UI Semibold', 11); $fontPetit = New-Object Drawing.Font('Segoe UI', 8.5)
    $st = @{ pairs = (Get-AliasPairs); edit = $null; sugg = @() }
    $aIcone = [bool](Get-Command Get-AppIcon -ErrorAction SilentlyContinue)
    Copy-Item $aliasFile "$aliasFile.bak" -Force -ErrorAction SilentlyContinue   # filet de securite

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Alias du lanceur'
    $f.StartPosition = 'CenterScreen'
    $f.AutoScaleMode = 'None'
    $f.Size = New-Object Drawing.Size((px 980), (px 620))
    $f.MinimumSize = New-Object Drawing.Size((px 760), (px 480))
    $f.TopMost = $true; $f.MinimizeBox = $false; $f.KeyPreview = $true
    $f.BackColor = $cBg; $f.ForeColor = $cText; $f.Font = $font
    $f.Padding = New-Object Windows.Forms.Padding((px 14))

    function New-Label($t, $fnt = $font, $col = $cText) { $l = New-Object Windows.Forms.Label; $l.Text = $t; $l.Font = $fnt; $l.ForeColor = $col; $l.AutoSize = $true; $l.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (px 6)); $l }
    function New-Box($cue) {
        $t = New-Object Windows.Forms.TextBox; $t.BorderStyle = 'FixedSingle'; $t.BackColor = $cPanel; $t.ForeColor = [Drawing.Color]::White
        $t.Dock = 'Fill'; $t.Margin = New-Object Windows.Forms.Padding(0, 0, (px 8), 0)
        $t.Add_HandleCreated({ param($s) [void][LanceurCue]::Set($s.Handle, $s.Tag) }.GetNewClosure()); $t.Tag = $cue; $t
    }
    function New-Btn($t, $primaire = $false) {
        $b = New-Object Windows.Forms.Button; $b.Text = $t; $b.FlatStyle = 'Flat'; $b.AutoSize = $true; $b.Padding = New-Object Windows.Forms.Padding((px 10), (px 3), (px 10), (px 3))
        $b.BackColor = $(if ($primaire) { $cAccent } else { $cPanel }); $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderColor = $(if ($primaire) { $cAccent } else { [Drawing.Color]::FromArgb(70, 70, 70) }); $b.Cursor = 'Hand'
        $b.Margin = New-Object Windows.Forms.Padding(0, 0, (px 8), 0); $b
    }

    # ---- Mise en page : liste a gauche, ajout a droite ----
    $root = New-Object Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.ColumnCount = 2; $root.RowCount = 1
    [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 56)))
    [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 44)))

    # -- Gauche : filtre + liste --
    $gauche = New-Object Windows.Forms.TableLayoutPanel
    $gauche.Dock = 'Fill'; $gauche.ColumnCount = 1; $gauche.RowCount = 4; $gauche.Margin = New-Object Windows.Forms.Padding(0, 0, (px 14), 0)
    foreach ($s in 'AutoSize', 'AutoSize', 'Percent', 'AutoSize') { [void]$gauche.RowStyles.Add((New-Object Windows.Forms.RowStyle($s, 100))) }
    $titreListe = New-Label 'Tes alias' $fontTitre
    $filtre = New-Box 'Filtrer (alias, appli...)'; $filtre.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (px 8))
    $lv = New-Object Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.HideSelection = $false; $lv.MultiSelect = $true
    $lv.BorderStyle = 'None'; $lv.BackColor = $cPanel; $lv.ForeColor = $cText; $lv.HeaderStyle = 'Nonclickable'; $lv.OwnerDraw = $true
    [void]$lv.Columns.Add('Alias', (px 110)); [void]$lv.Columns.Add('Ouvre', (px 330))
    $img = New-Object Windows.Forms.ImageList; $img.ColorDepth = 'Depth32Bit'; $img.ImageSize = New-Object Drawing.Size((px 20), (px 20)); $lv.SmallImageList = $img
    $brHead = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(38, 38, 38))
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $e.Graphics.FillRectangle($brHead, $e.Bounds)
        $r = $e.Bounds; $r.X += (px 6)
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $fontPetit, $r, $cDim, [Windows.Forms.TextFormatFlags]'VerticalCenter, Left')
    })
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_Resize({ if ($lv.Columns.Count -eq 2) { $lv.Columns[1].Width = [Math]::Max((px 100), $lv.ClientSize.Width - $lv.Columns[0].Width) } })
    $basGauche = New-Object Windows.Forms.FlowLayoutPanel; $basGauche.AutoSize = $true; $basGauche.Dock = 'Fill'; $basGauche.Margin = New-Object Windows.Forms.Padding(0, (px 8), 0, 0)
    $btnSuppr = New-Btn 'Supprimer'; $btnModif = New-Btn 'Modifier'
    $aide = New-Label 'Double-clic : modifier    Suppr : supprimer    Ctrl+A : tout' $fontPetit $cDim; $aide.Margin = New-Object Windows.Forms.Padding(0, (px 8), 0, 0)
    $basGauche.Controls.AddRange(@($btnModif, $btnSuppr, $aide))
    $gauche.Controls.Add($titreListe, 0, 0); $gauche.Controls.Add($filtre, 0, 1); $gauche.Controls.Add($lv, 0, 2); $gauche.Controls.Add($basGauche, 0, 3)

    # -- Droite : ajout rapide + ajout en masse --
    $droite = New-Object Windows.Forms.TableLayoutPanel
    $droite.Dock = 'Fill'; $droite.ColumnCount = 1; $droite.RowCount = 7
    foreach ($s in 'AutoSize', 'AutoSize', 'AutoSize', 'AutoSize', 'Percent', 'Percent', 'AutoSize') { [void]$droite.RowStyles.Add((New-Object Windows.Forms.RowStyle($s, 50))) }
    $titreAjout = New-Label 'Ajouter un alias' $fontTitre
    $ligne = New-Object Windows.Forms.TableLayoutPanel; $ligne.Dock = 'Fill'; $ligne.ColumnCount = 3; $ligne.RowCount = 1; $ligne.AutoSize = $true
    [void]$ligne.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 32)))
    [void]$ligne.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 68)))
    [void]$ligne.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    $tbAlias = New-Box 'alias'; $tbCible = New-Box 'appli, dossier, URL...'
    $btnAjout = New-Btn 'Ajouter' $true; $btnAjout.Margin = New-Object Windows.Forms.Padding(0)
    $ligne.Controls.Add($tbAlias, 0, 0); $ligne.Controls.Add($tbCible, 1, 0); $ligne.Controls.Add($btnAjout, 2, 0)
    $infoAjout = New-Label ("Entrée dans l'alias : passe à la cible.   Tab : prend la suggestion.`nEntrée dans la cible : ajoute, et on enchaîne sur le suivant.") $fontPetit $cDim
    $infoAjout.Margin = New-Object Windows.Forms.Padding(0, (px 6), 0, (px 14))
    $titreMasse = New-Label 'Ajouter en masse' $fontTitre
    $masse = New-Object Windows.Forms.TextBox
    $masse.Multiline = $true; $masse.AcceptsReturn = $true; $masse.AcceptsTab = $true; $masse.ScrollBars = 'Vertical'; $masse.WordWrap = $false
    $masse.Dock = 'Fill'; $masse.BorderStyle = 'FixedSingle'; $masse.BackColor = $cPanel; $masse.ForeColor = [Drawing.Color]::White
    $masse.Font = New-Object Drawing.Font('Consolas', 10); $masse.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (px 6))
    $apercu = New-Object Windows.Forms.ListBox
    $apercu.Dock = 'Fill'; $apercu.BorderStyle = 'None'; $apercu.BackColor = $cBg; $apercu.IntegralHeight = $false
    $apercu.DrawMode = 'OwnerDrawFixed'; $apercu.ItemHeight = (px 20); $apercu.SelectionMode = 'None'
    $basDroite = New-Object Windows.Forms.FlowLayoutPanel; $basDroite.AutoSize = $true; $basDroite.Dock = 'Fill'; $basDroite.Margin = New-Object Windows.Forms.Padding(0, (px 8), 0, 0)
    $btnTout = New-Btn 'Ajouter tout' $true; $btnPropose = New-Btn 'Proposer des alias'; $btnVider = New-Btn 'Vider'
    $basDroite.Controls.AddRange(@($btnTout, $btnPropose, $btnVider))
    $droite.Controls.Add($titreAjout, 0, 0); $droite.Controls.Add($ligne, 0, 1); $droite.Controls.Add($infoAjout, 0, 2)
    $droite.Controls.Add($titreMasse, 0, 3); $droite.Controls.Add($masse, 0, 4); $droite.Controls.Add($apercu, 0, 5); $droite.Controls.Add($basDroite, 0, 6)

    $root.Controls.Add($gauche, 0, 0); $root.Controls.Add($droite, 1, 0)
    $statut = New-Label '' $fontPetit $cDim; $statut.AutoSize = $false; $statut.Dock = 'Bottom'; $statut.Height = (px 26); $statut.TextAlign = 'BottomLeft'
    $f.Controls.Add($root); $f.Controls.Add($statut)

    # Suggestions sous la case Cible (par-dessus le reste)
    $sug = New-Object Windows.Forms.ListBox
    $sug.Visible = $false; $sug.BorderStyle = 'FixedSingle'; $sug.BackColor = [Drawing.Color]::FromArgb(38, 38, 38); $sug.ForeColor = $cText
    $sug.DrawMode = 'OwnerDrawFixed'; $sug.ItemHeight = (px 28); $sug.IntegralHeight = $false
    $f.Controls.Add($sug); $sug.BringToFront()
    $brSel = New-Object Drawing.SolidBrush($cAccent); $brSug = New-Object Drawing.SolidBrush($sug.BackColor)

    # ---- Fonctions ----
    function Get-Icone($app) {
        if (-not $app -or -not $aIcone) { return $null }
        if (-not $img.Images.ContainsKey($app.Id)) { $b = Get-AppIcon $app; if (-not $b) { return $null }; $img.Images.Add($app.Id, $b) }
        $app.Id
    }
    function Get-Resolu($cible) { $a = Resolve-Cible $cible; if ($a -and $a.Type -ne 'Commande') { $a } else { $null } }   # $null : commande / chemin / introuvable
    function Update-Liste {
        $q = ConvertTo-Key $filtre.Text.Trim()
        $lv.BeginUpdate(); $lv.Items.Clear()
        $tri = @($st.pairs | Sort-Object { ConvertTo-Key $_.Alias })
        foreach ($p in $tri) {
            $a = Get-Resolu $p.Cible
            $ouvre = if ($a) { if ($a.Type -ne 'Appli') { "$($a.Name)   ·  $($a.Type)" } else { $a.Name } } else { "$($p.Cible)   ·  commande / chemin" }
            if ($q -and -not ((ConvertTo-Key "$($p.Alias) $ouvre $($p.Cible)").Contains($q))) { continue }
            $it = New-Object Windows.Forms.ListViewItem($p.Alias)
            [void]$it.SubItems.Add($ouvre); $it.Tag = $p
            $ic = Get-Icone $a; if ($ic) { $it.ImageKey = $ic }
            if (-not $a) { $it.ForeColor = $cWarn }
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
        $n = $st.pairs.Count
        $titreListe.Text = "Tes alias  ($n)"
    }
    function Set-Statut($t) { $statut.Text = $t }
    function Save-Tout($msg) {
        Save-AliasPairs $st.pairs
        $st.pairs = Get-AliasPairs
        Update-Liste
        Set-Statut ([string][char]0x2713 + "  $msg  ·  enregistré, la barre en tient compte tout de suite")
    }
    function Reset-Ajout { $st.edit = $null; $btnAjout.Text = 'Ajouter'; $tbAlias.Text = ''; $tbCible.Text = ''; $sug.Visible = $false; $tbAlias.Focus() }
    function Add-Une {
        $a = $tbAlias.Text.Trim(); $c = $tbCible.Text.Trim()
        if ($sug.Visible -and $sug.SelectedIndex -ge 0) { $c = $st.sugg[$sug.SelectedIndex].Name }
        if (-not $a) { $tbAlias.Focus(); return }
        if ($a.Contains('=')) { Set-Statut "L'alias ne peut pas contenir '='"; return }
        if (-not $c) { $tbCible.Focus(); return }
        $ka = ConvertTo-Key $a
        $ancien = @($st.pairs | Where-Object { (ConvertTo-Key $_.Alias) -eq $ka })
        foreach ($x in @($st.pairs | Where-Object { $st.edit -and $_ -eq $st.edit })) { $st.pairs.Remove($x) }
        foreach ($x in $ancien) { $st.pairs.Remove($x) }
        [void]$st.pairs.Add([pscustomobject]@{ Alias = $a; Cible = $c })
        $r = Get-Resolu $c; $nom = if ($r) { $r.Name } else { $c }
        Save-Tout ("$a $([char]0x2192) $nom" + $(if ($ancien.Count -and -not $st.edit) { '  (remplace)' } else { '' }))
        Reset-Ajout
    }
    function Show-Sugg {
        $t = $tbCible.Text.Trim()
        if (-not $t -or -not $tbCible.Focused) { $sug.Visible = $false; return }
        $st.sugg = @(Find-Apps $t 7 | Where-Object { $_.Type -ne 'Commande' })
        $sug.BeginUpdate(); $sug.Items.Clear(); foreach ($x in $st.sugg) { [void]$sug.Items.Add($x.Name) }; $sug.EndUpdate()
        if (-not $st.sugg.Count) { $sug.Visible = $false; return }
        $pt = $f.PointToClient($tbCible.PointToScreen((New-Object Drawing.Point(0, $tbCible.Height))))
        $sug.Bounds = New-Object Drawing.Rectangle($pt.X, ($pt.Y + 2), [Math]::Max($tbCible.Width, (px 280)), ($st.sugg.Count * $sug.ItemHeight + 4))
        $sug.SelectedIndex = 0; $sug.Visible = $true; $sug.BringToFront()
    }
    function Edit-Selection {
        if (-not $lv.SelectedItems.Count) { return }
        $p = $lv.SelectedItems[0].Tag
        $st.edit = $p; $tbAlias.Text = $p.Alias; $tbCible.Text = $p.Cible; $btnAjout.Text = 'Modifier'
        $tbAlias.Focus(); $tbAlias.SelectAll(); $sug.Visible = $false
        Set-Statut "Modification de « $($p.Alias) » : change l'alias ou la cible, puis Entrée.  Échap : annuler"
    }
    function Remove-Selection {
        $sel = @($lv.SelectedItems | ForEach-Object { $_.Tag }); if (-not $sel.Count) { return }
        foreach ($p in $sel) { $st.pairs.Remove($p) }
        Save-Tout ("$($sel.Count) alias supprimé" + $(if ($sel.Count -gt 1) { 's' } else { '' }) + '  (copie de l''ancien fichier : alias.txt.bak)')
    }
    function Update-Apercu {
        $st.lignes = @(ConvertFrom-AliasText $masse.Text)
        $apercu.BeginUpdate(); $apercu.Items.Clear()
        foreach ($l in $st.lignes) { [void]$apercu.Items.Add($l.Ligne) }
        $apercu.EndUpdate()
        $ok = @($st.lignes | Where-Object Ok).Count
        $btnTout.Text = if ($ok) { "Ajouter tout ($ok)" } else { 'Ajouter tout' }
        $btnTout.Enabled = $ok -gt 0
    }

    # Apercu de l'ajout en masse : vert = appli trouvee, orange = commande / chemin / URL, gris = ligne illisible
    $apercu.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0 -or $e.Index -ge $st.lignes.Count) { return }
        $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush($cBg)), $e.Bounds)
        $l = $st.lignes[$e.Index]
        if (-not $l.Ok) { $t = "  ?  $($l.Ligne)   (format : alias = cible)"; $col = $cDim }
        else {
            $a = Get-Resolu $l.Cible
            $deja = @($st.pairs | Where-Object { (ConvertTo-Key $_.Alias) -eq (ConvertTo-Key $l.Alias) }).Count
            $suffixe = if ($deja) { '   (remplace l''existant)' } else { '' }
            if ($a) { $t = "  $([char]0x2713)  $($l.Alias)  $([char]0x2192)  $($a.Name)$suffixe"; $col = $cOk }
            else { $t = "  !  $($l.Alias)  $([char]0x2192)  $($l.Cible)  (commande / chemin)$suffixe"; $col = $cWarn }
        }
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $t, $fontPetit, $e.Bounds, $col, [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix')
    })
    $sug.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0 -or $e.Index -ge $st.sugg.Count) { return }
        $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
        $e.Graphics.FillRectangle($(if ($sel) { $brSel } else { $brSug }), $e.Bounds)
        $x = $st.sugg[$e.Index]; $isz = (px 20); $pad = (px 6)
        if ($aIcone) { $b = Get-AppIcon $x; if ($b) { $e.Graphics.InterpolationMode = 'HighQualityBicubic'; $e.Graphics.DrawImage($b, $e.Bounds.X + $pad, $e.Bounds.Y + [int](($e.Bounds.Height - $isz) / 2), $isz, $isz) } }
        $r = New-Object Drawing.Rectangle(($e.Bounds.X + $pad * 2 + $isz), $e.Bounds.Y, ($e.Bounds.Width - $pad * 3 - $isz), $e.Bounds.Height)
        $t = if ($x.Type -ne 'Appli') { "$($x.Name)   ·  $($x.Type)" } else { $x.Name }
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $t, $font, $r, [Drawing.Color]::White, [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix')
    })

    # ---- Evenements ----
    $filtre.Add_TextChanged({ Update-Liste })
    $tbCible.Add_TextChanged({ Show-Sugg })
    $tbCible.Add_PreviewKeyDown({ if ($_.KeyCode -eq 'Tab' -and $sug.Visible) { $_.IsInputKey = $true } })   # Tab accepte la suggestion
    $tbCible.Add_LostFocus({ if (-not $sug.Focused) { $sug.Visible = $false } })
    $sug.Add_MouseUp({ $i = $sug.IndexFromPoint($_.Location); if ($i -ge 0) { $tbCible.Text = $st.sugg[$i].Name; $sug.Visible = $false; $tbCible.Focus(); $tbCible.SelectionStart = $tbCible.Text.Length } })
    $tbAlias.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; if ($tbCible.Text) { Add-Une } else { $tbCible.Focus() } } })
    $tbCible.Add_KeyDown({
        param($s, $e)
        switch ($e.KeyCode) {
            'Return' { $e.SuppressKeyPress = $true; Add-Une }
            'Down'   { if ($sug.Visible -and $sug.SelectedIndex -lt $sug.Items.Count - 1) { $sug.SelectedIndex++ }; $e.SuppressKeyPress = $true }
            'Up'     { if ($sug.Visible -and $sug.SelectedIndex -gt 0) { $sug.SelectedIndex-- }; $e.SuppressKeyPress = $true }
            'Tab'    { if ($sug.Visible -and $sug.SelectedIndex -ge 0) { $tbCible.Text = $st.sugg[$sug.SelectedIndex].Name; $tbCible.SelectionStart = $tbCible.Text.Length; $sug.Visible = $false; $e.SuppressKeyPress = $true } }
        }
    })
    $btnAjout.Add_Click({ Add-Une })
    $lv.Add_DoubleClick({ Edit-Selection })
    $lv.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Delete') { Remove-Selection; $e.Handled = $true }
        elseif ($e.KeyCode -eq 'F2' -or $e.KeyCode -eq 'Return') { Edit-Selection; $e.Handled = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'A') { foreach ($it in $lv.Items) { $it.Selected = $true }; $e.Handled = $true }
    })
    $btnSuppr.Add_Click({ Remove-Selection })
    $btnModif.Add_Click({ Edit-Selection })
    # Apercu recalcule 150 ms apres la derniere frappe : coller 200 lignes reste fluide
    $tempo = New-Object Windows.Forms.Timer; $tempo.Interval = 150
    $tempo.Add_Tick({ $tempo.Stop(); Update-Apercu })
    $masse.Add_TextChanged({ $tempo.Stop(); $tempo.Start() })
    $masse.Add_KeyDown({ param($s, $e) if ($e.Control -and $e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; $btnTout.PerformClick() } elseif ($e.Control -and $e.KeyCode -eq 'A') { $masse.SelectAll(); $e.SuppressKeyPress = $true } })
    $btnTout.Add_Click({
        $tempo.Stop(); Update-Apercu
        $ok = @($st.lignes | Where-Object Ok); if (-not $ok.Count) { return }
        foreach ($l in $ok) {
            $ka = ConvertTo-Key $l.Alias
            foreach ($x in @($st.pairs | Where-Object { (ConvertTo-Key $_.Alias) -eq $ka })) { $st.pairs.Remove($x) }
            [void]$st.pairs.Add([pscustomobject]@{ Alias = $l.Alias; Cible = $l.Cible })
        }
        $illisibles = @($st.lignes | Where-Object { -not $_.Ok } | ForEach-Object Ligne)
        Save-Tout "$($ok.Count) alias ajoutés"
        $masse.Text = ($illisibles -join "`r`n")   # ne restent que les lignes a corriger
    })
    $btnPropose.Add_Click({
        $p = @(Get-AliasSuggestions 20)
        if (-not $p.Count) { Set-Statut 'Aucune proposition : tes applis les plus utilisées ont déjà un alias.'; return }
        $debut = if ($masse.Text.Trim()) { $masse.Text.TrimEnd() + "`r`n" } else { '' }
        $masse.Text = $debut + ($p -join "`r`n")
        Set-Statut "$($p.Count) propositions pour tes applis les plus utilisées : modifie ou supprime des lignes, puis Ajouter tout (Ctrl+Entrée)."
        $masse.Focus(); $masse.SelectionStart = $masse.Text.Length
    })
    $btnVider.Add_Click({ $masse.Text = ''; $masse.Focus() })
    $f.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Escape') {
            $e.SuppressKeyPress = $true
            if ($sug.Visible) { $sug.Visible = $false } elseif ($st.edit -or $tbAlias.Text -or $tbCible.Text) { Reset-Ajout; Set-Statut '' } else { $f.Close() }
        } elseif ($e.Control -and $e.KeyCode -eq 'F') { $filtre.Focus(); $filtre.SelectAll(); $e.SuppressKeyPress = $true }
    })
    $f.Add_Shown({
        $lv.Columns[1].Width = [Math]::Max((px 100), $lv.ClientSize.Width - $lv.Columns[0].Width)
        if ($preset) { $tbCible.Text = $preset; $sug.Visible = $false; Set-Statut "Tape l'alias pour « $preset », puis Entrée." }
        $tbAlias.Focus()
    })
    $masse.Text = ''
    $st.lignes = @(); Update-Apercu
    Update-Liste
    Set-Statut "Échap : fermer    Ctrl+F : filtrer    Ctrl+Entrée (zone en masse) : ajouter tout"
    [void]$f.ShowDialog()
    $tempo.Dispose()
}

# Texte d'aide grise dans une case vide (EM_SETCUEBANNER)
if (-not ('LanceurCue' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class LanceurCue {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    public static bool Set(IntPtr box, string text) { SendMessage(box, 0x1501, new IntPtr(1), text ?? ""); return true; }
}
'@
}

Import-Apps
