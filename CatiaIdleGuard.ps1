#Requires -Version 5.1
<#
.SYNOPSIS
    CATIA V5 Idle Guard - 無操作時に CATIA V5 を安全に終了してライセンスを返却する常駐ツール

.DESCRIPTION
    - CATIA V5 (CNEXT.exe) のウィンドウが前面にある状態でのキーボード/マウス入力を「CATIA 操作」とみなす
    - 一定時間 (既定 15 分) CATIA 操作が無い場合、警告ダイアログ (既定 60 秒カウントダウン) を表示
    - 応答が無い、または「今すぐ保存して終了」が押された場合:
        1. COM (CATIA.Application) で開いている全文書を列挙
        2. 未保存の文書をバックアップフォルダへ「名前を付けて保存」(元ファイルは上書きしない)
        3. CATIA を終了 (Quit) -> ライセンスがサーバへ返却される
        4. 一定時間経っても終了しない場合は強制終了 (設定で変更可)
    - 設定は同じフォルダの config.json で変更可能
    - 動作ログは logs\ フォルダに日付別で出力

.PARAMETER ConfigPath
    設定ファイルのパス (既定: スクリプトと同じフォルダの config.json)

.PARAMETER IdleMinutes
    config.json の IdleMinutes を一時的に上書き (動作テスト用)

.PARAMETER WarningSeconds
    config.json の WarningSeconds を一時的に上書き (動作テスト用)

.PARAMETER NoTray
    タスクトレイアイコンを表示しない

.NOTES
    Windows PowerShell 5.1 (Windows 標準) 向け。
    PowerShell 7 (pwsh) では GetActiveObject が使えないため、Start-CatiaIdleGuard.bat から起動すること。
    管理者権限で実行しないこと (CATIA と権限レベルが異なると COM 接続に失敗する)。
    このファイルは UTF-8 (BOM 付き) で保存すること。BOM が無いと日本語が文字化けする。
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [double]$IdleMinutes,
    [int]$WarningSeconds,
    [switch]$NoTray
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# 設定読み込み
# ------------------------------------------------------------------
$script:DefaultConfig = [ordered]@{
    IdleMinutes           = 15          # この分数 CATIA 操作が無ければ警告
    WarningSeconds        = 60          # 警告ダイアログのカウントダウン秒数
    PollSeconds           = 1           # 入力監視の周期 (秒)
    ProcessName           = 'CNEXT'     # CATIA V5 本体プロセス名 (拡張子なし)
    BackupFolder          = '%USERPROFILE%\Documents\CATIA_AutoBackup'
    ForceKillAfterSeconds = 90          # Quit 後この秒数で終了しなければ強制終了 (0 = 強制終了しない)
    QuitWithoutComAccess  = $false      # COM 接続失敗時に保存せず終了するか (既定: 終了しない = データ保護優先)
    LogFolder             = 'logs'      # スクリプトフォルダからの相対パス
    LogRetentionDays      = 30
}

function Get-Config {
    param([string]$Path)
    $cfg = [ordered]@{}
    foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
    if (Test-Path -LiteralPath $Path) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        }
        catch {
            Write-Warning "config.json の読み込みに失敗しました。既定値で続行します: $($_.Exception.Message)"
        }
    }
    $cfg.BackupFolder = [Environment]::ExpandEnvironmentVariables([string]$cfg.BackupFolder)
    if (-not [IO.Path]::IsPathRooted([string]$cfg.LogFolder)) {
        $cfg.LogFolder = Join-Path $PSScriptRoot ([string]$cfg.LogFolder)
    }
    return $cfg
}

$script:Config = Get-Config -Path $ConfigPath
if ($PSBoundParameters.ContainsKey('IdleMinutes'))    { $script:Config.IdleMinutes    = $IdleMinutes }
if ($PSBoundParameters.ContainsKey('WarningSeconds')) { $script:Config.WarningSeconds = $WarningSeconds }

# ------------------------------------------------------------------
# ログ
# ------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) {
            New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null
        }
        $file = Join-Path $script:Config.LogFolder ('CatiaIdleGuard_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    }
    catch { }
    Write-Host $line
}

