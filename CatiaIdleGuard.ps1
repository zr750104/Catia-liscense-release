#Requires -Version 5.1
<#
.SYNOPSIS
    CATIA V5 Idle Guard
    EN: Tray-resident tool that saves unsaved documents and quits CATIA V5 after a period of inactivity, returning the license.
    JP: 無操作時に CATIA V5 を安全に終了してライセンスを返却する常駐ツール

.DESCRIPTION
    EN:
    - Keyboard/mouse input while a CATIA V5 (CNEXT.exe) window is in the foreground counts as "CATIA activity".
    - If there is no CATIA activity for a set time (default 15 min), a warning dialog with a countdown (default 60 s) is shown.
    - If there is no response, or "Save and quit now" is clicked:
        1. List all open documents via COM (CATIA.Application)
        2. Save unsaved documents to the backup folder with "Save As" (original files are NOT overwritten)
        3. Quit CATIA -> the license is returned to the server
        4. Force-kill CATIA if it does not exit within a set time (configurable)
    - Settings: config.json in the same folder. Logs: logs\ folder, one file per day.

    JP:
    - CATIA V5 (CNEXT.exe) のウィンドウが前面にある状態でのキーボード/マウス入力を「CATIA 操作」とみなす
    - 一定時間 (既定 15 分) CATIA 操作が無い場合、警告ダイアログ (既定 60 秒カウントダウン) を表示
    - 応答が無い、または「今すぐ保存して終了」が押された場合:
        1. COM (CATIA.Application) で開いている全文書を列挙
        2. 未保存の文書をバックアップフォルダへ「名前を付けて保存」(元ファイルは上書きしない)
        3. CATIA を終了 (Quit) -> ライセンスがサーバへ返却される
        4. 一定時間経っても終了しない場合は強制終了 (設定で変更可)
    - 設定は同じフォルダの config.json、ログは logs\ フォルダに日付別で出力

.PARAMETER ConfigPath
    EN: Path to the settings file (default: config.json next to this script)
    JP: 設定ファイルのパス (既定: スクリプトと同じフォルダの config.json)

.PARAMETER IdleMinutes
    EN: Temporarily overrides IdleMinutes in config.json (for testing)
    JP: config.json の IdleMinutes を一時的に上書き (動作テスト用)

.PARAMETER WarningSeconds
    EN: Temporarily overrides WarningSeconds in config.json (for testing)
    JP: config.json の WarningSeconds を一時的に上書き (動作テスト用)

.PARAMETER NoTray
    EN: Do not show the tray icon
    JP: タスクトレイアイコンを表示しない

.NOTES
    EN: For Windows PowerShell 5.1 (built into Windows). Does not work on PowerShell 7 (pwsh) because GetActiveObject
        is not available there; start it with Start-CatiaIdleGuard.bat.
        Do NOT run as Administrator (COM connection fails if CATIA runs at a different privilege level).
        Keep this file saved as UTF-8 WITH BOM, otherwise Japanese/Thai text is garbled.
        On-screen text is shown in English, Japanese and Thai. Logs are English/Japanese.
    JP: Windows PowerShell 5.1 (Windows 標準) 向け。PowerShell 7 (pwsh) では GetActiveObject が使えないため、
        Start-CatiaIdleGuard.bat から起動すること。
        管理者権限で実行しないこと (CATIA と権限レベルが異なると COM 接続に失敗する)。
        このファイルは UTF-8 (BOM 付き) で保存すること。BOM が無いと日本語/タイ語が文字化けする。
        画面表示は英語・日本語・タイ語の 3 言語、ログは英日併記。
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [double]$IdleMinutes,
    [int]$WarningSeconds,
    [switch]$NoTray
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Script folder / スクリプトのフォルダ
#   EN: $PSScriptRoot can be empty in Windows PowerShell 5.1 (e.g. in param defaults), so use fallbacks.
#   JP: Windows PowerShell 5.1 では $PSScriptRoot が空になる場合があるため、順に代替手段で求める。
# ------------------------------------------------------------------
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) {
    try { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $script:ScriptDir = $null }
}
if (-not $script:ScriptDir -and $ConfigPath) {
    $script:ScriptDir = Split-Path -Parent $ConfigPath
}
if (-not $script:ScriptDir) {
    $script:ScriptDir = (Get-Location).Path
}
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $script:ScriptDir 'config.json'
}

