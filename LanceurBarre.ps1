# Barre de recherche posee dans la barre des taches Windows.
# Clique dedans (ou touche Windows seule, ou Ctrl+Alt+Espace), tape, Entree pour lancer.

# ---- Reglages (en pixels "logiques", a 100 % de zoom) ----
$Largeur       = 200     # largeur de la barre de recherche
$MargeDroite   = 290     # utilise seulement si la zone de l'horloge est introuvable
$ToucheWindows = $true   # appui seul sur la touche Windows = ouvre la barre (au lieu du menu Demarrer ; Ctrl+Echap l'ouvre toujours)
# ----------------------------------------------------------

# Une seule instance
$mutex = New-Object Threading.Mutex($false, 'Local\LanceurBarre')
if (-not $mutex.WaitOne(0)) { exit }

# Si on a quitte la barre volontairement, la tache de relance automatique ne la rouvre pas avant le prochain demarrage du PC
$stopFlag = Join-Path $env:APPDATA 'Lanceur\arret_volontaire'
if (Test-Path $stopFlag) {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if ((Get-Item $stopFlag).LastWriteTime -gt $boot -and $args -notcontains '-force') { exit }
    Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;
// Fenetre de suggestions qui s'affiche SANS prendre le clavier (sinon on ne peut plus taper)
public class LanceurPopup : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; return cp; } // NOACTIVATE | TOOLWINDOW | TOPMOST
    }
    // Un clic sur une suggestion ne doit pas activer cette fenetre : sinon la barre recoit Deactivate
    // (qui la vide et cache la liste) avant que le clic n'arrive.
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0021) { m.Result = new IntPtr(3); return; }   // WM_MOUSEACTIVATE -> MA_NOACTIVATE
        base.WndProc(ref m);
    }
}
public class LanceurNative : NativeWindow {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string c, string t);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    public event EventHandler HotKey;
    public LanceurNative() { CreateHandle(new CreateParams()); }
    public bool Register(uint mod, uint vk) { return RegisterHotKey(Handle, 1, mod, vk); }
    protected override void WndProc(ref Message m) {
        if ((m.Msg == 0x0312 || m.Msg == 0x8001) && HotKey != null) HotKey(this, EventArgs.Empty);   // WM_HOTKEY, ou touche Windows (WM_APP+1)
        base.WndProc(ref m);
    }
    // ---- Touche Windows seule : ouvre la barre au lieu du menu Demarrer ----
    // Crochet clavier bas niveau sur son propre thread (la frappe ne rame jamais, meme si la barre est occupee).
    // Win+E, Win+D... marchent toujours : on ne reagit que si la touche Windows est relachee sans autre touche entre-temps.
    delegate IntPtr LLProc(int n, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct KBD { public uint vk, scan, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint msg; public IntPtr w, l; public uint time; public int x, y; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LLProc fn, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    LLProc proc; IntPtr hook, target; bool winDown, other;
    public void StartWinKey() {
        target = Handle; proc = HookProc;
        var t = new System.Threading.Thread(() => {
            hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);   // WH_KEYBOARD_LL
            MSG m; while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
        });
        t.IsBackground = true; t.Start();
    }
    IntPtr HookProc(int n, IntPtr w, IntPtr l) {
        if (n >= 0) {
            var k = (KBD)Marshal.PtrToStructure(l, typeof(KBD));
            if ((k.flags & 0x10) == 0) {   // on ignore les touches simulees (les notres)
                int msg = w.ToInt32();
                bool down = msg == 0x100 || msg == 0x104, up = msg == 0x101 || msg == 0x105;
                if (k.vk == 0x5B || k.vk == 0x5C) {   // touche Windows gauche / droite
                    if (down) { if (!winDown) { winDown = true; other = false; } }
                    else if (up && winDown) {
                        winDown = false;
                        if (!other) {
                            // Une touche "muette" entre l'appui et le relachement : Windows n'ouvre pas le menu Demarrer
                            keybd_event(0xE8, 0, 0, UIntPtr.Zero); keybd_event(0xE8, 0, 2, UIntPtr.Zero);
                            keybd_event((byte)k.vk, 0, 1 | 2, UIntPtr.Zero);   // relachement de la touche Windows (simule)
                            PostMessage(target, 0x8001, IntPtr.Zero, IntPtr.Zero);
                            return new IntPtr(1);   // le vrai relachement est avale
                        }
                    }
                } else if (down && winDown) other = true;
            }
        }
        return CallNextHookEx(hook, n, w, l);
    }
    public static void KeepOnTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
    // Met la fenetre au premier plan, meme quand une autre appli a le clavier
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    public static void Front(IntPtr h) {
        uint pid, ft = GetWindowThreadProcessId(GetForegroundWindow(), out pid), me = GetCurrentThreadId();
        if (ft != 0 && ft != me) { AttachThreadInput(me, ft, true); SetForegroundWindow(h); AttachThreadInput(me, ft, false); }
        else SetForegroundWindow(h);
    }
    // Derniere fenetre utilisee hors de la barre (pour lui rendre le clavier sur Echap)
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    public static IntPtr OtherForeground() {
        IntPtr f = GetForegroundWindow(); uint pid; GetWindowThreadProcessId(f, out pid);
        return (f == IntPtr.Zero || pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) ? IntPtr.Zero : f;
    }
    public static bool Alive(IntPtr h) { return h != IntPtr.Zero && IsWindow(h); }
    public static void Placeholder(IntPtr box, string text) { SendMessage(box, 0x1501, new IntPtr(1), text); }
    // Rectangle de la barre des taches (vide si introuvable)
    public static Rectangle Taskbar() {
        IntPtr t = FindWindow("Shell_TrayWnd", null); RECT r;
        if (t == IntPtr.Zero || !GetWindowRect(t, out r)) return Rectangle.Empty;
        return Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
    }
    // Rattache la fenetre a la barre des taches : une fenetre "possedee" reste toujours au-dessus de son proprietaire,
    // meme quand le menu Demarrer remet la barre des taches au premier plan.
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    public static void AttachToTaskbar(IntPtr h) {
        IntPtr t = FindWindow("Shell_TrayWnd", null);
        if (t != IntPtr.Zero && GetWindowLongPtr(h, -8) != t) SetWindowLongPtr(h, -8, t);   // GWLP_HWNDPARENT
    }
    // Une fenetre (film, jeu, diaporama...) est-elle en plein ecran sur l'ecran principal ?
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static bool FullscreenApp() {
        IntPtr f = GetForegroundWindow(); if (f == IntPtr.Zero) return false;
        uint pid; GetWindowThreadProcessId(f, out pid);
        if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) return false;
        var cls = new System.Text.StringBuilder(64); GetClassName(f, cls, 64);
        string c = cls.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd" || c == "Windows.UI.Core.CoreWindow") return false;
        RECT r; if (!GetWindowRect(f, out r)) return false;
        var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(MonitorFromWindow(f, 2), ref mi) || (mi.dwFlags & 1) == 0) return false;   // ecran principal seulement
        return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
    }
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    public static void Hide(IntPtr h) { ShowWindow(h, 0); }
    public static void ShowNoActivate(IntPtr h) { ShowWindow(h, 4); }
    // Bord gauche de la zone horloge / icones systeme (0 si introuvable)
    public static int TrayLeft() {
        IntPtr t = FindWindow("Shell_TrayWnd", null); if (t == IntPtr.Zero) return 0;
        IntPtr n = FindWindowEx(t, IntPtr.Zero, "TrayNotifyWnd", null); RECT r;
        if (n == IntPtr.Zero || !GetWindowRect(n, out r)) return 0;
        return r.L;
    }
}
// Icone d'une appli (appli du menu Demarrer, fichier ou dossier), avec transparence
[ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm); }
[StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
public static class LanceurIcon {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    public static Bitmap Get(string path, int size) {
        IntPtr hb = IntPtr.Zero;
        try {
            IShellItemImageFactory f;
            SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out f);
            if (f.GetImage(new SIZE { cx = size, cy = size }, 0x4, out hb) != 0) return null;   // SIIGBF_ICONONLY
            using (var src = Image.FromHbitmap(hb)) {
                if (Image.GetPixelFormatSize(src.PixelFormat) < 32) return new Bitmap(src);
                var d = src.LockBits(new Rectangle(0, 0, src.Width, src.Height), ImageLockMode.ReadOnly, src.PixelFormat);
                try { using (var argb = new Bitmap(d.Width, d.Height, d.Stride, PixelFormat.Format32bppArgb, d.Scan0)) return new Bitmap(argb); }
                finally { src.UnlockBits(d); }
            }
        } catch { return null; }
        finally { if (hb != IntPtr.Zero) DeleteObject(hb); }
    }
}
'@
[void][LanceurNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# Journal (demarrage, arret, lancements, erreurs) dans %APPDATA%\Lanceur\barre.log
$journal = Join-Path $env:APPDATA 'Lanceur\barre.log'
New-Item -ItemType Directory -Force (Split-Path $journal) | Out-Null
function Write-Journal([string]$m) {
    try {
        if ((Test-Path $journal) -and (Get-Item $journal).Length -gt 200KB) { Remove-Item $journal -Force }
        Add-Content -Path $journal -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) -Encoding UTF8
    } catch {}
}
Write-Journal "Demarrage (PID $PID)"
# Une erreur dans la barre ne doit jamais la fermer : on la note et on continue
[Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Journal "Erreur : $($e.Exception.Message)" })

