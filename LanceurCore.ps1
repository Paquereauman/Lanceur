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

# ---- Fenetre des alias (style Windows 11) ----
# Une colonne : ajout en haut (Entree, Entree, alias suivant), puis la liste filtrable.
# Tout est enregistre a chaque changement, et la barre en tient compte aussitot.
# $preset : nom d'une appli a pre-remplir comme cible (clic droit sur une suggestion de la barre)
function Show-AliasManager([string]$preset) {
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k = $g.DpiX / 96; $g.Dispose()
    function px([double]$v) { [int]($v * $k) }
    $cBg = [Drawing.Color]::FromArgb(32, 32, 32); $cChamp = [Drawing.Color]::FromArgb(45, 45, 45); $cChampHaut = [Drawing.Color]::FromArgb(52, 52, 52)
    $cTexte = [Drawing.Color]::FromArgb(240, 240, 240); $cDim = [Drawing.Color]::FromArgb(160, 160, 160)
    $cAccent = [Drawing.Color]::FromArgb(76, 194, 255); $cAccentFonce = [Drawing.Color]::FromArgb(0, 95, 184)
    $cSel = [Drawing.Color]::FromArgb(50, 50, 50); $cWarn = [Drawing.Color]::FromArgb(252, 185, 0)
    $famille = if ((New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains 'Segoe UI Variable Text') { 'Segoe UI Variable Text' } else { 'Segoe UI' }
    $font = New-Object Drawing.Font($famille, 10); $fontFort = New-Object Drawing.Font($famille, 10, [Drawing.FontStyle]::Bold)
    $fontTitre = New-Object Drawing.Font($famille, 18, [Drawing.FontStyle]::Bold); $fontPetit = New-Object Drawing.Font($famille, 9)
    $st = @{ pairs = (Get-AliasPairs); edit = $null; vue = @(); survol = -1 }
    $aIcone = [bool](Get-Command Get-AppIcon -ErrorAction SilentlyContinue)
    Copy-Item $aliasFile "$aliasFile.bak" -Force -ErrorAction SilentlyContinue   # filet de securite

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Alias'; $f.StartPosition = 'CenterScreen'; $f.AutoScaleMode = 'None'
    $f.Size = New-Object Drawing.Size((px 620), (px 680)); $f.MinimumSize = New-Object Drawing.Size((px 460), (px 420))
    $f.TopMost = $true; $f.MinimizeBox = $false; $f.KeyPreview = $true
    $f.BackColor = $cBg; $f.ForeColor = $cTexte; $f.Font = $font
    $f.Padding = New-Object Windows.Forms.Padding((px 24), (px 16), (px 24), (px 16))
    # Barre de titre sombre et coins arrondis (Windows 11)
    $f.Add_HandleCreated({ [LanceurCue]::Style($f.Handle) })

    # Champ arrondi facon Windows 11 : fond gris, trait de couleur en bas quand il a le focus
    function New-Champ($cue) {
        $p = New-Object Windows.Forms.Panel; $p.Height = (px 36); $p.Dock = 'Fill'; $p.Margin = New-Object Windows.Forms.Padding(0, 0, (px 8), 0); $p.BackColor = $cBg
        $t = New-Object Windows.Forms.TextBox; $t.BorderStyle = 'None'; $t.BackColor = $cChamp; $t.ForeColor = $cTexte; $t.Font = $font
        $p.Controls.Add($t); $p.Tag = $t; $t.Tag = $cue
        $p.Add_Resize({ param($s) $tb = $s.Tag; $tb.Left = (px 11); $tb.Width = $s.Width - (px 22); $tb.Top = [int](($s.Height - $tb.Height) / 2) - 1; $s.Invalidate() })
        $p.Add_Paint({
            param($s, $e)
            $gr = $e.Graphics; $gr.SmoothingMode = 'AntiAlias'; $tb = $s.Tag
            $r = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1)); $d = (px 8)
            $path = New-Object Drawing.Drawing2D.GraphicsPath
            $path.AddArc($r.X, $r.Y, $d, $d, 180, 90); $path.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
            $path.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90); $path.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90); $path.CloseFigure()
            $gr.FillPath((New-Object Drawing.SolidBrush($tb.BackColor)), $path)
            $gr.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(60, 60, 60))), $path)
            if ($tb.Focused) { $gr.FillRectangle((New-Object Drawing.SolidBrush($cAccent)), (px 4), ($s.Height - (px 2)), ($s.Width - (px 8)), (px 2)) }
        })
        $t.Add_GotFocus({ param($s) $s.BackColor = $cBg; $s.Parent.Invalidate() })
        $t.Add_LostFocus({ param($s) $s.BackColor = $cChamp; $s.Parent.Invalidate() })
        $t.Add_HandleCreated({ param($s) [void][LanceurCue]::Set($s.Handle, $s.Tag) })
        $p
    }
    # Bouton plat arrondi
    function New-Bouton($texte, $plein) {
        $b = New-Object Windows.Forms.Button; $b.Text = $texte; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $(if ($plein) { $cAccent } else { $cChamp }); $b.ForeColor = $(if ($plein) { [Drawing.Color]::Black } else { $cTexte })
        $b.FlatAppearance.MouseOverBackColor = $(if ($plein) { [Drawing.Color]::FromArgb(100, 205, 255) } else { $cChampHaut })
        $b.Font = $(if ($plein) { $fontFort } else { $font }); $b.Height = (px 36); $b.Width = (px 104); $b.Cursor = 'Hand'; $b.Margin = New-Object Windows.Forms.Padding(0)
        $b.Add_Resize({ param($s) $d = (px 8); $p = New-Object Drawing.Drawing2D.GraphicsPath; $w = $s.Width; $h = $s.Height
            $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($w - $d, 0, $d, $d, 270, 90); $p.AddArc($w - $d, $h - $d, $d, $d, 0, 90); $p.AddArc(0, $h - $d, $d, $d, 90, 90)
            $s.Region = New-Object Drawing.Region($p) })
        $b
    }
    function New-Texte($t, $fnt, $col) { $l = New-Object Windows.Forms.Label; $l.Text = $t; $l.Font = $fnt; $l.ForeColor = $col; $l.AutoSize = $true; $l.Margin = New-Object Windows.Forms.Padding(0); $l }

    # ---- Mise en page (une colonne) ----
    $col = New-Object Windows.Forms.TableLayoutPanel
    $col.Dock = 'Fill'; $col.ColumnCount = 1; $col.RowCount = 7
    foreach ($s in 'AutoSize', 'AutoSize', 'AutoSize', 'AutoSize', 'AutoSize', 'Percent', 'AutoSize') { [void]$col.RowStyles.Add((New-Object Windows.Forms.RowStyle($s, 100))) }

    $titre = New-Texte 'Alias' $fontTitre $cTexte
    $sousTitre = New-Texte 'Un mot court qui ouvre une appli, un dossier ou un site depuis la barre.' $fontPetit $cDim
    $sousTitre.Margin = New-Object Windows.Forms.Padding((px 2), (px 2), 0, (px 18))

    $ligne = New-Object Windows.Forms.TableLayoutPanel; $ligne.Dock = 'Fill'; $ligne.ColumnCount = 3; $ligne.RowCount = 1; $ligne.Height = (px 36)
    $ligne.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (px 6))
    [void]$ligne.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 30)))
    [void]$ligne.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 70)))
    [void]$ligne.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (px 104))))
    [void]$ligne.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', (px 36))))
    $chAlias = New-Champ 'Alias'; $chCible = New-Champ 'Appli, dossier ou URL'
    $tbAlias = $chAlias.Tag; $tbCible = $chCible.Tag
    $btnAjout = New-Bouton 'Ajouter' $true
    $ligne.Controls.Add($chAlias, 0, 0); $ligne.Controls.Add($chCible, 1, 0); $ligne.Controls.Add($btnAjout, 2, 0)
    $info = New-Texte '' $fontPetit $cDim; $info.Margin = New-Object Windows.Forms.Padding((px 2), (px 2), 0, (px 22))

    $chFiltre = New-Champ 'Rechercher dans tes alias'; $chFiltre.Dock = 'Top'; $chFiltre.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (px 10))
    $filtre = $chFiltre.Tag

    $liste = New-Object Windows.Forms.ListBox
    $liste.Dock = 'Fill'; $liste.BorderStyle = 'None'; $liste.BackColor = $cBg; $liste.ForeColor = $cTexte; $liste.IntegralHeight = $false
    $liste.DrawMode = 'OwnerDrawFixed'; $liste.ItemHeight = (px 44); $liste.SelectionMode = 'MultiExtended'
    $bas = New-Texte 'Double-clic : modifier     Suppr : supprimer     Ctrl+F : rechercher     Échap : fermer' $fontPetit $cDim
    $bas.Margin = New-Object Windows.Forms.Padding((px 2), (px 10), 0, 0)

    $col.Controls.Add($titre, 0, 0); $col.Controls.Add($sousTitre, 0, 1); $col.Controls.Add($ligne, 0, 2); $col.Controls.Add($info, 0, 3)
    $col.Controls.Add($chFiltre, 0, 4); $col.Controls.Add($liste, 0, 5); $col.Controls.Add($bas, 0, 6)
    $f.Controls.Add($col)

    # ---- Fonctions ----
    function Get-Resolu($cible) { $a = Resolve-Cible $cible; if ($a -and $a.Type -ne 'Commande') { $a } else { $null } }   # $null : commande / chemin / introuvable
    function Set-Info($t, $c = $cDim) { $info.Text = $t; $info.ForeColor = $c }
    # Ce que fait une cible qui n'est pas une appli : dossier, fichier, site web, commande, ou introuvable
    function Get-Genre([string]$c) {
        $x = [Environment]::ExpandEnvironmentVariables($c)
        if ($x -match '^(https?://|www\.)') { return 'site web' }
        if (Test-Path -LiteralPath $x -PathType Container -ErrorAction SilentlyContinue) { return 'dossier' }
        if (Test-Path -LiteralPath $x -ErrorAction SilentlyContinue) { return 'fichier' }
        if ($x -match '^[a-z][a-z0-9+.-]*:' -and $x -notmatch '^[a-z]:\') { return 'lien' }
        if (Get-Command ($x -split ' ')[0] -CommandType Application -ErrorAction SilentlyContinue) { return 'commande' }
        'introuvable'
    }
    function Update-Liste {
        $q = ConvertTo-Key $filtre.Text.Trim()
        $vue = New-Object Collections.ArrayList
        foreach ($p in ($st.pairs | Sort-Object { ConvertTo-Key $_.Alias })) {
            $a = Get-Resolu $p.Cible
            $nom = if ($a) { $a.Name } else { $p.Cible }
            if ($q -and -not (ConvertTo-Key "$($p.Alias) $nom $($p.Cible)").Contains($q)) { continue }
            [void]$vue.Add([pscustomobject]@{ Paire = $p; App = $a; Brut = (Resolve-Cible $p.Cible); Nom = $nom; Genre = $(if ($a) { '' } else { Get-Genre $p.Cible }) })
        }
        $st.vue = $vue
        $liste.BeginUpdate(); $liste.Items.Clear(); foreach ($v in $vue) { [void]$liste.Items.Add($v.Paire.Alias) }; $liste.EndUpdate()
        $sousTitre.Text = "$($st.pairs.Count) alias  ·  un mot court qui ouvre une appli, un dossier ou un site depuis la barre."
    }
    function Save-Tout($msg) {
        Save-AliasPairs $st.pairs
        $st.pairs = Get-AliasPairs
        Update-Liste
        Set-Info ([string][char]0x2713 + "  $msg") $cAccent
    }
    function Reset-Ajout { $st.edit = $null; $btnAjout.Text = 'Ajouter'; $tbAlias.Text = ''; $tbCible.Text = ''; $tbAlias.Focus() }
    function Add-Une {
        $a = $tbAlias.Text.Trim(); $c = $tbCible.Text.Trim()
        if (-not $a) { $tbAlias.Focus(); return }
        if ($a.Contains('=')) { Set-Info "Un alias ne peut pas contenir « = »." $cWarn; return }
        if (-not $c) { $tbCible.Focus(); return }
        $ka = ConvertTo-Key $a
        $remplace = @($st.pairs | Where-Object { (ConvertTo-Key $_.Alias) -eq $ka -and $_ -ne $st.edit }).Count -gt 0
        foreach ($x in @($st.pairs | Where-Object { (ConvertTo-Key $_.Alias) -eq $ka -or ($st.edit -and $_ -eq $st.edit) })) { $st.pairs.Remove($x) }
        [void]$st.pairs.Add([pscustomobject]@{ Alias = $a; Cible = $c })
        $r = Get-Resolu $c
        $msg = "$a $([char]0x2192) $(if ($r) { $r.Name } else { "$c  ($(Get-Genre $c))" })"
        if ($st.edit) { $msg += '  · modifié' } elseif ($remplace) { $msg += '  · remplace l''ancien' }
        Save-Tout $msg
        Reset-Ajout
    }
    function Edit-Selection {
        $i = $liste.SelectedIndex; if ($i -lt 0) { return }
        $p = $st.vue[$i].Paire
        $st.edit = $p; $tbAlias.Text = $p.Alias; $tbCible.Text = $p.Cible; $btnAjout.Text = 'Modifier'
        $tbAlias.Focus(); $tbAlias.SelectAll()
        Set-Info "Modification de « $($p.Alias) » : change l'alias ou la cible, puis Entrée.  Échap : annuler"
    }
    function Remove-Selection {
        $sel = @($liste.SelectedIndices | ForEach-Object { $st.vue[$_].Paire }); if (-not $sel.Count) { return }
        foreach ($p in $sel) { $st.pairs.Remove($p) }
        Save-Tout ("$($sel.Count) alias supprimé" + $(if ($sel.Count -gt 1) { 's' } else { '' }))
    }

    # Une ligne : icone, alias, appli ouverte ; selection arrondie avec un trait de couleur a gauche ; x pour supprimer au survol
    $liste.Add_DrawItem({
        param($s, $e)
        if ($e.Index -lt 0 -or $e.Index -ge $st.vue.Count) { return }
        $gr = $e.Graphics; $gr.SmoothingMode = 'AntiAlias'; $gr.TextRenderingHint = 'ClearTypeGridFit'
        $gr.FillRectangle((New-Object Drawing.SolidBrush($cBg)), $e.Bounds)
        $v = $st.vue[$e.Index]; $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0; $survol = $e.Index -eq $st.survol
        $r = New-Object Drawing.Rectangle($e.Bounds.X, ($e.Bounds.Y + (px 2)), ($e.Bounds.Width - 1), ($e.Bounds.Height - (px 4)))
        if ($sel -or $survol) {
            $d = (px 8); $p = New-Object Drawing.Drawing2D.GraphicsPath
            $p.AddArc($r.X, $r.Y, $d, $d, 180, 90); $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90); $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90); $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90); $p.CloseFigure()
            $gr.FillPath((New-Object Drawing.SolidBrush($(if ($sel) { $cSel } else { [Drawing.Color]::FromArgb(40, 40, 40) }))), $p)
            if ($sel) { $gr.FillRectangle((New-Object Drawing.SolidBrush($cAccent)), $r.X, ($r.Y + $r.Height / 2 - (px 8)), (px 3), (px 16)) }
        }
        $isz = (px 22); $x = $r.X + (px 14)
        $b = if ($aIcone -and $v.Brut -and $v.Genre -ne 'introuvable') { Get-AppIcon $v.Brut } else { $null }
        if ($b) { $gr.InterpolationMode = 'HighQualityBicubic'; $gr.DrawImage($b, $x, $r.Y + [int](($r.Height - $isz) / 2), $isz, $isz) }
        elseif (-not $v.App) { [Windows.Forms.TextRenderer]::DrawText($gr, [string][char]0x2197, $font, (New-Object Drawing.Rectangle($x, $r.Y, $isz, $r.Height)), $cWarn, [Windows.Forms.TextFormatFlags]'VerticalCenter, HorizontalCenter') }
        $x += $isz + (px 14)
        $wAlias = (px 140)
        $fl = [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix'
        [Windows.Forms.TextRenderer]::DrawText($gr, $v.Paire.Alias, $fontFort, (New-Object Drawing.Rectangle($x, $r.Y, ($wAlias - (px 8)), $r.Height)), $cTexte, $fl)
        $x += $wAlias
        $droite = $r.Right - $(if ($survol) { (px 40) } else { (px 12) })
        $texte = if ($v.App) { $v.Nom + $(if ($v.App.Type -ne 'Appli') { "   ·  $($v.App.Type)" } else { '' }) } else { "$($v.Nom)   ·  $($v.Genre)" }
        [Windows.Forms.TextRenderer]::DrawText($gr, $texte, $font, (New-Object Drawing.Rectangle($x, $r.Y, [Math]::Max(10, $droite - $x), $r.Height)), $(if ($v.Genre -eq 'introuvable') { $cWarn } else { $cDim }), $fl)
        if ($survol) { [Windows.Forms.TextRenderer]::DrawText($gr, [string][char]0x2715, $font, (New-Object Drawing.Rectangle(($r.Right - (px 36)), $r.Y, (px 28), $r.Height)), $cDim, [Windows.Forms.TextFormatFlags]'VerticalCenter, HorizontalCenter') }
    })
    $liste.Add_MouseMove({
        $i = $liste.IndexFromPoint($_.Location)
        if ($i -ne $st.survol) { $st.survol = $i; $liste.Invalidate() }
        $liste.Cursor = if ($i -ge 0 -and $_.X -gt $liste.ClientSize.Width - (px 40)) { 'Hand' } else { 'Default' }
    })
    $liste.Add_MouseLeave({ $st.survol = -1; $liste.Invalidate() })
    $liste.Add_MouseUp({
        $i = $liste.IndexFromPoint($_.Location)
        if ($_.Button -eq 'Left' -and $i -ge 0 -and $_.X -gt $liste.ClientSize.Width - (px 40)) {   # clic sur x
            $p = $st.vue[$i].Paire; $st.pairs.Remove($p); Save-Tout "« $($p.Alias) » supprimé"
        }
    })

    # ---- Evenements ----
    $filtre.Add_TextChanged({ Update-Liste })
    $tbAlias.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; if ($tbCible.Text) { Add-Une } else { $tbCible.Focus() } } })
    $tbCible.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Add-Une } })
    $btnAjout.Add_Click({ Add-Une })
    $liste.Add_DoubleClick({ if ($liste.PointToClient([Windows.Forms.Control]::MousePosition).X -le $liste.ClientSize.Width - (px 40)) { Edit-Selection } })
    $liste.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Delete') { Remove-Selection; $e.Handled = $true }
        elseif ($e.KeyCode -eq 'F2' -or $e.KeyCode -eq 'Return') { Edit-Selection; $e.Handled = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'A') { for ($i = 0; $i -lt $liste.Items.Count; $i++) { $liste.SetSelected($i, $true) }; $e.Handled = $true }
    })
    $liste.Add_Resize({ $liste.Invalidate() })
    $liste.Add_HandleCreated({ [LanceurCue]::Sombre($liste.Handle) })   # barre de defilement sombre
    $f.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Escape') {
            $e.SuppressKeyPress = $true
            if ($st.edit -or $tbAlias.Text -or $tbCible.Text) { Reset-Ajout; Set-Info '' } else { $f.Close() }
        } elseif ($e.Control -and $e.KeyCode -eq 'F') { $filtre.Focus(); $filtre.SelectAll(); $e.SuppressKeyPress = $true }
    })
    $f.Add_Shown({
        if ($preset) { $tbCible.Text = $preset; Set-Info "Tape l'alias pour « $preset », puis Entrée." }
        else { Set-Info "Tape l'alias, Entrée, puis l'appli, Entrée : c'est ajouté, tu enchaînes sur le suivant." }
        $tbAlias.Focus()
    })
    Update-Liste
    [void]$f.ShowDialog()
}

# Texte d'aide grise dans une case vide (EM_SETCUEBANNER), barre de titre sombre et coins arrondis (Windows 11)
if (-not ('LanceurCue' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class LanceurCue {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    public static bool Set(IntPtr box, string text) { SendMessage(box, 0x1501, new IntPtr(1), text ?? ""); return true; }
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string ids);
    public static void Sombre(IntPtr h) { SetWindowTheme(h, "DarkMode_Explorer", null); }
    public static void Style(IntPtr h) {
        int on = 1; DwmSetWindowAttribute(h, 20, ref on, 4);        // DWMWA_USE_IMMERSIVE_DARK_MODE
        int round = 2; DwmSetWindowAttribute(h, 33, ref round, 4);  // DWMWA_WINDOW_CORNER_PREFERENCE = arrondi
    }
}
'@
}

Import-Apps
