# =================================================================
#  Claude Launcher - tray application
#  Tape quelques lettres, filtre tes projets (ProjectsRoot),
#  Entree => ouvre PowerShell + claude dans le dossier choisi.
# =================================================================

# ----- Configuration --------------------------------------------
# Toute la conf est dans config.json (a cote du script).
# Si le fichier n'existe pas, il est cree avec les valeurs par defaut.
# ----------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ----- Instance unique ------------------------------------------
# Un mutex nomme empeche de lancer deux fois l'app (deux icones dans la traybar).
$script:Mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeLauncher_SingleInstance")
$hasMutex = $false
try {
    $hasMutex = $script:Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $hasMutex = $true   # l'instance precedente a plante sans liberer le mutex
}
if (-not $hasMutex) {
    [System.Windows.Forms.MessageBox]::Show(
        "Claude Launcher est deja lance (voir la zone de notification).",
        "Claude Launcher", 'OK', 'Information') | Out-Null
    exit
}

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$IconPath   = Join-Path $ScriptDir "icon.ico"
$ConfigPath = Join-Path $ScriptDir "config.json"

# Valeurs par defaut (utilisees si config.json absent ou cle manquante)
$DefaultConfig = [ordered]@{
    ProjectsRoot     = "C:\wamp64\www"
    SearchDepth      = 1
    ExcludeFolders   = @(".git", "node_modules", "vendor")   # le dossier du launcher est exclu automatiquement
    ClaudeCommand    = "claude"
    ChromeUrlPattern = "http://127.0.0.1/{name}"
    HideAutomatedSessions = $true   # masque les sessions lancees par script (claude -p)
    Shell            = "auto"       # auto = pwsh.exe (PowerShell 7) si present, sinon powershell.exe
}

function Load-Config {
    # Cree config.json avec les defauts si absent
    if (-not (Test-Path $ConfigPath)) {
        try {
            $DefaultConfig | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Impossible de creer config.json :`n$($_.Exception.Message)",
                "Claude Launcher", 'OK', 'Warning') | Out-Null
        }
    }
    # Lit le fichier ; fusionne avec les defauts pour les cles absentes
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    if (Test-Path $ConfigPath) {
        try {
            $loaded = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $DefaultConfig.Keys) {
                if ($loaded.PSObject.Properties.Name -contains $k -and $null -ne $loaded.$k) {
                    $cfg[$k] = $loaded.$k
                }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "config.json est invalide, utilisation des valeurs par defaut :`n$($_.Exception.Message)",
                "Claude Launcher", 'OK', 'Warning') | Out-Null
        }
    }
    return $cfg
}