# ------------------------------------------------------------------
# Settings / 設定読み込み
# ------------------------------------------------------------------
$script:DefaultConfig = [ordered]@{
    IdleMinutes           = 15          # Warn after this many minutes without CATIA activity / この分数 CATIA 操作が無ければ警告
    WarningSeconds        = 60          # Countdown of the warning dialog (s) / 警告ダイアログのカウントダウン秒数
    PollSeconds           = 1           # Polling interval (s) / 入力監視の周期 (秒)
    ProcessName           = 'CNEXT'     # CATIA V5 process name without .exe / CATIA V5 本体プロセス名 (拡張子なし)
    BackupFolder          = '%USERPROFILE%\Documents\CATIA_AutoBackup'
    ForceKillAfterSeconds = 90          # Force-kill if not exited this many s after Quit (0 = never) / Quit 後この秒数で終了しなければ強制終了 (0 = しない)
    QuitWithoutComAccess  = $false      # Quit even if COM is unavailable (data may be lost) / COM 接続失敗時も終了するか (未保存データ消失の恐れ)
    LogFolder             = 'logs'      # Relative to the script folder / スクリプトフォルダからの相対パス
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
            Write-Warning "Failed to read config.json. Using defaults. / config.json の読み込みに失敗しました。既定値で続行します: $($_.Exception.Message)"
        }
    }
    $cfg.BackupFolder = [Environment]::ExpandEnvironmentVariables([string]$cfg.BackupFolder)
    if (-not [IO.Path]::IsPathRooted([string]$cfg.LogFolder)) {
        $cfg.LogFolder = Join-Path $script:ScriptDir ([string]$cfg.LogFolder)
    }
    return $cfg
}

$script:Config = Get-Config -Path $ConfigPath
if ($PSBoundParameters.ContainsKey('IdleMinutes'))    { $script:Config.IdleMinutes    = $IdleMinutes }
if ($PSBoundParameters.ContainsKey('WarningSeconds')) { $script:Config.WarningSeconds = $WarningSeconds }

# ------------------------------------------------------------------
# Logging / ログ
#   Messages are written as "English / 日本語".
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
# Win32 API (last input time / foreground window process ID)
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

# UI font: Meiryo UI if installed (Japanese Windows), otherwise Segoe UI (e.g. Thai/English Windows)
# 画面フォント: Meiryo UI があれば使用、無ければ Segoe UI (タイ語版/英語版 Windows 対策)
function Get-UiFontName {
    try {
        $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
        if ($installed -contains 'Meiryo UI') { return 'Meiryo UI' }
    }
    catch { }
    return 'Segoe UI'
}
$script:UiFont = Get-UiFontName

# Thai font: Leelawadee UI (Windows 8+) or Tahoma (always installed) / タイ語フォント
function Get-ThaiFontName {
    try {
        $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
        if ($installed -contains 'Leelawadee UI') { return 'Leelawadee UI' }
    }
    catch { }
    return 'Tahoma'
}
$script:ThaiFont = Get-ThaiFontName

# ------------------------------------------------------------------
# CATIA process / input monitoring
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
    # Wait while pumping DoEvents so the tray menu stays responsive
    # タスクトレイのメニューに反応できるよう、短い間隔で DoEvents を回しながら待つ
    param([int]$Milliseconds)
    $end = (Get-Date).AddMilliseconds($Milliseconds)
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $end -and $script:Running)
}

