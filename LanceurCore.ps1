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
    [pscustomobject]@{ Name = $name; Id = $id; Type = $type; Target = $target; IconPath = $iconPath; Shell = $shell; Key = (ConvertTo-Key $name); Aliases = @() }
}

function Import-Apps {
    $list = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique | ForEach-Object { New-Entree $_.Name $_.AppID 'Appli' })
    $pris = @{}; foreach ($a in $list) { $pris[$a.Key] = $true }
    # Raccourcis perso : nom = nom du fichier sans extension ("Compta.lnk" -> "Compta")
    foreach ($f in Get-Raccourcis) { $list += New-Entree $f.BaseName $f.FullName 'Raccourci' $f.FullName }
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
    foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
        $alias = ConvertTo-Key $Matches[1]; $cible = $Matches[2]
        $app = $list | Where-Object { $_.Name -eq $cible } | Select-Object -First 1
        if (-not $app -and $cible -notmatch '[\\/:.]') {
            $app = $list | Where-Object { -not $_.Target -and $_.Name -like "$cible*" } | Sort-Object { $_.Name.Length } | Select-Object -First 1
        }
        if (-not $app) {
            $app = New-Entree $cible $cible 'Commande' $cible
            $list += $app
        }
        $app.Aliases += $alias
    }
    $script:apps = $list
    $script:keys = [string[]]@($list | ForEach-Object { $_.Key })
    $script:aliasArr = [string[]]@($list | ForEach-Object { $_.Aliases -join '|' })
    $script:hits  = [int[]]@($list | ForEach-Object { [int]$script:hist[$_.Id] })
    $script:bonus = [int[]]@($list | ForEach-Object { [int]$typeBonus[$_.Type] })
    for ($i = 0; $i -lt $list.Count; $i++) { $list[$i] | Add-Member -NotePropertyName Idx -NotePropertyValue $i -Force }
    $script:appsLoadedAt = Get-Date
    $script:aliasStamp = (Get-Item $aliasFile).LastWriteTime
    $script:raccourcisStamp = Get-RaccourcisStamp
    $script:menuStamp = Get-MenuDemarrerStamp
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
    if ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasStamp -or (Get-RaccourcisStamp) -ne $script:raccourcisStamp -or
        (Get-MenuDemarrerStamp) -ne $script:menuStamp) { Import-Apps }
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
    $k = ConvertTo-Key $alias
    $keep = foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -notmatch '^\s*#' -and $line -match '^\s*([^=]+?)\s*=' -and (ConvertTo-Key $Matches[1]) -eq $k) { continue }
        $line
    }
    @($keep) + "$alias = $cible" | Set-Content -Encoding UTF8 $aliasFile
    Import-Apps
}

# ---- Fenetre de gestion des alias ----
# $preset : nom d'une appli a pre-remplir dans une nouvelle ligne
function Show-AliasManager([string]$preset) {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Alias du lanceur'
    $f.StartPosition = 'CenterScreen'
    $f.Size = New-Object Drawing.Size(560, 480)
    $f.MinimumSize = New-Object Drawing.Size(400, 300)
    $f.TopMost = $true
    $f.MinimizeBox = $false
    $f.Font = New-Object Drawing.Font('Segoe UI', 10)

    $info = New-Object Windows.Forms.Label
    $info.Dock = 'Top'
    $info.Height = 46
    $info.Padding = New-Object Windows.Forms.Padding(8, 6, 8, 0)
    $info.Text = "Alias = ce que tu tapes dans la barre.  Cible = l'appli (suggestions en tapant), un dossier, une URL ou une commande."

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $true
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [Drawing.Color]::White
    $grid.BorderStyle = 'None'
    [void]$grid.Columns.Add('Alias', 'Alias')
    [void]$grid.Columns.Add('Cible', 'Cible')
    $grid.Columns[0].FillWeight = 30
    $grid.Columns[1].FillWeight = 70

    foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
        [void]$grid.Rows.Add($Matches[1], $Matches[2])
    }
    if ($preset) {
        $i = $grid.Rows.Add('', $preset)
        $grid.CurrentCell = $grid.Rows[$i].Cells[0]
        $f.Add_Shown({ $grid.BeginEdit($true) })
    }

    # Suggestions de noms d'applis dans la colonne Cible
    $names = New-Object Windows.Forms.AutoCompleteStringCollection
    $names.AddRange([string[]]@($script:apps | Where-Object { $_.Type -ne 'Commande' } | ForEach-Object { $_.Name }))
    $grid.Add_EditingControlShowing({
        param($s, $e)
        $tb = $e.Control -as [Windows.Forms.TextBox]
        if (-not $tb) { return }
        if ($grid.CurrentCell.ColumnIndex -eq 1) {
            $tb.AutoCompleteMode = 'SuggestAppend'; $tb.AutoCompleteSource = 'CustomSource'; $tb.AutoCompleteCustomSource = $names
        } else { $tb.AutoCompleteMode = 'None' }
    })

    $bottom = New-Object Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 48
    $bottom.FlowDirection = 'RightToLeft'
    $bottom.Padding = New-Object Windows.Forms.Padding(6)

    $save = New-Object Windows.Forms.Button; $save.Text = 'Enregistrer'; $save.Width = 110; $save.Height = 32
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Annuler'; $cancel.Width = 90; $cancel.Height = 32
    $del = New-Object Windows.Forms.Button; $del.Text = 'Supprimer la ligne'; $del.Width = 150; $del.Height = 32
    $bottom.Controls.AddRange(@($save, $cancel, $del))

    $del.Add_Click({
        $r = $grid.CurrentRow
        if ($r -and -not $r.IsNewRow) { $grid.Rows.Remove($r) }
    })
    $cancel.Add_Click({ $f.Close() })
    $save.Add_Click({
        [void]$grid.EndEdit()
        $out = @($aliasEntete)
        foreach ($r in $grid.Rows) {
            if ($r.IsNewRow) { continue }
            $a = "$($r.Cells[0].Value)".Trim(); $c = "$($r.Cells[1].Value)".Trim()
            if ($a -and $c) { $out += "$a = $c" }
        }
        $out | Set-Content -Encoding UTF8 $aliasFile
        Import-Apps
        $f.Close()
    })

    $f.Controls.Add($grid)
    $f.Controls.Add($info)
    $f.Controls.Add($bottom)
    [void]$f.ShowDialog()
}

Import-Apps