$cfg              = Load-Config
$ProjectsRoot     = ([string]$cfg.ProjectsRoot).TrimEnd('\', '/')
if ($ProjectsRoot -match ':$') { $ProjectsRoot += '\' }   # racine de lecteur : "C:" -> "C:\"
# SearchDepth : au minimum 1 (0 ou negatif ferait planter Get-ChildItem -Depth)
$SearchDepth      = 1
try { $SearchDepth = [Math]::Max(1, [int]$cfg.SearchDepth) } catch { $SearchDepth = 1 }
$ExcludeFolders   = @($cfg.ExcludeFolders)
$ClaudeCommand    = [string]$cfg.ClaudeCommand
$ChromeUrlPattern = [string]$cfg.ChromeUrlPattern
$HideAutomatedSessions = [bool]$cfg.HideAutomatedSessions
$Shell            = [string]$cfg.Shell

# Lecture des sessions Claude Code locales (fonctions sans UI)
. (Join-Path $ScriptDir "ClaudeSessions.ps1")

# ===== Tray icon ================================================
$notify = New-Object System.Windows.Forms.NotifyIcon
if (Test-Path $IconPath) {
    $notify.Icon = New-Object System.Drawing.Icon($IconPath)
} else {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}
$notify.Text    = "Claude Launcher"
$notify.Visible = $true

$menu     = New-Object System.Windows.Forms.ContextMenuStrip
$mOpen    = $menu.Items.Add("Ouvrir le launcher")
$mSessions = $menu.Items.Add("Sessions Claude")
$mRoot    = $menu.Items.Add("Ouvrir $ProjectsRoot")
$mLocal   = $menu.Items.Add("Ouvrir http://127.0.0.1 dans Chrome")
$mRefresh = $menu.Items.Add("Rafraichir la liste")
[void]$menu.Items.Add("-")
$mExit    = $menu.Items.Add("Quitter")
$notify.ContextMenuStrip = $menu

# ===== Search form ==============================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Claude Launcher"
$form.Size            = New-Object System.Drawing.Size(520, 480)
$form.StartPosition   = "Manual"
$form.FormBorderStyle = "FixedToolWindow"
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.KeyPreview      = $true
$form.BackColor       = [System.Drawing.Color]::FromArgb(245, 245, 245)

$label = New-Object System.Windows.Forms.Label
$label.Location = New-Object System.Drawing.Point(12, 8)
$label.Size     = New-Object System.Drawing.Size(490, 18)
$label.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($label)

$textbox = New-Object System.Windows.Forms.TextBox
$textbox.Location    = New-Object System.Drawing.Point(12, 28)
$textbox.Size        = New-Object System.Drawing.Size(490, 28)
$textbox.Font        = New-Object System.Drawing.Font("Segoe UI", 13)
$textbox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle   # bordure plate (pas de liseret bleu 3D)
$form.Controls.Add($textbox)

$listbox = New-Object System.Windows.Forms.ListBox
$listbox.Location       = New-Object System.Drawing.Point(12, 62)
$listbox.Size           = New-Object System.Drawing.Size(490, 360)
$listbox.Font           = New-Object System.Drawing.Font("Segoe UI", 11)
$listbox.IntegralHeight = $false
$listbox.BorderStyle    = [System.Windows.Forms.BorderStyle]::FixedSingle
$listbox.DrawMode       = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$listbox.ItemHeight     = 26    # un peu plus aere
$form.Controls.Add($listbox)

# Couleurs pour le rendu en zebra
$colorRowEven = [System.Drawing.Color]::White
$colorRowOdd  = [System.Drawing.Color]::FromArgb(245, 245, 245)   # gris clair
$colorSelBg   = [System.Drawing.Color]::FromArgb(204, 120, 92)    # coral Claude
$colorSelFg   = [System.Drawing.Color]::White
$colorText    = [System.Drawing.Color]::FromArgb(35, 35, 35)
$colorMeta    = [System.Drawing.Color]::FromArgb(130, 130, 130)
$colorMetaSel = [System.Drawing.Color]::FromArgb(255, 235, 225)
$fontMeta     = New-Object System.Drawing.Font("Segoe UI", 9)

# Texte sur une ligne, tronque avec "..." s'il deborde
$fmtEllipsis = New-Object System.Drawing.StringFormat
$fmtEllipsis.Trimming    = [System.Drawing.StringTrimming]::EllipsisCharacter
$fmtEllipsis.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

$listbox.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0

    if ($isSelected) {
        $bg = $colorSelBg
        $fg = $colorSelFg
    } elseif ($e.Index % 2 -eq 0) {
        $bg = $colorRowEven
        $fg = $colorText
    } else {
        $bg = $colorRowOdd
        $fg = $colorText
    }

    # Fond
    $brushBg = New-Object System.Drawing.SolidBrush($bg)
    $e.Graphics.FillRectangle($brushBg, $e.Bounds)
    $brushBg.Dispose()

    $item = $listbox.Items[$e.Index]
    $x    = [single]($e.Bounds.X + 10)
    $w    = [single]($e.Bounds.Width - 20)

    # Session : "projet - il y a 2 h" en gris a droite, titre tronque a gauche
    if ($item.Kind -eq 'session') {
        $meta      = "$($item.Project)  -  $(Format-RelativeDate $item.LastActivity)"
        $metaW     = [Math]::Min($w * 0.45, $e.Graphics.MeasureString($meta, $fontMeta).Width + 4)
        $brushMeta = New-Object System.Drawing.SolidBrush($(if ($isSelected) { $colorMetaSel } else { $colorMeta }))
        $metaRect  = New-Object System.Drawing.RectangleF(([single]($x + $w - $metaW)), ([single]($e.Bounds.Y + 6)), ([single]$metaW), ([single]$e.Bounds.Height))
        $e.Graphics.DrawString($meta, $fontMeta, $brushMeta, $metaRect, $fmtEllipsis)
        $brushMeta.Dispose()
        $w = [single]($w - $metaW - 8)
    }

    # Texte principal avec padding gauche
    $brushFg = New-Object System.Drawing.SolidBrush($fg)
    $textRect = New-Object System.Drawing.RectangleF($x, ([single]($e.Bounds.Y + 3)), $w, ([single]$e.Bounds.Height))
    $e.Graphics.DrawString([string]$item.Display, $listbox.Font, $brushFg, $textRect, $fmtEllipsis)
    $brushFg.Dispose()
})