function Remove-OldLogs {
    try {
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { return }
        $limit = (Get-Date).AddDays(-1 * [int]$script:Config.LogRetentionDays)
        Get-ChildItem -LiteralPath $script:Config.LogFolder -Filter 'CatiaIdleGuard_*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

# ------------------------------------------------------------------
# Win32 API (最終入力時刻 / 前面ウィンドウのプロセス ID)
# ------------------------------------------------------------------
Add-Type -Namespace CatiaIdleGuard -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO {
    public uint cbSize;
    public uint dwTime;
}

[DllImport("user32.dll")]
public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();

[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

public static uint GetLastInputTick() {
    LASTINPUTINFO lii = new LASTINPUTINFO();
    lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
    if (!GetLastInputInfo(ref lii)) return 0;
    return lii.dwTime;
}

public static uint GetForegroundProcessId() {
    IntPtr h = GetForegroundWindow();
    if (h == IntPtr.Zero) return 0;
    uint pid;
    GetWindowThreadProcessId(h, out pid);
    return pid;
}
'@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------
# CATIA プロセス / 入力監視
# ------------------------------------------------------------------
function Get-CatiaProcesses {
    @(Get-Process -Name $script:Config.ProcessName -ErrorAction SilentlyContinue)
}

function Test-CatiaForeground {
    param([int[]]$CatiaPids)
    if (-not $CatiaPids -or $CatiaPids.Count -eq 0) { return $false }
    $fg = [int64][CatiaIdleGuard.Native]::GetForegroundProcessId()
    foreach ($p in $CatiaPids) { if ([int64]$p -eq $fg) { return $true } }
    return $false
}

function Wait-Poll {
    # タスクトレイのメニューに反応できるよう、短い間隔で DoEvents を回しながら待つ
    param([int]$Milliseconds)
    $end = (Get-Date).AddMilliseconds($Milliseconds)
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $end -and $script:Running)
}

# ------------------------------------------------------------------
# CATIA COM 操作
# ------------------------------------------------------------------
function Connect-Catia {
    try {
        return [Runtime.InteropServices.Marshal]::GetActiveObject('CATIA.Application')
    }
    catch {
        Write-Log -Level WARN -Message "CATIA.Application への COM 接続に失敗: $($_.Exception.Message)"
        return $null
    }
}

function Remove-ComReference {
    param($Obj)
    if ($null -ne $Obj) {
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Obj) } catch { }
    }
}

function Get-UniquePath {
    param([string]$Folder, [string]$Name)
    $target = Join-Path $Folder $Name
    if (-not (Test-Path -LiteralPath $target)) { return $target }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    $i = 1
    do {
        $target = Join-Path $Folder ('{0}_{1}{2}' -f $base, $i, $ext)
        $i++
    } while (Test-Path -LiteralPath $target)
    return $target
}

function Backup-UnsavedDocuments {
    <#
        未保存の文書をすべてバックアップフォルダへ SaveAs する。
        戻り値: @{ Total=開いている文書数; Unsaved=未保存数; Saved=保存成功数; Failed=失敗数; Folder=保存先 }
        列挙自体に失敗した場合は例外を投げる (呼び出し側で「終了しない」判断に使う)。
    #>
    param([Parameter(Mandatory)]$Catia)

    $result = @{ Total = 0; Unsaved = 0; Saved = 0; Failed = 0; Folder = $null }
    $docs = $Catia.Documents
    $result.Total = [int]$docs.Count
    if ($result.Total -eq 0) { return $result }

    $unsaved = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $result.Total; $i++) {
        $doc = $docs.Item($i)      # ここで失敗したら例外のまま上位へ (状態不明の文書を見捨てない)
        if (-not $doc.Saved) { [void]$unsaved.Add($doc) }
    }
    $result.Unsaved = $unsaved.Count
    if ($result.Unsaved -eq 0) { return $result }

    $folder = Join-Path $script:Config.BackupFolder (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $result.Folder = $folder

    # 先に Part/Drawing など末端文書を保存し、Product は最後に保存する
    # (Product を SaveAs した時点で子文書への新しいリンクを含めて保存されるため)
    $ordered = @($unsaved | Where-Object { $_.Name -notlike '*.CATProduct' }) +
               @($unsaved | Where-Object { $_.Name -like '*.CATProduct' })

    foreach ($doc in $ordered) {
        $name = 'unknown'
        try {
            $name = [string]$doc.Name
            $original = ''
            try { $original = [string]$doc.FullName } catch { }
            $target = Get-UniquePath -Folder $folder -Name $name
            $doc.SaveAs($target)
            $result.Saved++
            Write-Log -Message "バックアップ保存: $name -> $target (元: $original)"
        }
        catch {
            $result.Failed++
            Write-Log -Level ERROR -Message "バックアップ保存に失敗: $name : $($_.Exception.Message)"
        }
    }

    # 保存内容の目録
    try {
        $manifest = Join-Path $folder '_README.txt'
        @(
            'CATIA Idle Guard による自動バックアップ'
            "日時: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "理由: $($script:Config.IdleMinutes) 分間 CATIA の操作が無かったため、ライセンス返却のために CATIA を終了しました。"
            '元ファイルは上書きしていません。必要な場合はこのフォルダの文書を開いて元の場所へ保存し直してください。'
            ''
            "保存成功: $($result.Saved) / 未保存文書: $($result.Unsaved) / 失敗: $($result.Failed)"
        ) | Set-Content -LiteralPath $manifest -Encoding UTF8
    }
    catch { }

    return $result
}