. (Join-Path $PSScriptRoot 'LanceurCore.ps1')

$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96; $g.Dispose()
$bg     = [Drawing.Color]::FromArgb(45, 45, 45)
$bgPop  = [Drawing.Color]::FromArgb(32, 32, 32)
$selCol = [Drawing.Color]::FromArgb(60, 90, 140)
$brBg   = New-Object Drawing.SolidBrush($bgPop)
$brSel  = New-Object Drawing.SolidBrush($selCol)

# ---- Icones (avec cache) ----
$script:icons = @{}
$script:iconParChemin = @{}
$iconPx = [int](32 * $scale)
function Get-AppIcon($a) {
    if (-not $a) { return $null }
    if ($script:icons.ContainsKey($a.Id)) { return $script:icons[$a.Id] }
    $path = $null
    if ($a.IconPath) { $path = $a.IconPath }   # Panneau de configuration / Parametres
    elseif ($a.Target) {
        $t = [Environment]::ExpandEnvironmentVariables($a.Target)
        if (Test-Path -LiteralPath $t -ErrorAction SilentlyContinue) { $path = (Resolve-Path -LiteralPath $t).Path }
        else { $cmd = Get-Command $t -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($cmd) { $path = $cmd.Source } }
    } else { $path = "shell:AppsFolder\$($a.Id)" }
    # Meme fichier d'icone pour beaucoup d'entrees (taches, pages Parametres) : extrait une seule fois
    if ($path -and $script:iconParChemin.ContainsKey($path)) { $img = $script:iconParChemin[$path] }
    else { $img = if ($path) { [LanceurIcon]::Get($path, $iconPx) } else { $null }; if ($path) { $script:iconParChemin[$path] = $img } }
    $script:icons[$a.Id] = $img
    $img
}

