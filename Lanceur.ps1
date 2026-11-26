# Lanceur rapide : tape le nom d'une appli, Entree pour la lancer.
# Haut/Bas : choisir   Entree : lancer   Echap : fermer
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Historique d'utilisation (les apps les plus lancees remontent en tete) ---
$dataDir  = Join-Path $env:APPDATA 'Lanceur'
$histFile = Join-Path $dataDir 'historique.json'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$hist = @{}
if (Test-Path $histFile) {
    try { (Get-Content $histFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $hist[$_.Name] = [int]$_.Value } } catch {}
}

function ConvertTo-Key([string]$s) {
    # minuscules + sans accents
    $d = $s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    -join ($d.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}

# --- Toutes les applis du menu Demarrer (classiques + Store) ---
$apps = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Id = $_.AppID; Target = $null; Key = (ConvertTo-Key $_.Name); Aliases = @() }
})

# --- Alias : fichier alias.txt a cote du script, lignes "alias = nom de l'appli / chemin / URL" ---
$aliasFile = Join-Path $PSScriptRoot 'alias.txt'
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
foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
    if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
    $alias = ConvertTo-Key $Matches[1]; $cible = $Matches[2]
    $app = $apps | Where-Object { $_.Name -eq $cible } | Select-Object -First 1
    if (-not $app -and $cible -notmatch '[\\/:.]') {
        $app = $apps | Where-Object { -not $_.Target -and $_.Name -like "$cible*" } | Sort-Object { $_.Name.Length } | Select-Object -First 1
    }
    if (-not $app) {
        $app = [pscustomobject]@{ Name = $cible; Id = $cible; Target = $cible; Key = (ConvertTo-Key $cible); Aliases = @() }
        $apps += $app
    }
    $app.Aliases += $alias
}

function Get-Score([string]$n, [string]$q) {
    if ($n -eq $q) { return 1000 }
    if ($n.StartsWith($q)) { return 800 }
    $words = @($n -split '[\s\-_.()]+' | Where-Object { $_ })
    foreach ($w in $words) { if ($w.StartsWith($q)) { return 600 } }
    $initials = -join ($words | ForEach-Object { $_[0] })
    if ($initials.StartsWith($q)) { return 500 }
    if ($n.Contains($q)) { return 400 }
    $i = 0
    foreach ($c in $n.ToCharArray()) { if ($i -lt $q.Length -and $c -eq $q[$i]) { $i++ } }
    if ($i -eq $q.Length) { return 100 }
    return 0
}

# --- Fenetre ---
$bg    = [Drawing.Color]::FromArgb(32, 32, 32)
$bgBox = [Drawing.Color]::FromArgb(50, 50, 50)

$form = New-Object Windows.Forms.Form
$form.Text = 'Lanceur'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(600, 430)
$form.BackColor = $bg
$form.TopMost = $true
$form.Padding = New-Object Windows.Forms.Padding(12)

$list = New-Object Windows.Forms.ListBox
$list.Dock = 'Fill'
$list.Font = New-Object Drawing.Font('Segoe UI', 13)
$list.BackColor = $bg
$list.ForeColor = [Drawing.Color]::Gainsboro
$list.BorderStyle = 'None'
$list.IntegralHeight = $false

$box = New-Object Windows.Forms.TextBox
$box.Dock = 'Top'
$box.Font = New-Object Drawing.Font('Segoe UI', 18)
$box.BackColor = $bgBox
$box.ForeColor = [Drawing.Color]::White
$box.BorderStyle = 'FixedSingle'

$hint = New-Object Windows.Forms.Label
$hint.Dock = 'Bottom'
$hint.Height = 22
$hint.Font = New-Object Drawing.Font('Segoe UI', 9)
$hint.ForeColor = [Drawing.Color]::Gray
$hint.Text = 'Entree : lancer    Haut/Bas : choisir    Echap : fermer    :alias = modifier les alias'

# Fill en premier pour qu'il prenne l'espace restant
$form.Controls.Add($list)
$form.Controls.Add($hint)
$form.Controls.Add($box)

$script:results = @()

function Update-List {
    $q = ConvertTo-Key $box.Text.Trim()
    if (-not $q) {
        $r = $apps | Sort-Object @{ e = { -[int]$hist[$_.Id] } }, Name
    } else {
        $r = $apps | ForEach-Object {
            $s = Get-Score $_.Key $q
            foreach ($al in $_.Aliases) {
                if ($al -eq $q) { $s = [math]::Max($s, 2000) }
                elseif ($al.StartsWith($q)) { $s = [math]::Max($s, 900) }
            }
            if ($s) { [pscustomobject]@{ App = $_; S = $s + [math]::Min(300, 25 * [int]$hist[$_.Id]) } }
        } | Sort-Object S -Descending | ForEach-Object { $_.App }
    }
    $script:results = @($r | Select-Object -First 15)
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($a in $script:results) {
        $label = $a.Name
        if ($a.Aliases.Count) { $label += '    [' + ($a.Aliases -join ', ') + ']' }
        [void]$list.Items.Add($label)
    }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    $list.EndUpdate()
}

function Start-Selected {
    $text = $box.Text.Trim()
    if ($text -eq ':alias') {
        Start-Process notepad.exe "`"$aliasFile`""
    } elseif ($list.SelectedIndex -ge 0 -and $script:results.Count) {
        $app = $script:results[$list.SelectedIndex]
        try {
            if ($app.Target) { Start-Process $app.Target }
            else { Start-Process explorer.exe "shell:AppsFolder\$($app.Id)" }
        } catch {
            [Windows.Forms.MessageBox]::Show("Impossible de lancer : $($app.Name)", 'Lanceur') | Out-Null
            return
        }
        $hist[$app.Id] = [int]$hist[$app.Id] + 1
        try { $hist | ConvertTo-Json | Set-Content -Encoding UTF8 $histFile } catch {}
    } elseif ($text) {
        try { Start-Process $text } catch {
            [Windows.Forms.MessageBox]::Show("Impossible de lancer : $text", 'Lanceur') | Out-Null
            return
        }
    }
    $form.Close()
}

$box.Add_TextChanged({ Update-List })
$box.Add_KeyDown({
    param($s, $e)
    switch ([int]$e.KeyCode) {   # 40 Bas, 38 Haut, 13 Entree, 27 Echap
        40 { if ($list.SelectedIndex -lt $list.Items.Count - 1) { $list.SelectedIndex++ }; $e.SuppressKeyPress = $true }
        38 { if ($list.SelectedIndex -gt 0) { $list.SelectedIndex-- }; $e.SuppressKeyPress = $true }
        13 { $e.SuppressKeyPress = $true; Start-Selected }
        27 { $e.SuppressKeyPress = $true; $form.Close() }
    }
})
$list.Add_DoubleClick({ Start-Selected })
$list.Add_KeyDown({ param($s, $e) if ([int]$e.KeyCode -eq 13) { Start-Selected } elseif ([int]$e.KeyCode -eq 27) { $form.Close() } })
$form.Add_Shown({ $form.Activate(); $box.Focus() })
$form.Add_Deactivate({ $form.Close() })   # se ferme si on clique ailleurs

Update-List
[void]$form.ShowDialog()