function Stop-CatiaSafely {
    <#
        未保存文書をバックアップ保存してから CATIA を終了する。
        戻り値: $true = CATIA が終了した, $false = 終了しなかった (データ保護のため見送り / 失敗)
    #>
    Write-Log -Message 'CATIA 終了処理を開始します。'

    $catia = Connect-Catia
    if ($null -ne $catia) {
        $backup = $null
        try {
            $backup = Backup-UnsavedDocuments -Catia $catia
            Write-Log -Message ('文書: {0} / 未保存: {1} / 保存成功: {2} / 失敗: {3}' -f $backup.Total, $backup.Unsaved, $backup.Saved, $backup.Failed)
        }
        catch {
            Write-Log -Level ERROR -Message "文書の列挙に失敗: $($_.Exception.Message)"
        }

        if ($null -eq $backup -or $backup.Failed -gt 0) {
            Write-Log -Level WARN -Message '未保存文書を保護できない可能性があるため CATIA を終了しません。次回の無操作判定で再試行します。'
            Remove-ComReference $catia
            return $false
        }

        try {
            try { $catia.DisplayFileAlerts = $false } catch { }
            $catia.Quit()
            Write-Log -Message 'CATIA.Application.Quit() を送信しました。'
        }
        catch {
            Write-Log -Level ERROR -Message "Quit() に失敗: $($_.Exception.Message)"
        }
        Remove-ComReference $catia
    }
    else {
        if (-not [bool]$script:Config.QuitWithoutComAccess) {
            Write-Log -Level WARN -Message 'COM 接続できないため、未保存文書を保護する目的で CATIA を終了しません (QuitWithoutComAccess=false)。'
            return $false
        }
        Write-Log -Level WARN -Message 'COM 接続できませんが QuitWithoutComAccess=true のため強制終了に進みます。'
    }

    # 終了待ち -> 必要なら強制終了
    $limit = [int]$script:Config.ForceKillAfterSeconds
    $deadline = (Get-Date).AddSeconds([Math]::Max($limit, 10))
    while ((Get-Date) -lt $deadline) {
        if ((Get-CatiaProcesses).Count -eq 0) {
            Write-Log -Message 'CATIA が終了しました。ライセンスは返却されています。'
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    if ($limit -gt 0) {
        Write-Log -Level WARN -Message "CATIA が $limit 秒以内に終了しないため強制終了します。"
        foreach ($p in Get-CatiaProcesses) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
            catch { Write-Log -Level ERROR -Message "強制終了に失敗 (PID $($p.Id)): $($_.Exception.Message)" }
        }
        Start-Sleep -Seconds 2
        if ((Get-CatiaProcesses).Count -eq 0) {
            Write-Log -Message 'CATIA を強制終了しました。'
            return $true
        }
    }
    Write-Log -Level ERROR -Message 'CATIA を終了できませんでした。'
    return $false
}

# ------------------------------------------------------------------
# 警告ダイアログ (カウントダウン)
# ------------------------------------------------------------------
function Show-WarningDialog {
    <#
        戻り値: 'Continue' (作業続行), 'QuitNow' (今すぐ終了), 'Timeout' (無応答 -> 終了)
        カウントダウン中に CATIA ウィンドウで入力があった場合も 'Continue' を返す。
    #>
    param([int]$Seconds, [int[]]$CatiaPids)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CATIA Idle Guard'
    $form.Size = New-Object System.Drawing.Size(480, 210)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Size = New-Object System.Drawing.Size(450, 90)
    $label.Location = New-Object System.Drawing.Point(15, 15)
    $label.Font = New-Object System.Drawing.Font('Meiryo UI', 10)
    $form.Controls.Add($label)

    $btnContinue = New-Object System.Windows.Forms.Button
    $btnContinue.Text = '作業を続行する'
    $btnContinue.Size = New-Object System.Drawing.Size(190, 36)
    $btnContinue.Location = New-Object System.Drawing.Point(40, 120)
    $btnContinue.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnContinue)
    $form.CancelButton = $btnContinue

    $btnQuit = New-Object System.Windows.Forms.Button
    $btnQuit.Text = '今すぐ保存して終了'
    $btnQuit.Size = New-Object System.Drawing.Size(190, 36)
    $btnQuit.Location = New-Object System.Drawing.Point(245, 120)
    $btnQuit.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnQuit)

    $state = @{ Remaining = $Seconds; Result = 'Timeout'; LastTick = [CatiaIdleGuard.Native]::GetLastInputTick() }

    $update = {
        $label.Text = ("{0} 分間 CATIA の操作がありません。`r`n" +
            "{1} 秒後に未保存の文書をバックアップ保存して CATIA を終了し、ライセンスを返却します。`r`n" +
            '保存先: {2}') -f $script:Config.IdleMinutes, $state.Remaining, $script:Config.BackupFolder
    }.GetNewClosure()
    & $update

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $state.Remaining = $state.Remaining - 1
        # カウントダウン中に CATIA ウィンドウで入力があれば続行扱い
        $tick = [CatiaIdleGuard.Native]::GetLastInputTick()
        if ($tick -ne $state.LastTick) {
            $state.LastTick = $tick
            if (Test-CatiaForeground -CatiaPids $CatiaPids) {
                $state.Result = 'Continue'
                $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                return
            }
        }
        if ($state.Remaining -le 0) {
            $state.Result = 'Timeout'
            $form.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
            return
        }
        & $update
    }.GetNewClosure())
    $timer.Start()

    $form.Add_Shown({ $form.Activate() }.GetNewClosure())
    $dr = $form.ShowDialog()
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()

    if ($dr -eq [System.Windows.Forms.DialogResult]::OK)     { return 'QuitNow' }
    if ($dr -eq [System.Windows.Forms.DialogResult]::Cancel) { return 'Continue' }
    return $state.Result
}