# Une icone coute ~25 ms la premiere fois : on les precharge toutes en fond (les plus utilisees d'abord),
# deux par tick et jamais pendant la frappe, pour que les suggestions s'affichent toujours instantanement.
$script:fileIcones = New-Object Collections.Queue
$prechargement = New-Object Windows.Forms.Timer
$prechargement.Interval = 20
$prechargement.Add_Tick({
    if ($box.Focused -and $box.Text) { return }
    for ($n = 0; $n -lt 2 -and $script:fileIcones.Count; $n++) { [void](Get-AppIcon $script:fileIcones.Dequeue()) }
    if (-not $script:fileIcones.Count) { $prechargement.Stop() }
})
function Start-PrechargementIcones {
    $script:fileIcones.Clear()
    foreach ($a in ($script:apps | Sort-Object { -[int]$script:hist[$_.Id] })) {
        if (-not $script:icons.ContainsKey($a.Id)) { $script:fileIcones.Enqueue($a) }
    }
    if ($script:fileIcones.Count) { $prechargement.Start() }
}

# Loupe dessinee une fois (icone de la barre quand rien n'est tape)
function New-Loupe([int]$s) {
    $b = New-Object Drawing.Bitmap($s, $s)
    $gr = [Drawing.Graphics]::FromImage($b); $gr.SmoothingMode = 'AntiAlias'
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(200, 200, 200), [single]([Math]::Max(1.5, $s / 11)))
    $d = $s * 0.58; $o = $s * 0.08
    $gr.DrawEllipse($pen, [single]$o, [single]$o, [single]$d, [single]$d)
    $gr.DrawLine($pen, [single]($o + $d * 0.85), [single]($o + $d * 0.85), [single]($s * 0.92), [single]($s * 0.92))
    $gr.Dispose(); $b
}

