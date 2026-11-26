# Coeur du lanceur : liste des applis, alias, recherche, lancement, historique.
# Utilise par Lanceur.ps1 (fenetre) et LanceurBarre.ps1 (barre dans la barre des taches).

$dataDir  = Join-Path $env:APPDATA 'Lanceur'
$histFile = Join-Path $dataDir 'historique.json'
$aliasFile = Join-Path $PSScriptRoot 'alias.txt'
New-Item -ItemType Directory -Force $dataDir | Out-Null

$script:hist = @{}
if (Test-Path $histFile) {
    try { (Get-Content $histFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $script:hist[$_.Name] = [int]$_.Value } } catch {}
}

if (-not (Test-Path $aliasFile)) {
    @'
# Alias du lanceur : une ligne par alias, au format   alias = cible
# La cible peut etre le nom exact d'une appli du menu Demarrer, un chemin, une URL ou une commande.
# Tape ":alias" dans le lanceur pour ouvrir ce fichier.
w = Word
x = Excel
calc = Calculator
note = Notepad
'@ | Set-Content -Encoding UTF8 $aliasFile
}

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
    public static int Score(string n, string q) {
        if (n == q) return 1000;
        if (n.StartsWith(q, StringComparison.Ordinal)) return 800;
        var words = n.Split(Sep, StringSplitOptions.RemoveEmptyEntries);
        var ini = new StringBuilder();
        foreach (var w in words) { if (w.StartsWith(q, StringComparison.Ordinal)) return 600; ini.Append(w[0]); }
        if (ini.ToString().StartsWith(q, StringComparison.Ordinal)) return 500;
        if (n.IndexOf(q, StringComparison.Ordinal) >= 0) return 400;
        int i = 0;
        foreach (char c in n) if (i < q.Length && c == q[i]) i++;
        return i == q.Length ? 100 : 0;
    }
    // aliases[i] = alias separes par '|'
    public static int[] Find(string[] keys, string[] aliases, int[] hits, string text, int max) {
        string q = Key((text ?? "").Trim());
        var res = new List<int[]>();
        for (int i = 0; i < keys.Length; i++) {
            int s = q.Length == 0 ? 1 : Score(keys[i], q);
            if (q.Length > 0 && aliases[i].Length > 0)
                foreach (var a in aliases[i].Split('|')) {
                    if (a == q) s = Math.Max(s, 2000);
                    else if (a.StartsWith(q, StringComparison.Ordinal)) s = Math.Max(s, 900);
                }
            if (s > 0) res.Add(new[] { i, s + Math.Min(300, 25 * hits[i]) });
        }
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

function Import-Apps {
    $list = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Id = $_.AppID; Target = $null; Key = (ConvertTo-Key $_.Name); Aliases = @() }
    })
    foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
        $alias = ConvertTo-Key $Matches[1]; $cible = $Matches[2]
        $app = $list | Where-Object { $_.Name -eq $cible } | Select-Object -First 1
        if (-not $app -and $cible -notmatch '[\\/:.]') {
            $app = $list | Where-Object { -not $_.Target -and $_.Name -like "$cible*" } | Sort-Object { $_.Name.Length } | Select-Object -First 1
        }
        if (-not $app) {
            $app = [pscustomobject]@{ Name = $cible; Id = $cible; Target = $cible; Key = (ConvertTo-Key $cible); Aliases = @() }
            $list += $app
        }
        $app.Aliases += $alias
    }
    $script:apps = $list
    $script:keys = [string[]]@($list | ForEach-Object { $_.Key })
    $script:aliasArr = [string[]]@($list | ForEach-Object { $_.Aliases -join '|' })
    $script:hits = [int[]]@($list | ForEach-Object { [int]$script:hist[$_.Id] })
    for ($i = 0; $i -lt $list.Count; $i++) { $list[$i] | Add-Member -NotePropertyName Idx -NotePropertyValue $i -Force }
    $script:appsLoadedAt = Get-Date
    $script:aliasStamp = (Get-Item $aliasFile).LastWriteTime
}

# Recharge seulement si alias.txt a change (la liste complete est rafraichie en tache de fond par la barre)
function Update-AppsIfStale {
    if ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasStamp) { Import-Apps }
}

function Find-Apps([string]$text, [int]$max = 15) {
    $idx = [LanceurSearch]::Find($script:keys, $script:aliasArr, $script:hits, $text, $max)
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
            if ($app.Target) { Start-Process $app.Target }
            else { Start-Process explorer.exe "shell:AppsFolder\$($app.Id)" }
            $script:hist[$app.Id] = [int]$script:hist[$app.Id] + 1
            $script:hits[$app.Idx] = $script:hist[$app.Id]
            try { $script:hist | ConvertTo-Json | Set-Content -Encoding UTF8 $histFile } catch {}
            return $true
        }
        if ($text) { Start-Process $text; return $true }
    } catch {
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
    $names.AddRange([string[]]@($script:apps | Where-Object { -not $_.Target } | ForEach-Object { $_.Name }))
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
        $out = @(
            "# Alias du lanceur : une ligne par alias, au format   alias = cible"
            "# La cible peut etre le nom exact d'une appli du menu Demarrer, un chemin, une URL ou une commande."
            "# Tape "":alias"" dans la barre pour ouvrir la fenetre des alias."
        )
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