# ------------------------------------------------------------------
# タスクトレイ
# ------------------------------------------------------------------
$script:Tray = $null
function Initialize-Tray {
    if ($NoTray) { return }
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = [System.Drawing.SystemIcons]::Shield
    $icon.Text = 'CATIA Idle Guard'
    $icon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemStatus = $menu.Items.Add('状態: 起動中')
    $itemStatus.Enabled = $false
    [void]$menu.Items.Add('-')
    $itemLog = $menu.Items.Add('ログフォルダを開く')
    $itemLog.Add_Click({
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null }
        Start-Process explorer.exe $script:Config.LogFolder
    })
    $itemBackup = $menu.Items.Add('バックアップフォルダを開く')
    $itemBackup.Add_Click({
        if (-not (Test-Path -LiteralPath $script:Config.BackupFolder)) { New-Item -ItemType Directory -Path $script:Config.BackupFolder -Force | Out-Null }
        Start-Process explorer.exe $script:Config.BackupFolder
    })
    [void]$menu.Items.Add('-')
    $itemExit = $menu.Items.Add('Idle Guard を終了')
    $itemExit.Add_Click({ $script:Running = $false })
    $icon.ContextMenuStrip = $menu

    $script:Tray = @{ Icon = $icon; Status = $itemStatus }
}