# ---- La barre ----
$bar = New-Object Windows.Forms.Form
$bar.AutoScaleMode = 'None'
$bar.FormBorderStyle = 'None'
$bar.ShowInTaskbar = $false
$bar.StartPosition = 'Manual'
$bar.TopMost = $true
$bar.BackColor = $bg
$bar.MinimumSize = New-Object Drawing.Size(1, 1)

$pic = New-Object Windows.Forms.PictureBox
$pic.SizeMode = 'Zoom'
$pic.BackColor = $bg
$bar.Controls.Add($pic)

$box = New-Object Windows.Forms.TextBox
$box.BorderStyle = 'None'
$box.BackColor = $bg
$box.ForeColor = [Drawing.Color]::White
$box.Font = New-Object Drawing.Font('Segoe UI', 10)
$bar.Controls.Add($box)

$script:loupe = $null
$script:lay = $null

# Place la barre dans la barre des taches, juste a gauche de l'horloge.
# Appele en continu : se recale si la barre des taches n'etait pas prete au demarrage, ou si l'ecran change.
function Update-Layout {
    # Hauteur/position verticale : ecran - zone de travail (stable). Gere la barre des taches en haut OU en bas.
    # La fenetre Shell_TrayWnd, elle, s'agrandit parfois (menu des icones cachees, animations) : dernier recours seulement.
    $scr = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $wa  = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $enHaut = $false
    if ($wa.Top -gt $scr.Top) { $enHaut = $true; $hgt = $wa.Top - $scr.Top }
    elseif ($wa.Bottom -lt $scr.Bottom) { $hgt = $scr.Bottom - $wa.Bottom }
    else {
        # barre des taches masquee automatiquement : on regarde ou est Shell_TrayWnd
        $t = [LanceurNative]::Taskbar()
        $enHaut = (-not $t.IsEmpty) -and ($t.Top -le $scr.Top + 2) -and ($t.Bottom -lt $scr.Bottom - 2)
        $hgt = if (-not $t.IsEmpty) { $t.Height } else { 0 }
    }
    if ($hgt -lt 20 -or $hgt -gt 120 * $scale) { $hgt = [int](48 * $scale) }   # pas encore prete
    $tbY = if ($enHaut) { $scr.Top } else { $scr.Bottom - $hgt }
    $tb = New-Object Drawing.Rectangle($scr.Left, $tbY, $scr.Width, $hgt)
    $script:tbEnHaut = $enHaut; $script:tbBottom = $tb.Bottom
    $w = [int]($Largeur * $scale)
    $h = [int]([Math]::Min($tb.Height * 0.66, 36 * $scale))
    $right = [LanceurNative]::TrayLeft()
    if ($right -le $tb.Left + $w -or $right -gt $tb.Right) { $right = $tb.Right - [int]($MargeDroite * $scale) }
    $x = $right - $w - [int](8 * $scale)
    $y = $tb.Top + [int](($tb.Height - $h) / 2)
    $want = New-Object Drawing.Rectangle($x, $y, $w, $h)
    $key = "$x,$y,$w,$h,$($tb.Top)"
    if ($key -eq $script:lay) {
        # Windows deplace parfois la fenetre tout seul (vers la zone de travail) : on la remet a sa place
        if (-not $bar.Bounds.Equals($want)) { $bar.Bounds = $want; Write-Journal "Replacee (Windows l'avait deplacee)" }
        return
    }
    $script:lay = $key
    $script:tbTop = $tb.Top; $script:barX = $x
    $bar.Bounds = $want
    # coins arrondis
    $r = [int](8 * $scale); $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $p.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $p.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90); $p.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
    $p.CloseFigure(); $bar.Region = New-Object Drawing.Region($p)
    # icone a gauche, texte a droite
    $is = [int]($h * 0.58)
    $pic.Bounds = New-Object Drawing.Rectangle([int](8 * $scale), [int](($h - $is) / 2), $is, $is)
    $script:loupe = New-Loupe $is
    if (-not $box.Text) { $pic.Image = $script:loupe }
    $bx = $pic.Right + [int](6 * $scale)
    $box.Left = $bx
    $box.Width = $w - $bx - [int](8 * $scale)
    $box.Top = [int](($h - $box.Height) / 2)
}