$status = New-Object System.Windows.Forms.Label
$status.Location  = New-Object System.Drawing.Point(12, 428)
$status.Size      = New-Object System.Drawing.Size(490, 18)
$status.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($status)

# ===== Data & helpers ===========================================
$script:AllFolders = @()

function Refresh-Folders {
    $list = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $ProjectsRoot) {
        $selfDir = $ScriptDir.TrimEnd('\')
        # Parcours manuel : on ne descend PAS dans les dossiers exclus
        # (node_modules, vendor...) et le dossier du launcher est toujours ignore.
        # Le chemin relatif est construit au fil du parcours (pas de Substring :
        # chemin court "UTILIS~1" vs chemin long ne font pas la meme longueur).
        $walk = {
            param([string]$dir, [int]$level, [string]$prefix)
            Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($ExcludeFolders -contains $_.Name) { return }
                # Dossier du launcher : par chemin, ou par la presence du script
                # (couvre le cas chemin court / chemin long)
                if ($_.FullName.TrimEnd('\') -ieq $selfDir -or
                    (Test-Path -LiteralPath (Join-Path $_.FullName 'ClaudeLauncher.ps1'))) { return }
                $rel = if ($prefix) { "$prefix\$($_.Name)" } else { $_.Name }
                $display = $(if ($SearchDepth -gt 1) { $rel } else { $_.Name })
                $list.Add([PSCustomObject]@{
                    Kind    = 'project'
                    Name    = $_.Name
                    Path    = $_.FullName
                    RelPath = $rel
                    # Avec SearchDepth > 1, on affiche le chemin relatif pour
                    # distinguer les homonymes (deux "src", deux "app"...).
                    Display    = $display
                    SearchText = $display
                })
                if ($level -lt $SearchDepth) { & $walk $_.FullName ($level + 1) $rel }
            }
        }
        & $walk $ProjectsRoot 1 ''
    }
    $script:AllFolders = @($list | Sort-Object Display)
}

$script:AllSessions = @()
$script:Mode        = 'projects'   # 'projects' ou 'sessions' (Tab pour basculer)

function Refresh-Sessions {
    $status.Text = "Chargement des sessions Claude..."
    $status.Refresh()
    $script:AllSessions = Get-ClaudeSessions -HideAutomated:$HideAutomatedSessions
}

function Get-CurrentItems {
    if ($script:Mode -eq 'sessions') { return $script:AllSessions } else { return $script:AllFolders }
}