# ------------------------------------------------------------------
# CATIA COM operations / CATIA COM 操作
# ------------------------------------------------------------------
function Connect-Catia {
    try {
        return [Runtime.InteropServices.Marshal]::GetActiveObject('CATIA.Application')
    }
    catch {
        Write-Log -Level WARN -Message "COM connection to CATIA.Application failed / CATIA.Application への COM 接続に失敗: $($_.Exception.Message)"
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
        EN: Saves all unsaved documents to the backup folder with SaveAs.
            Returns @{ Total; Unsaved; Saved; Failed; Folder }.
            Throws if enumeration itself fails (caller then decides NOT to quit).
        JP: 未保存の文書をすべてバックアップフォルダへ SaveAs する。
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
        # On failure, let the exception propagate (never abandon a document whose state is unknown)
        # ここで失敗したら例外のまま上位へ (状態不明の文書を見捨てない)
        $doc = $docs.Item($i)
        if (-not $doc.Saved) { [void]$unsaved.Add($doc) }
    }
    $result.Unsaved = $unsaved.Count
    if ($result.Unsaved -eq 0) { return $result }

    $folder = Join-Path $script:Config.BackupFolder (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $result.Folder = $folder

    # Save leaf documents (Part/Drawing) first and Products last, so the Product is saved with links to the new copies
    # 先に Part/Drawing など末端文書を保存し、Product は最後に保存する (子文書への新しいリンクを含めて保存されるため)
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
            Write-Log -Message "Backup saved / バックアップ保存: $name -> $target (original / 元: $original)"
        }
        catch {
            $result.Failed++
            Write-Log -Level ERROR -Message "Backup save failed / バックアップ保存に失敗: $name : $($_.Exception.Message)"
        }
    }

    # Index file of the backup / 保存内容の目録
    try {
        $manifest = Join-Path $folder '_README.txt'
        @(
            'Automatic backup by CATIA Idle Guard'
            'CATIA Idle Guard による自動バックアップ'
            'สำรองข้อมูลอัตโนมัติโดย CATIA Idle Guard'
            ''
            "Date / 日時 / วันที่: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            ''
            "Reason: CATIA was closed to return the license because it was not used for $($script:Config.IdleMinutes) minutes."
            "理由: $($script:Config.IdleMinutes) 分間 CATIA の操作が無かったため、ライセンス返却のために CATIA を終了しました。"
            "เหตุผล: ปิด CATIA เพื่อคืนไลเซนส์ เนื่องจากไม่ได้ใช้งานเป็นเวลา $($script:Config.IdleMinutes) นาที"
            ''
            'The original files were NOT overwritten. If needed, open the documents in this folder and save them back to the original location.'
            '元ファイルは上書きしていません。必要な場合はこのフォルダの文書を開いて元の場所へ保存し直してください。'
            'ไฟล์ต้นฉบับไม่ถูกเขียนทับ หากต้องการ ให้เปิดเอกสารในโฟลเดอร์นี้แล้วบันทึกกลับไปยังตำแหน่งเดิม'
            ''
            "Saved / 保存成功 / บันทึกสำเร็จ: $($result.Saved)"
            "Unsaved documents / 未保存文書 / เอกสารที่ยังไม่ได้บันทึก: $($result.Unsaved)"
            "Failed / 失敗 / ล้มเหลว: $($result.Failed)"
        ) | Set-Content -LiteralPath $manifest -Encoding UTF8
    }
    catch { }

    return $result
}