$bar.Add_Load({ Update-Layout; [LanceurNative]::AttachToTaskbar($bar.Handle); [LanceurNative]::Placeholder($box.Handle, 'Rechercher...'); Start-PrechargementIcones })

# ---- Le menu de suggestions (au-dessus ou au-dessous de la barre) ----
$pop = New-Object LanceurPopup
$pop.AutoScaleMode = 'None'
$pop.FormBorderStyle = 'None'
$pop.ShowInTaskbar = $false
$pop.StartPosition = 'Manual'
$pop.BackColor = $bgPop
$pop.Padding = New-Object Windows.Forms.Padding([int](6 * $scale))
$popW = [int](380 * $scale)

$list = New-Object Windows.Forms.ListBox
$list.Dock = 'Fill'
$list.Font = New-Object Drawing.Font('Segoe UI', 11)
$list.BackColor = $bgPop
$list.ForeColor = [Drawing.Color]::Gainsboro
$list.BorderStyle = 'None'
$list.IntegralHeight = $false
$list.DrawMode = 'OwnerDrawFixed'
$list.ItemHeight = [int](34 * $scale)
$policeEtiquette = New-Object Drawing.Font('Segoe UI', 8)
$pop.Controls.Add($list)

# Dessin d'une ligne : icone + nom (+ type a droite)
$list.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0 -or $e.Index -ge $script:results.Count) { return }
    $gr = $e.Graphics
    $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $gr.FillRectangle($(if ($sel) { $brSel } else { $brBg }), $e.Bounds)
    $isz = [int](24 * $scale); $pad = [int](8 * $scale)
    $ico = Get-AppIcon $script:results[$e.Index]
    if ($ico) {
        $gr.InterpolationMode = 'HighQualityBicubic'
        $gr.DrawImage($ico, $e.Bounds.X + $pad, $e.Bounds.Y + [int](($e.Bounds.Height - $isz) / 2), $isz, $isz)
    }
    $tx = $e.Bounds.X + $pad * 2 + $isz
    $right = $e.Bounds.Right - $pad
    # Etiquette grise a droite pour tout ce qui n'est pas une appli ("Parametres", "Raccourci"...)
    $type = $script:results[$e.Index].Type
    if ($type -and $type -ne 'Appli') {
        $kw = [Windows.Forms.TextRenderer]::MeasureText($type, $policeEtiquette).Width
        $kr = New-Object Drawing.Rectangle(($right - $kw), $e.Bounds.Y, $kw, $e.Bounds.Height)
        $fl = [Windows.Forms.TextFormatFlags]'VerticalCenter, Right, SingleLine, NoPrefix'
        [Windows.Forms.TextRenderer]::DrawText($gr, $type, $policeEtiquette, $kr, $(if ($sel) { [Drawing.Color]::LightGray } else { [Drawing.Color]::Gray }), $fl)
        $right -= $kw + $pad
    }
    $rect = New-Object Drawing.Rectangle($tx, $e.Bounds.Y, ($right - $tx), $e.Bounds.Height)
    $col = if ($sel) { [Drawing.Color]::White } else { [Drawing.Color]::Gainsboro }
    $flags = [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix'
    [Windows.Forms.TextRenderer]::DrawText($gr, [string]$list.Items[$e.Index], $list.Font, $rect, $col, $flags)
})