function Update-List {
    param([string]$Filter)
    $all = @(Get-CurrentItems)
    $listbox.BeginUpdate()
    try {
        $listbox.Items.Clear()
        $needle = $Filter.Trim()
        if ([string]::IsNullOrEmpty($needle)) {
            $found = $all
        } else {
            # Recherche litterale (pas de -like : "[" ou "*" casseraient le filtre).
            # Sessions : titre, projet, branche, premier et dernier message.
            $found = $all | Where-Object {
                $_.SearchText.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        }
        foreach ($m in $found) { [void]$listbox.Items.Add($m) }
        if ($listbox.Items.Count -gt 0) { $listbox.SelectedIndex = 0 }
    } finally {
        $listbox.EndUpdate()
    }
    Update-Status
}

function Update-Status {
    $what = if ($script:Mode -eq 'sessions') { 'session(s)' } else { 'dossier(s)' }
    $text = "$($listbox.Items.Count) $what  /  total: $(@(Get-CurrentItems).Count)"
    $entry = Get-SelectedEntry
    if ($entry -and $entry.Kind -eq 'session') {
        # Detail de la session selectionnee : branche et date exacte
        $branch = if ($entry.Branch -and $entry.Branch -ne 'HEAD') { "$($entry.Branch)  -  " } else { '' }
        $text = "$text   |   $branch$($entry.LastActivity.ToString('dd/MM/yyyy HH:mm'))"
    }
    $status.Text = $text
}

function Set-Mode {
    param([string]$Mode)
    $script:Mode = $Mode
    if ($Mode -eq 'sessions') {
        Refresh-Sessions
        $label.Text = "SESSIONS  -  Entree = reprendre  -  Shift+Entree = Explorateur  -  Tab = projets"
        $form.Text  = "Claude Launcher - sessions"
    } else {
        $label.Text = "Entree = Claude  -  Ctrl+Entree = Chrome  -  Shift+Entree = Explorateur  -  Tab = sessions"
        $form.Text  = "Claude Launcher"
    }
    # Le texte tape est conserve : taper "naturhouse" puis Tab montre les
    # sessions de ce projet.
    Update-List $textbox.Text
}

function Get-SelectedEntry {
    if ($listbox.SelectedIndex -lt 0) { return $null }
    return $listbox.SelectedItem
}

function Get-SessionCommand {
    param($Entry)
    # L'id vient du nom de fichier (GUID) : pas de caractere a echapper
    return "$ClaudeCommand --resume $($Entry.Id)"
}

function Get-ShellExe {
    # Shell utilise pour lancer claude (cle "Shell" de config.json) :
    #   "auto"       => pwsh.exe (PowerShell 7) s'il est installe, sinon powershell.exe
    #   "pwsh"       => PowerShell 7
    #   "powershell" => Windows PowerShell 5.1
    #   autre valeur => nom ou chemin d'un executable (doit accepter -NoExit -Command)
    $wanted = switch ($Shell.Trim().ToLower()) {
        ''           { @('pwsh.exe', 'powershell.exe') }
        'auto'       { @('pwsh.exe', 'powershell.exe') }
        'pwsh'       { @('pwsh.exe', 'powershell.exe') }
        'powershell' { @('powershell.exe') }
        default      { @($Shell, 'powershell.exe') }
    }
    foreach ($name in $wanted) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return 'powershell.exe'
}

function Start-ClaudeIn {
    param([string]$Path, [string]$Command)
    $shellExe = Get-ShellExe
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        # Windows Terminal : ouvre un onglet dans le dossier et lance la commande.
        # wt interprete ";" comme separateur de commandes : on l'echappe en "\;".
        $cmd = $Command -replace ';', '\;'
        Start-Process -FilePath "wt.exe" -ArgumentList @(
            "-d", "`"$Path`"",
            "`"$shellExe`"", "-NoExit", "-Command", $cmd
        )
    } else {
        # Le dossier est passe via -WorkingDirectory : aucun souci d'apostrophe
        # ou de caractere special dans le chemin.
        Start-Process -FilePath $shellExe -WorkingDirectory $Path -ArgumentList @(
            "-NoExit", "-Command", $Command
        )
    }
}