function Stop-CatiaSafely {
    <#
        EN: Backs up unsaved documents, then quits CATIA.
            Returns $true if CATIA exited, $false if not (skipped to protect data, or failed).
        JP: 未保存文書をバックアップ保存してから CATIA を終了する。
            戻り値: $true = CATIA が終了した, $false = 終了しなかった (データ保護のため見送り / 失敗)
    #>
    Write-Log -Message 'Starting CATIA shutdown / CATIA 終了処理を開始します。'

    $catia = Connect-Catia
    if ($null -ne $catia) {
        $backup = $null
        try {
            $backup = Backup-UnsavedDocuments -Catia $catia
            Write-Log -Message ('Documents / 文書: {0}  Unsaved / 未保存: {1}  Saved / 保存成功: {2}  Failed / 失敗: {3}' -f $backup.Total, $backup.Unsaved, $backup.Saved, $backup.Failed)
        }
        catch {
            Write-Log -Level ERROR -Message "Failed to list documents / 文書の列挙に失敗: $($_.Exception.Message)"
        }

        if ($null -eq $backup -or $backup.Failed -gt 0) {
            Write-Log -Level WARN -Message 'CATIA was NOT closed because unsaved documents may not be protected. Will retry at the next idle check. / 未保存文書を保護できない可能性があるため CATIA を終了しません。次回の無操作判定で再試行します。'
            Remove-ComReference $catia
            return $false
        }

        try {
            try { $catia.DisplayFileAlerts = $false } catch { }
            $catia.Quit()
            Write-Log -Message 'Sent CATIA.Application.Quit() / CATIA.Application.Quit() を送信しました。'
        }
        catch {
            Write-Log -Level ERROR -Message "Quit() failed / Quit() に失敗: $($_.Exception.Message)"
        }
        Remove-ComReference $catia
    }
    else {
        if (-not [bool]$script:Config.QuitWithoutComAccess) {
            Write-Log -Level WARN -Message 'CATIA was NOT closed because COM is unavailable (QuitWithoutComAccess=false), to protect unsaved documents. / COM 接続できないため、未保存文書を保護する目的で CATIA を終了しません (QuitWithoutComAccess=false)。'
            return $false
        }
        Write-Log -Level WARN -Message 'COM is unavailable but QuitWithoutComAccess=true, so CATIA will be force-killed. / COM 接続できませんが QuitWithoutComAccess=true のため強制終了に進みます。'
    }

    # Wait for exit -> force-kill if needed / 終了待ち -> 必要なら強制終了
    $limit = [int]$script:Config.ForceKillAfterSeconds
    $deadline = (Get-Date).AddSeconds([Math]::Max($limit, 10))
    while ((Get-Date) -lt $deadline) {
        if ((Get-CatiaProcesses).Count -eq 0) {
            Write-Log -Message 'CATIA has exited. The license has been returned. / CATIA が終了しました。ライセンスは返却されています。'
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    if ($limit -gt 0) {
        Write-Log -Level WARN -Message "CATIA did not exit within $limit s. Force-killing. / CATIA が $limit 秒以内に終了しないため強制終了します。"
        foreach ($p in Get-CatiaProcesses) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
            catch { Write-Log -Level ERROR -Message "Force-kill failed / 強制終了に失敗 (PID $($p.Id)): $($_.Exception.Message)" }
        }
        Start-Sleep -Seconds 2
        if ((Get-CatiaProcesses).Count -eq 0) {
            Write-Log -Message 'CATIA was force-killed. / CATIA を強制終了しました。'
            return $true
        }
    }
    Write-Log -Level ERROR -Message 'Could not close CATIA. / CATIA を終了できませんでした。'
    return $false
}

# ------------------------------------------------------------------
# Warning dialog (countdown) / 警告ダイアログ (カウントダウン)
# ------------------------------------------------------------------
function Show-WarningDialog {
    <#
        EN: Returns 'Continue', 'QuitNow' or 'Timeout' (no response -> quit).
            Input in a CATIA window during the countdown also returns 'Continue'.
        JP: 戻り値: 'Continue' (作業続行), 'QuitNow' (今すぐ終了), 'Timeout' (無応答 -> 終了)
            カウントダウン中に CATIA ウィンドウで入力があった場合も 'Continue' を返す。
    #>
    param([int]$Seconds, [int[]]$CatiaPids)

    # Each language has its own label so that each one uses a font that has its glyphs
    # 言語ごとにラベルを分け、その言語の文字を持つフォントで表示する
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CATIA Idle Guard'
    $form.ClientSize = New-Object System.Drawing.Size(640, 370)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false

    $newLabel = {
        param([int]$Y, [int]$H, [string]$FontName, [double]$Size)
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize = $false
        $l.Location = New-Object System.Drawing.Point(15, $Y)
        $l.Size = New-Object System.Drawing.Size(610, $H)
        $l.Font = New-Object System.Drawing.Font($FontName, $Size)
        $form.Controls.Add($l)
        return $l
    }.GetNewClosure()

    $labelEn   = & $newLabel 10  58 'Segoe UI'       9.5   # English
    $labelJp   = & $newLabel 72  58 $script:UiFont   9.5   # 日本語
    $labelTh   = & $newLabel 134 62 $script:ThaiFont 10    # ภาษาไทย
    $labelPath = & $newLabel 200 40 $script:UiFont   8.5   # Backup folder / 保存先
    $labelPath.ForeColor = [System.Drawing.Color]::DimGray

    $btnContinue = New-Object System.Windows.Forms.Button
    $btnContinue.Text = "Continue working`r`n作業を続行する"
    $btnContinue.Size = New-Object System.Drawing.Size(260, 52)
    $btnContinue.Location = New-Object System.Drawing.Point(45, 252)
    $btnContinue.Font = New-Object System.Drawing.Font($script:UiFont, 9.5)
    $btnContinue.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnContinue)
    $form.CancelButton = $btnContinue

    $btnQuit = New-Object System.Windows.Forms.Button
    $btnQuit.Text = "Save and quit now`r`n今すぐ保存して終了"
    $btnQuit.Size = New-Object System.Drawing.Size(260, 52)
    $btnQuit.Location = New-Object System.Drawing.Point(335, 252)
    $btnQuit.Font = New-Object System.Drawing.Font($script:UiFont, 9.5)
    $btnQuit.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnQuit)

    # Thai captions under the buttons / ボタン下のタイ語表記
    foreach ($cap in @(@{ X = 45; T = 'ทำงานต่อ' }, @{ X = 335; T = 'บันทึกและปิดทันที' })) {
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize = $false
        $l.TextAlign = 'MiddleCenter'
        $l.Location = New-Object System.Drawing.Point($cap.X, 308)
        $l.Size = New-Object System.Drawing.Size(260, 30)
        $l.Font = New-Object System.Drawing.Font($script:ThaiFont, 10)
        $l.Text = $cap.T
        $form.Controls.Add($l)
    }

    $state = @{ Remaining = $Seconds; Result = 'Timeout'; LastTick = [CatiaIdleGuard.Native]::GetLastInputTick() }
    # Closures from GetNewClosure() cannot see script-scope functions, so pass the function as a scriptblock
    # GetNewClosure() のクロージャからはスクリプトスコープの関数が見えないため、関数をスクリプトブロックとして渡す
    $testForeground = ${function:Test-CatiaForeground}
    $mins = $script:Config.IdleMinutes
    $folderText = $script:Config.BackupFolder

    $update = {
        $sec = $state.Remaining
        $labelEn.Text = ("CATIA has not been used for {0} minutes.`r`n" +
            'In {1} seconds, unsaved documents will be backed up and CATIA will be closed to return the license.') -f $mins, $sec
        $labelJp.Text = ("{0} 分間 CATIA の操作がありません。`r`n" +
            '{1} 秒後に未保存の文書をバックアップ保存して CATIA を終了し、ライセンスを返却します。') -f $mins, $sec
        $labelTh.Text = ("ไม่ได้ใช้งาน CATIA มาแล้ว {0} นาที`r`n" +
            'ในอีก {1} วินาที ระบบจะสำรองเอกสารที่ยังไม่ได้บันทึก และปิด CATIA เพื่อคืนไลเซนส์') -f $mins, $sec
        $labelPath.Text = "Backup folder / 保存先:`r`n$folderText"
    }.GetNewClosure()
    & $update

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $state.Remaining = $state.Remaining - 1
        # Input in a CATIA window during the countdown = continue / カウントダウン中に CATIA ウィンドウで入力があれば続行扱い
        $tick = [CatiaIdleGuard.Native]::GetLastInputTick()
        if ($tick -ne $state.LastTick) {
            $state.LastTick = $tick
            if (& $testForeground -CatiaPids $CatiaPids) {
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
# Tray icon / タスクトレイ
# ------------------------------------------------------------------
$script:Tray = $null
function Initialize-Tray {
    if ($NoTray) { return }
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = [System.Drawing.SystemIcons]::Shield
    $icon.Text = 'CATIA Idle Guard'
    $icon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemStatus = $menu.Items.Add('Status / 状態 / สถานะ: Starting / 起動中 / กำลังเริ่มต้น')
    $itemStatus.Enabled = $false
    [void]$menu.Items.Add('-')
    $itemLog = $menu.Items.Add('Open log folder / ログフォルダを開く / เปิดโฟลเดอร์ Log')
    $itemLog.Add_Click({
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null }
        Start-Process explorer.exe $script:Config.LogFolder
    })
    $itemBackup = $menu.Items.Add('Open backup folder / バックアップフォルダを開く / เปิดโฟลเดอร์สำรองข้อมูล')
    $itemBackup.Add_Click({
        if (-not (Test-Path -LiteralPath $script:Config.BackupFolder)) { New-Item -ItemType Directory -Path $script:Config.BackupFolder -Force | Out-Null }
        Start-Process explorer.exe $script:Config.BackupFolder
    })
    [void]$menu.Items.Add('-')
    $itemExit = $menu.Items.Add('Exit Idle Guard / Idle Guard を終了 / ปิด Idle Guard')
    $itemExit.Add_Click({ $script:Running = $false })
    $icon.ContextMenuStrip = $menu

    $script:Tray = @{ Icon = $icon; Status = $itemStatus }
}

function Set-TrayStatus {
    # Menu shows EN / JP / TH. The tooltip is English only (Windows limits it to 63 characters).
    # メニューは英日タイ併記。ツールチップは 63 文字制限があるため英語のみ。
    param([string]$English, [string]$Japanese, [string]$Thai)
    if ($null -ne $script:Tray) {
        $script:Tray.Status.Text = "Status / 状態 / สถานะ: $English / $Japanese / $Thai"
        $tip = 'CATIA Idle Guard - ' + $English
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
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
# Main loop / メインループ
# ------------------------------------------------------------------
$script:Running = $true

Write-Log -Message ('CATIA Idle Guard started / 起動 (IdleMinutes={0}, WarningSeconds={1}, Process={2}, Backup={3})' -f `
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
                Write-Log -Message 'CATIA exit detected. Back to standby. / CATIA の終了を検出しました。監視を待機状態に戻します。'
                $trackedPids = @()
            }
            Set-TrayStatus 'CATIA not running (standby)' 'CATIA 未起動 (待機中)' 'CATIA ไม่ได้เปิดอยู่ (รอ)'
            Wait-Poll -Milliseconds $pollMs
            continue
        }

        # New CATIA session detected -> treat startup as activity / 新しい CATIA セッションを検出 -> 起動直後を活動とみなす
        $newPids = @($pids | Where-Object { $trackedPids -notcontains $_ })
        if ($newPids.Count -gt 0) {
            Write-Log -Message "CATIA detected, monitoring started / CATIA を検出、監視を開始します (PID: $($newPids -join ', '))"
            $lastActivity = Get-Date
        }
        $trackedPids = $pids

        # Input detection: last-input time advanced AND CATIA is in the foreground = CATIA activity
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
            $r = '{0:mm\:ss}' -f $remain
            Set-TrayStatus "Monitoring - quit in $r" "監視中 - 終了まで $r" "กำลังตรวจสอบ - ปิดในอีก $r"
        }
        else {
            Write-Log -Message ('No CATIA activity for {0:F1} min. Showing warning dialog. / {0:F1} 分間 CATIA 操作なし。警告ダイアログを表示します。' -f $idle.TotalMinutes)
            Set-TrayStatus 'Warning shown' '警告表示中' 'กำลังแสดงคำเตือน'
            $answer = Show-WarningDialog -Seconds ([int]$script:Config.WarningSeconds) -CatiaPids $pids
            Write-Log -Message "Warning dialog result / 警告ダイアログの結果: $answer"

            if ($answer -eq 'Continue') {
                $lastActivity = Get-Date
                $lastInputTick = [CatiaIdleGuard.Native]::GetLastInputTick()
            }
            else {
                Set-TrayStatus 'Closing CATIA' 'CATIA 終了処理中' 'กำลังปิด CATIA'
                $ok = Stop-CatiaSafely
                if ($ok) {
                    Show-Balloon -Title 'CATIA Idle Guard' -Text ("CATIA was closed and the license returned. Unsaved documents are in the backup folder.`n" +
                        "CATIA を終了し、ライセンスを返却しました。未保存文書はバックアップフォルダに保存されています。`n" +
                        'ปิด CATIA และคืนไลเซนส์แล้ว เอกสารที่ยังไม่ได้บันทึกอยู่ในโฟลเดอร์สำรองข้อมูล')
                    $trackedPids = @()
                }
                else {
                    Show-Balloon -Title 'CATIA Idle Guard' -Text ("Could not close CATIA. Please check the log.`n" +
                        "CATIA を終了できませんでした。ログを確認してください。`n" +
                        'ไม่สามารถปิด CATIA ได้ กรุณาตรวจสอบ Log')
                    # Grace period so the warning does not repeat immediately / 連続して警告を出し続けないよう、再判定までの猶予を設ける
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
    Write-Log -Message 'CATIA Idle Guard stopped / 終了しました。'
}