$script:results = @()
$script:aliasMode = $null
$fleche = [string][char]0x2192

function Update-BarIcon {
    $i = $list.SelectedIndex
    $img = if ($box.Text -and $i -ge 0 -and $i -lt $script:results.Count) { Get-AppIcon $script:results[$i] } else { $null }
    $pic.Image = if ($img) { $img } else { $script:loupe }
}
$list.Add_SelectedIndexChanged({ Update-BarIcon })

function Show-Results {
    # @(...) : garde un tableau meme avec un seul resultat
    # "ch=chrome" : mode creation d'alias
    if ($box.Text -match '^\s*([^=]+?)\s*=\s*(.*)$') {
        $script:aliasMode = $Matches[1]
        $script:results = @(Find-Apps $Matches[2] 10)
    } else {
        $script:aliasMode = $null
        $script:results = @(Find-Apps $box.Text 10)
    }
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($a in $script:results) {
        if ($script:aliasMode) { [void]$list.Items.Add("Alias  $($script:aliasMode)  $fleche  $($a.Name)") }
        else { [void]$list.Items.Add((Get-AppLabel $a)) }
    }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    $list.EndUpdate()
    Update-BarIcon
    if (-not $list.Items.Count) { $pop.Hide(); return }
    $ph = $list.Items.Count * $list.ItemHeight + [int](12 * $scale) + 4   # +4 : evite une barre de defilement inutile
    $px = [Math]::Min($script:barX, [Windows.Forms.Screen]::PrimaryScreen.Bounds.Right - $popW - 4)
    # Barre des taches en haut : suggestions en dessous ; en bas : au-dessus
    $py = if ($script:tbEnHaut) { $script:tbBottom + [int](6 * $scale) } else { $script:tbTop - $ph - [int](6 * $scale) }
    $pop.Bounds = New-Object Drawing.Rectangle($px, $py, $popW, $ph)
    if (-not $pop.Visible) { $pop.Show() }
    [LanceurNative]::AttachToTaskbar($pop.Handle)
    [LanceurNative]::KeepOnTop($pop.Handle)
    if (-not $box.Focused) { $box.Focus() }
}

function Reset-Bar { $box.Text = ''; $pop.Hide(); $pic.Image = $script:loupe }

# Petit message temporaire affiche dans la barre vide
$flashTimer = New-Object Windows.Forms.Timer
$flashTimer.Interval = 2500
$flashTimer.Add_Tick({ $flashTimer.Stop(); [LanceurNative]::Placeholder($box.Handle, 'Rechercher...') })
function Show-Flash([string]$msg) {
    [LanceurNative]::Placeholder($box.Handle, $msg)
    $flashTimer.Stop(); $flashTimer.Start()
}