function Launch-Selected {
    $entry = Get-SelectedEntry
    if (-not $entry) { return }
    if ($entry.Kind -eq 'session') {
        # Claude ne retrouve une session que depuis son dossier d'origine
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            $status.Text = "Dossier introuvable : $($entry.Path)"
            return
        }
        Start-ClaudeIn -Path $entry.Path -Command (Get-SessionCommand $entry)
    } else {
        Start-ClaudeIn -Path $entry.Path -Command $ClaudeCommand
    }
    $form.Hide()
}

function Get-ChromePath {
    # Trouve chrome.exe (Program Files, Program Files (x86), LocalAppData, PATH)
    $candidates = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:LocalAppData}\Google\Chrome\Application\chrome.exe"
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) {
        $cmd = Get-Command chrome.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }
    return $exe
}

function Start-Chrome {
    param([string]$Url)
    $exe = Get-ChromePath
    try {
        if ($exe) {
            # Si Chrome tourne deja, un nouvel onglet s'ouvre dans la fenetre active
            Start-Process -FilePath $exe -ArgumentList $Url
        } else {
            # Fallback : navigateur par defaut
            Start-Process $Url
        }
    } catch {
        Start-Process $Url
    }
}

function Open-InChrome {
    $entry = Get-SelectedEntry
    if (-not $entry) { return }
    $rel = $entry.RelPath
    if ($entry.Kind -eq 'session') {
        # Session : URL du projet si son dossier est sous ProjectsRoot
        $root = $ProjectsRoot.TrimEnd('\') + '\'
        if (-not $entry.Path -or -not $entry.Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $status.Text = "Ce dossier n'est pas sous $ProjectsRoot"
            return
        }
        $rel = $entry.Path.Substring($root.Length).TrimEnd('\')
    }
    # Pattern issu de config.json : {name} est remplace par le chemin relatif
    # du dossier (segments encodes pour l'URL, separateur "/").
    $urlPath = ($rel -split '\\' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $url     = $ChromeUrlPattern.Replace('{name}', $urlPath)
    Start-Chrome -Url $url
    $form.Hide()
}

function Open-InExplorer {
    $entry = Get-SelectedEntry
    if (-not $entry) { return }
    if (-not (Test-Path -LiteralPath $entry.Path)) {
        $status.Text = "Dossier introuvable : $($entry.Path)"
        return
    }
    Start-Process explorer.exe "`"$($entry.Path)`""
    $form.Hide()
}

function Show-Launcher {
    param([string]$Mode = 'projects')
    Refresh-Folders
    $textbox.Text = ""
    Set-Mode $Mode
    # Place la fenetre en bas a droite de l'ecran ou se trouve la souris
    # (= celui de la traybar cliquee, utile en multi-ecran)
    $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $form.Location = New-Object System.Drawing.Point(
        ($wa.Right  - $form.Width  - 12),
        ($wa.Bottom - $form.Height - 12)
    )
    $form.Show()
    $form.Activate()
    [void]$textbox.Focus()
}

# ===== Events ===================================================
$textbox.Add_TextChanged({ Update-List $textbox.Text })
$listbox.Add_SelectedIndexChanged({ Update-Status })

# Tab est normalement consomme par WinForms pour changer de controle avant
# tout KeyDown : on le declare "touche d'entree" pour le recevoir.
$tabAsInput = {
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Tab) { $_.IsInputKey = $true }
}
$textbox.Add_PreviewKeyDown($tabAsInput)
$listbox.Add_PreviewKeyDown($tabAsInput)

# Gestion clavier au niveau du formulaire (KeyPreview=$true plus haut) :
# le formulaire intercepte la touche AVANT que la TextBox/ListBox la voie.
# Comparaison explicite sur l'enum Keys pour eviter toute ambiguite avec
# Enter/Return (qui sont des alias mais .ToString() renvoie "Return").
$form.Add_KeyDown({
    $k    = $_.KeyCode
    $Keys = [System.Windows.Forms.Keys]
    if ($k -eq $Keys::Enter -or $k -eq $Keys::Return) {
        $_.Handled = $true
        $_.SuppressKeyPress = $true
        if ($_.Control) {
            Open-InChrome      # Ctrl+Entree  => Chrome http://127.0.0.1/<dossier>
        } elseif ($_.Shift) {
            Open-InExplorer    # Shift+Entree => Explorateur Windows dans le dossier
        } else {
            Launch-Selected    # Entree       => PowerShell + claude dans le dossier
        }
    }
    elseif ($k -eq $Keys::Tab) {
        # Tab => bascule projets <-> sessions Claude
        $_.Handled = $true
        $_.SuppressKeyPress = $true
        Set-Mode $(if ($script:Mode -eq 'sessions') { 'projects' } else { 'sessions' })
        [void]$textbox.Focus()
    }
    elseif ($k -eq $Keys::Escape) {
        $_.Handled = $true
        $_.SuppressKeyPress = $true
        $form.Hide()
    }
    elseif ($k -eq $Keys::Down) {
        # On ne capture les fleches que si le focus est dans la TextBox
        # (sinon on laisse la ListBox gerer sa navigation native).
        if ($textbox.Focused -and $listbox.Items.Count -gt 0 -and
            $listbox.SelectedIndex -lt $listbox.Items.Count - 1) {
            $listbox.SelectedIndex++
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        }
    }
    elseif ($k -eq $Keys::Up) {
        if ($textbox.Focused -and $listbox.SelectedIndex -gt 0) {
            $listbox.SelectedIndex--
            $_.Handled = $true
            $_.SuppressKeyPress = $true
        }
    }
})

$listbox.Add_DoubleClick({ Launch-Selected })

# Clic droit sur un element : le selectionne et copie son chemin complet
# (session : la commande de reprise "claude --resume <id>")
$listbox.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $idx = $listbox.IndexFromPoint($e.Location)
    if ($idx -lt 0 -or $idx -ge $listbox.Items.Count) { return }
    $listbox.SelectedIndex = $idx
    $entry = $listbox.Items[$idx]
    if (-not $entry) { return }
    try {
        if ($entry.Kind -eq 'session') {
            $cmd = Get-SessionCommand $entry
            [System.Windows.Forms.Clipboard]::SetText($cmd)
            $status.Text = "Commande copiee : $cmd"
            return
        }
        [System.Windows.Forms.Clipboard]::SetText($entry.Path)
        $status.Text = "Chemin copie : $($entry.Path)"
    } catch {
        $status.Text = "Echec de la copie : $($_.Exception.Message)"
    }
})

$form.Add_Deactivate({ $form.Hide() })
$form.Add_FormClosing({
    param($s, $e)
    # Cache au lieu de fermer (sauf si l'app quitte)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $form.Hide()
    }
})

$notify.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Launcher }
})

$mOpen.Add_Click({ Show-Launcher })
$mSessions.Add_Click({ Show-Launcher -Mode 'sessions' })
$mRoot.Add_Click({ Start-Process explorer.exe "`"$ProjectsRoot`"" })
$mLocal.Add_Click({ Start-Chrome -Url "http://127.0.0.1" })
$mRefresh.Add_Click({
    Refresh-Folders
    if ($script:Mode -eq 'sessions') { Refresh-Sessions }
    Update-List $textbox.Text
    $status.Text = "Liste rafraichie ($($script:AllFolders.Count) dossiers)"
})
$mExit.Add_Click({
    $notify.Visible = $false
    $notify.Dispose()
    try { $script:Mutex.ReleaseMutex() } catch {}
    [System.Windows.Forms.Application]::Exit()
})

# Chargement initial
Refresh-Folders

# ===== Run ======================================================
[System.Windows.Forms.Application]::Run()
