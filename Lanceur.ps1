# Lanceur rapide (fenetre) : tape le nom d'une appli, Entree pour la lancer.
# Haut/Bas : choisir   Entree : lancer   Echap : fermer
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Meme liste d'applis, recherche, alias et historique que la barre
. (Join-Path $PSScriptRoot 'LanceurCore.ps1')

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
    $script:results = @(Find-Apps $box.Text 15)
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($a in $script:results) {
        $label = Get-AppLabel $a
        if ($a.Type -ne 'Appli') { $label += "    ($($a.Type))" }
        [void]$list.Items.Add($label)
    }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    $list.EndUpdate()
}

function Start-Selected {
    $app = if ($list.SelectedIndex -ge 0 -and $script:results.Count) { $script:results[$list.SelectedIndex] } else { $null }
    if ($box.Text.Trim() -eq ':alias') { $form.Hide(); Show-AliasManager; $form.Close(); return }
    if (Invoke-Launch $app $box.Text) { $form.Close() }
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
$form.Add_Deactivate({ if ($form.Visible) { $form.Close() } })   # se ferme si on clique ailleurs

Update-List
[void]$form.ShowDialog()