function Start-Choice {
    $app = if ($list.SelectedIndex -ge 0 -and $script:results.Count) { $script:results[$list.SelectedIndex] } else { $null }
    if ($box.Text.Trim() -eq ':alias') { Reset-Bar; Show-AliasManager; return }
    if ($script:aliasMode) {
        $alias = $script:aliasMode
        $cible = if ($app) { $app.Name } else { ($box.Text -split '=', 2)[1] }
        if ($cible.Trim()) {
            Add-Alias $alias $cible
            Reset-Bar
            Show-Flash ([char]0x2713 + " $alias $fleche $cible")
        }
        return
    }
    if (Invoke-Launch $app $box.Text) { Reset-Bar }
}

# Clic droit sur une suggestion : lui donner un alias
$itemMenu = New-Object Windows.Forms.ContextMenuStrip
[void]$itemMenu.Items.Add('Donner un alias a cette appli', $null, {
    $i = $list.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:results.Count) {
        # Prepare "=NomAppli" dans la barre, curseur au debut : il suffit de taper l'alias puis Entree
        $name = $script:results[$i].Name
        $pop.Hide()
        [LanceurNative]::Front($bar.Handle)
        $box.Focus()
        $box.Text = "=$name"
        $box.SelectionStart = 0
        $box.SelectionLength = 0
    }
})
$list.ContextMenuStrip = $itemMenu
$list.Add_MouseDown({ if ($_.Button -eq 'Right') { $i = $list.IndexFromPoint($_.Location); if ($i -ge 0) { $list.SelectedIndex = $i } } })

$box.Add_GotFocus({ $n = $script:apps.Count; Update-AppsIfStale; if ($script:apps.Count -ne $n) { Start-PrechargementIcones }; if ($box.Text) { Show-Results } })
$box.Add_TextChanged({ if ($box.Text) { Show-Results } else { $pop.Hide(); $pic.Image = $script:loupe } })
$box.Add_KeyDown({
    param($s, $e)
    # Ctrl+Espace : vide le champ en gardant le curseur dedans
    if ($e.Control -and -not $e.Alt -and [int]$e.KeyCode -eq 32) { $e.SuppressKeyPress = $true; Reset-Bar; return }
    # Ctrl+Retour arriere : efface le mot precedent, comme partout
    # (par defaut une TextBox WinForms insere un caractere carre bizarre)
    if ($e.Control -and -not $e.Alt -and [int]$e.KeyCode -eq 8) {
        $e.SuppressKeyPress = $true
        $p = $box.SelectionStart
        if ($box.SelectionLength) { $box.SelectedText = ''; return }
        $avant = $box.Text.Substring(0, $p) -replace '\S*\s*$', ''
        $box.Text = $avant + $box.Text.Substring($p)
        $box.SelectionStart = $avant.Length
        return
    }
    switch ([int]$e.KeyCode) {   # 40 Bas, 38 Haut, 13 Entree, 27 Echap
        40 { if (-not $pop.Visible) { Show-Results } elseif ($list.SelectedIndex -lt $list.Items.Count - 1) { $list.SelectedIndex++ }; $e.SuppressKeyPress = $true }
        38 { if ($list.SelectedIndex -gt 0) { $list.SelectedIndex-- }; $e.SuppressKeyPress = $true }
        13 { $e.SuppressKeyPress = $true; Start-Choice }
        27 {   # Echap : vide la barre et rend le clavier a la fenetre d'avant
            $e.SuppressKeyPress = $true; Reset-Bar
            if ([LanceurNative]::Alive($script:fenAvant)) { [LanceurNative]::Front($script:fenAvant) }
        }
    }
})
# Lance au relachement du bouton gauche (MouseClick n'arrive pas toujours sur cette fenetre non activable)
$list.Add_MouseUp({ if ($_.Button -ne 'Left') { return }; $i = $list.IndexFromPoint($_.Location); if ($i -ge 0) { $list.SelectedIndex = $i; Start-Choice } })
$bar.Add_MouseDown({ [LanceurNative]::Front($bar.Handle); $box.Focus() })
$pic.Add_MouseDown({ [LanceurNative]::Front($bar.Handle); $box.Focus() })
$box.Add_MouseDown({ [LanceurNative]::Front($bar.Handle) })