function Set-TrayStatus {
    param([string]$Text)
    if ($null -ne $script:Tray) {
        $script:Tray.Status.Text = "状態: $Text"
        $tip = 'CATIA Idle Guard - ' + $Text
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }   # NotifyIcon.Text の上限
        $script:Tray.Icon.Text = $tip
    }
}

function Show-Balloon {
    param([string]$Title, [string]$Text)
    if ($null -ne $script:Tray) {
        try { $script:Tray.Icon.ShowBalloonTip(5000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}

# ------------------------------------------------------------------
# メインループ
# ------------------------------------------------------------------
$script:Running = $true

Write-Log -Message ('CATIA Idle Guard 起動 (IdleMinutes={0}, WarningSeconds={1}, Process={2}, Backup={3})' -f `
    $script:Config.IdleMinutes, $script:Config.WarningSeconds, $script:Config.ProcessName, $script:Config.BackupFolder)
Remove-OldLogs
Initialize-Tray

$trackedPids = @()
$lastActivity = Get-Date
$lastInputTick = [CatiaIdleGuard.Native]::GetLastInputTick()
$idleLimit = [TimeSpan]::FromMinutes([double]$script:Config.IdleMinutes)
$pollMs = [Math]::Max(200, [int]([double]$script:Config.PollSeconds * 1000))

try {
    while ($script:Running) {
        $procs = Get-CatiaProcesses
        $pids = @($procs | ForEach-Object { [int]$_.Id })

        if ($pids.Count -eq 0) {
            if ($trackedPids.Count -gt 0) {
                Write-Log -Message 'CATIA の終了を検出しました。監視を待機状態に戻します。'
                $trackedPids = @()
            }
            Set-TrayStatus 'CATIA 未起動 (待機中)'
            Wait-Poll -Milliseconds $pollMs
            continue
        }

        # 新しい CATIA セッションを検出 -> 起動直後を活動とみなす
        $newPids = @($pids | Where-Object { $trackedPids -notcontains $_ })
        if ($newPids.Count -gt 0) {
            Write-Log -Message "CATIA を検出しました (PID: $($newPids -join ', '))。監視を開始します。"
            $lastActivity = Get-Date
        }
        $trackedPids = $pids

        # 入力検出: 最終入力時刻が進んでいて、かつ前面が CATIA なら CATIA 操作
        $tick = [CatiaIdleGuard.Native]::GetLastInputTick()
        if ($tick -ne $lastInputTick) {
            $lastInputTick = $tick
            if (Test-CatiaForeground -CatiaPids $pids) {
                $lastActivity = Get-Date
            }
        }

        $idle = (Get-Date) - $lastActivity
        $remain = $idleLimit - $idle
        if ($remain.TotalSeconds -gt 0) {
            Set-TrayStatus ('監視中 - 終了まで {0:mm\:ss}' -f $remain)
        }
        else {
            Write-Log -Message ('{0:F1} 分間 CATIA 操作なし。警告ダイアログを表示します。' -f $idle.TotalMinutes)
            Set-TrayStatus '警告表示中'
            $answer = Show-WarningDialog -Seconds ([int]$script:Config.WarningSeconds) -CatiaPids $pids
            Write-Log -Message "警告ダイアログの結果: $answer"

            if ($answer -eq 'Continue') {
                $lastActivity = Get-Date
                $lastInputTick = [CatiaIdleGuard.Native]::GetLastInputTick()
            }
            else {
                Set-TrayStatus 'CATIA 終了処理中'
                $ok = Stop-CatiaSafely
                if ($ok) {
                    Show-Balloon -Title 'CATIA Idle Guard' -Text 'CATIA を終了し、ライセンスを返却しました。未保存文書はバックアップフォルダに保存されています。'
                    $trackedPids = @()
                }
                else {
                    Show-Balloon -Title 'CATIA Idle Guard' -Text 'CATIA を終了できませんでした。ログを確認してください。'
                    # 連続して警告を出し続けないよう、再判定までの猶予を設ける
                    $lastActivity = Get-Date
                }
            }
        }

        Wait-Poll -Milliseconds $pollMs
    }
}
finally {
    if ($null -ne $script:Tray) {
        $script:Tray.Icon.Visible = $false
        $script:Tray.Icon.Dispose()
    }
    Write-Log -Message 'CATIA Idle Guard を終了しました。'
}