# Clic ailleurs : vide la barre et cache les suggestions
# (sauf un clic sur la liste elle-meme : il doit arriver jusqu'a elle pour lancer l'appli)
$bar.Add_Deactivate({
    if ($pop.Visible -and $pop.Bounds.Contains([Windows.Forms.Control]::MousePosition)) { return }
    Reset-Bar
})

# Rester au-dessus de la barre des taches, et bien place
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$script:cachee = $false
$script:fenAvant = [IntPtr]::Zero
$timer.Add_Tick({
    $f = [LanceurNative]::OtherForeground(); if ($f -ne [IntPtr]::Zero) { $script:fenAvant = $f }
    # Plein ecran (film, jeu...) : la barre des taches s'efface, la barre de recherche aussi
    if ([LanceurNative]::FullscreenApp()) {
        if (-not $script:cachee) { $pop.Hide(); [LanceurNative]::Hide($bar.Handle); $script:cachee = $true }
        return
    }
    if ($script:cachee) { [LanceurNative]::ShowNoActivate($bar.Handle); $script:cachee = $false }
    Update-Layout
    [LanceurNative]::AttachToTaskbar($bar.Handle)   # refait si l'Explorateur a redemarre
    [LanceurNative]::KeepOnTop($bar.Handle)
})
$timer.Start()

# Rafraichir la liste des apps toutes les 30 min, seulement quand on n'est pas en train de taper
$refresh = New-Object Windows.Forms.Timer
$refresh.Interval = 30 * 60 * 1000
$refresh.Add_Tick({ if (-not $box.Focused) { Import-Apps; Start-PrechargementIcones } })   # cache d'icones garde : seules les nouvelles sont chargees
$refresh.Start()

# Raccourci global Ctrl+Alt+Espace, et touche Windows seule (si activee en haut du fichier)
$hk = New-Object LanceurNative
[void]$hk.Register(0x0002 -bor 0x0001 -bor 0x4000, 0x20)   # CTRL | ALT | NOREPEAT, ESPACE
if ($ToucheWindows) { $hk.StartWinKey() }
$hk.add_HotKey({
    $f = [LanceurNative]::OtherForeground(); if ($f -ne [IntPtr]::Zero) { $script:fenAvant = $f }
    if ($script:cachee) { [LanceurNative]::ShowNoActivate($bar.Handle); $script:cachee = $false }
    [LanceurNative]::Front($bar.Handle); $bar.Activate(); $box.Focus(); $box.SelectAll()
})

# Menu clic droit : quitter / modifier les alias
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Gerer les alias...', $null, { Reset-Bar; Show-AliasManager })
[void]$menu.Items.Add('Ouvrir le dossier des raccourcis', $null, { Reset-Bar; Start-Process explorer.exe "`"$raccourcisDir`"" })
[void]$menu.Items.Add('Actualiser la liste des apps', $null, { Import-Apps; $script:icons = @{}; $script:iconParChemin = @{}; Start-PrechargementIcones })
[void]$menu.Items.Add('Quitter la barre', $null, { Write-Journal 'Quitter (menu)'; Set-Content $stopFlag '' -ErrorAction SilentlyContinue; $bar.Close() })
$bar.ContextMenuStrip = $menu
$box.ContextMenuStrip = $menu
$pic.ContextMenuStrip = $menu

try { [Windows.Forms.Application]::Run($bar) }
catch { Write-Journal "Arret sur erreur : $($_.Exception.Message)" }
Write-Journal 'Arret'
$mutex.ReleaseMutex()
