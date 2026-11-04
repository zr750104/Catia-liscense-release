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
    [switch]$NoTray,
    [switch]$RegisterStartup     # set by Start-CatiaIdleGuard.bat / 通常起動の bat が指定する
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
    AutoStartup           = $true       # Register auto-start at sign-in when started normally / 通常起動時にサインイン時の自動起動を登録する
    ManagedInstall        = $false      # Set by Install-AllUsers.ps1 (all-users install by an administrator) / 管理者による全ユーザー向けインストール時に true
    # SHA-256 of "CatiaIdleGuard:" + password. Empty = no password. See README to change it.
    # "CatiaIdleGuard:" + パスワード の SHA-256。空ならパスワードなし。変更方法は README を参照。
    ExitPasswordHash      = '09051bb0e9234daaf296e3f915794e6a3655c9236370bfd92fb4a8f4b7d4d355'
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
    $cfg.LogFolder = [Environment]::ExpandEnvironmentVariables([string]$cfg.LogFolder)
    if (-not [IO.Path]::IsPathRooted([string]$cfg.LogFolder)) {
        $cfg.LogFolder = Join-Path $script:ScriptDir ([string]$cfg.LogFolder)
    }
    return $cfg
}

# Command-line overrides (test launcher) / コマンドラインでの上書き (テスト用)
$script:CliOverrides = @{}
if ($PSBoundParameters.ContainsKey('IdleMinutes'))    { $script:CliOverrides['IdleMinutes']    = $IdleMinutes }
if ($PSBoundParameters.ContainsKey('WarningSeconds')) { $script:CliOverrides['WarningSeconds'] = $WarningSeconds }
$script:ConfigReloaded = $false

function Import-Settings {
    $script:Config = Get-Config -Path $script:ConfigPath
    foreach ($k in @($script:CliOverrides.Keys)) { $script:Config[$k] = $script:CliOverrides[$k] }
    $script:ConfigReloaded = $true
}
Import-Settings

# Managed (all-users) mode only when the tool really runs from Program Files, where users cannot edit files.
# A per-user config.json that says ManagedInstall=true is not enough (that would switch protection off).
# 管理者インストール扱いは、実際に Program Files (ユーザーが書き換えられない場所) から動いている場合だけ。
# ユーザー単位の config.json に ManagedInstall=true と書いただけでは認めない (保護が外れてしまうため)。
function Test-IsManaged {
    if (-not [bool]$script:Config.ManagedInstall) { return $false }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root -and ([string]$script:ScriptDir).StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

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

# ------------------------------------------------------------------
# All-users install by an administrator / 管理者による全ユーザー向けインストール
#   EN: Install-AllUsers.ps1 registers HKLM\...\Run\CATIA Idle Guard. If it exists, a per-user copy
#       (e.g. in Downloads) steps aside: it removes its own Startup shortcut and exits.
#   JP: Install-AllUsers.ps1 が HKLM\...\Run\CATIA Idle Guard を登録する。これがある場合、
#       ユーザー単位のコピー (ダウンロードフォルダなど) は自分のスタートアップを外して終了する。
# ------------------------------------------------------------------
$script:RunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$script:RunValueName = 'CATIA Idle Guard'
function Test-ManagedInstallPresent {
    try { [void](Get-ItemProperty -Path $script:RunKey -Name $script:RunValueName -ErrorAction Stop); return $true }
    catch { return $false }
}

if (-not (Test-IsManaged) -and (Test-ManagedInstallPresent)) {
    Write-Log -Level WARN -Message 'Installed for all users by an administrator. This per-user copy exits. / 管理者が全ユーザー向けにインストール済みのため、このコピーは終了します。'
    try {
        $userLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'CATIA Idle Guard.lnk'
        if (Test-Path -LiteralPath $userLnk) { Remove-Item -LiteralPath $userLnk -Force }
    }
    catch { }
    [void][System.Windows.Forms.MessageBox]::Show(
        ("CATIA Idle Guard is installed for all users by your administrator. This copy is not used.`r`n`r`n" +
         "CATIA Idle Guard は管理者により全ユーザー向けにインストールされています。このコピーは使用しません。`r`n`r`n" +
         "CATIA Idle Guard ถูกติดตั้งสำหรับผู้ใช้ทุกคนโดยผู้ดูแลระบบแล้ว สำเนานี้จะไม่ถูกใช้งาน"),
        'CATIA Idle Guard', 'OK', 'Information')
    exit 0
}

# ------------------------------------------------------------------
# Single instance / 多重起動の防止
# ------------------------------------------------------------------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\CatiaIdleGuard')
$script:HasMutex = $false
try { $script:HasMutex = $script:Mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $script:HasMutex = $true }   # previous run crashed / 前回が異常終了
if (-not $script:HasMutex) {
    Write-Log -Level WARN -Message 'Already running. This second copy exits. / 既に起動しています。2 つ目は終了します。'
    [void][System.Windows.Forms.MessageBox]::Show(
        ("CATIA Idle Guard is already running.`r`nTo restart it, right-click the shield icon in the tray, choose Exit, then start it again.`r`n`r`n" +
         "CATIA Idle Guard は既に起動しています。`r`n再起動する場合は、トレイの盾アイコンを右クリックして終了してから、もう一度起動してください。`r`n`r`n" +
         "CATIA Idle Guard กำลังทำงานอยู่แล้ว`r`nหากต้องการเริ่มใหม่ ให้คลิกขวาที่ไอคอนรูปโล่ในถาดระบบ เลือกปิด แล้วเริ่มโปรแกรมอีกครั้ง"),
        'CATIA Idle Guard', 'OK', 'Information')
    exit 0
}

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
    # Always return an array, also for 0 or 1 process (unary comma stops PowerShell unrolling it)
    # 0 件・1 件でも必ず配列で返す (カンマ演算子で PowerShell の展開を防ぐ)
    return ,@(Get-Process -Name $script:Config.ProcessName -ErrorAction SilentlyContinue)
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

# CATIA objects are called by name through IDispatch (late binding).
# PowerShell's normal property access cannot see CATIA properties such as Documents.Count.
# CATIA のオブジェクトは名前指定 (IDispatch の遅延バインディング) で呼び出す。
# PowerShell の通常のプロパティ参照では Documents.Count などが見えないため。
#
# NOTE: results are returned with the unary comma (return ,$x). Without it, PowerShell unrolls
#       enumerable COM objects such as CATIA.Documents into their items.
# 注意: 結果はカンマ演算子付き (return ,$x) で返す。付けないと PowerShell が CATIA.Documents のような
#       列挙可能な COM オブジェクトを中身の要素に展開してしまう。
function Get-ComErrorText {
    # InnerException holds the real COM error (e.g. DISP_E_UNKNOWNNAME) / 本当の COM エラーは InnerException 側にある
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if ($null -ne $ex.InnerException) { return $ex.InnerException.Message }
    return $ex.Message
}

function Get-ComProperty {
    param($Obj, [string]$Name)
    try {
        $value = [System.__ComObject].InvokeMember($Name, [System.Reflection.BindingFlags]::GetProperty, $null, $Obj, $null)
    }
    catch {
        throw "COM get '$Name' failed / COM 取得 '$Name' に失敗: $(Get-ComErrorText $_)"
    }
    return ,$value
}

function Set-ComProperty {
    param($Obj, [string]$Name, $Value)
    try {
        [void][System.__ComObject].InvokeMember($Name, [System.Reflection.BindingFlags]::SetProperty, $null, $Obj, @($Value))
    }
    catch {
        throw "COM set '$Name' failed / COM 設定 '$Name' に失敗: $(Get-ComErrorText $_)"
    }
}

function Invoke-ComMethod {
    param($Obj, [string]$Name, [object[]]$Arguments = @())
    try {
        $value = [System.__ComObject].InvokeMember($Name, [System.Reflection.BindingFlags]::InvokeMethod, $null, $Obj, $Arguments)
    }
    catch {
        throw "COM call '$Name' failed / COM 呼び出し '$Name' に失敗: $(Get-ComErrorText $_)"
    }
    return ,$value
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
    $docs = Get-ComProperty $Catia 'Documents'
    $result.Total = [int](Get-ComProperty $docs 'Count')
    if ($result.Total -eq 0) { return $result }

    # Each entry: @{ Doc = COM object; Name = file name }
    $unsaved = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $result.Total; $i++) {
        # On failure, let the exception propagate (never abandon a document whose state is unknown)
        # ここで失敗したら例外のまま上位へ (状態不明の文書を見捨てない)
        $doc = Invoke-ComMethod $docs 'Item' @([int]$i)
        $name = [string](Get-ComProperty $doc 'Name')
        # CATIA keeps hidden feature catalogs (*.CATfct) open in the background; they are not user documents
        # CATIA は *.CATfct (フィーチャーカタログ) を裏で開いたままにする。利用者の文書ではないので対象外
        if ($name -like '*.CATfct') {
            Write-Log -Message "  Document $i : $name (feature catalog, skipped / カタログのため対象外)"
            continue
        }
        $saved = [bool](Get-ComProperty $doc 'Saved')
        $path = ''
        try { $path = [string](Get-ComProperty $doc 'Path') }
        catch {
            try { $path = [string](Split-Path -Parent ([string](Get-ComProperty $doc 'FullName'))) } catch { $path = '' }
        }
        # A new document that was never written to disk can report Saved=True; back it up as well
        # 一度もディスクに保存していない新規文書は Saved=True を返すことがあるため、これもバックアップ対象にする
        $neverSaved = [string]::IsNullOrEmpty($path)
        $needBackup = (-not $saved) -or $neverSaved
        Write-Log -Message ("  Document {0} : {1}  Saved={2}  Path='{3}'  -> {4}" -f $i, $name, $saved, $path, $(if ($needBackup) { 'backup / バックアップ' } else { 'no change / 変更なし' }))
        if ($needBackup) {
            [void]$unsaved.Add(@{ Doc = $doc; Name = $name })
        }
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

    foreach ($entry in $ordered) {
        $name = $entry.Name
        try {
            $original = ''
            try { $original = [string](Get-ComProperty $entry.Doc 'FullName') } catch { }
            $target = Get-UniquePath -Folder $folder -Name $name
            [void](Invoke-ComMethod $entry.Doc 'SaveAs' @([string]$target))
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
        # Suppress CATIA confirmation dialogs so that SaveAs/Quit never wait for a click
        # 保存/終了の途中で CATIA の確認画面が出て止まらないよう、確認表示を止める
        $alertsBefore = $null
        try {
            $alertsBefore = Get-ComProperty $catia 'DisplayFileAlerts'
            Set-ComProperty $catia 'DisplayFileAlerts' $false
        }
        catch {
            Write-Log -Level WARN -Message "Could not turn off CATIA file alerts / CATIA の確認表示を止められません: $($_.Exception.Message)"
        }

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
            if ($null -ne $alertsBefore) {
                try { Set-ComProperty $catia 'DisplayFileAlerts' ([bool]$alertsBefore) } catch { }
            }
            Remove-ComReference $catia
            return $false
        }

        try {
            [void](Invoke-ComMethod $catia 'Quit')
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
# Password (exit / auto-start setting) / パスワード (終了・自動起動の設定変更)
#   EN: Only the salted SHA-256 hash is stored, never the password itself.
#       This deters casual exits; it cannot stop someone ending the process in Task Manager.
#   JP: 保存するのはソルト付き SHA-256 のハッシュだけで、パスワード自体は保存しない。
#       うっかり終了を防ぐ抑止策であり、タスクマネージャーでの強制終了は防げない。
# ------------------------------------------------------------------
function Get-PasswordHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('CatiaIdleGuard:' + $Text))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Confirm-Password {
    # Returns $true if the password is correct or no password is set / 正しい、またはパスワード未設定なら $true
    param(
        [ValidateSet('exit', 'autostart', 'config')][string]$Action,
        [string]$ExpectedHash   # default: the current (approved) settings / 省略時は現在の承認済み設定
    )
    if ($PSBoundParameters.ContainsKey('ExpectedHash')) { $expected = $ExpectedHash }
    else { $expected = [string]$script:Config.ExitPasswordHash }
    if ([string]::IsNullOrWhiteSpace($expected)) { return $true }

    if ($Action -eq 'config') {
        $en = 'config.json was changed. Enter the password to accept the change. Cancel restores the previous settings.'
        $jp = 'config.json が変更されました。変更を認めるにはパスワードを入力してください。キャンセルすると元の設定に戻します。'
        $th = 'config.json ถูกแก้ไข กรุณาใส่รหัสผ่านเพื่อยอมรับการเปลี่ยนแปลง หากยกเลิก จะคืนค่าการตั้งค่าเดิม'
    }
    elseif ($Action -eq 'exit') {
        $en = 'Enter the password to exit CATIA Idle Guard.'
        $jp = 'CATIA Idle Guard を終了するには、パスワードを入力してください。'
        $th = 'กรุณาใส่รหัสผ่านเพื่อปิด CATIA Idle Guard'
    }
    else {
        $en = 'Enter the password to change the auto-start setting.'
        $jp = '自動起動の設定を変更するには、パスワードを入力してください。'
        $th = 'กรุณาใส่รหัสผ่านเพื่อเปลี่ยนการตั้งค่าเริ่มอัตโนมัติ'
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CATIA Idle Guard'
    $form.ClientSize = New-Object System.Drawing.Size(470, 240)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true

    $y = 12
    foreach ($line in @(@{ T = $en; F = 'Segoe UI' }, @{ T = $jp; F = $script:UiFont }, @{ T = $th; F = $script:ThaiFont })) {
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize = $false
        $l.Location = New-Object System.Drawing.Point(15, $y)
        $l.Size = New-Object System.Drawing.Size(440, 40)
        $l.Font = New-Object System.Drawing.Font($line.F, 9.5)
        $l.Text = $line.T
        $form.Controls.Add($l)
        $y += 42
    }

    $box = New-Object System.Windows.Forms.TextBox
    $box.UseSystemPasswordChar = $true
    $box.Location = New-Object System.Drawing.Point(15, 144)
    $box.Size = New-Object System.Drawing.Size(440, 26)
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 11)
    $form.Controls.Add($box)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Size = New-Object System.Drawing.Size(100, 32)
    $ok.Location = New-Object System.Drawing.Point(245, 192)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel / キャンセル'
    $cancel.Size = New-Object System.Drawing.Size(110, 32)
    $cancel.Location = New-Object System.Drawing.Point(355, 192)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    $form.Add_Shown({ $form.Activate(); $box.Focus() }.GetNewClosure())
    $result = $form.ShowDialog()
    $entered = $box.Text
    $form.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
    if ((Get-PasswordHash $entered) -eq $expected) { return $true }

    Write-Log -Level WARN -Message "Wrong password ($Action) / パスワード誤り ($Action)"
    [void][System.Windows.Forms.MessageBox]::Show(
        "Wrong password.`r`nパスワードが違います。`r`nรหัสผ่านไม่ถูกต้อง",
        'CATIA Idle Guard', 'OK', 'Warning')
    return $false
}

# ------------------------------------------------------------------
# Auto-start at sign-in / サインイン時の自動起動
#   EN: A shortcut to Start-CatiaIdleGuard.bat in the user's Startup folder. It is re-created if the
#       tool folder was moved. Turned on/off from the tray menu; the choice is saved in config.json.
#   JP: ユーザーのスタートアップフォルダに Start-CatiaIdleGuard.bat へのショートカットを置く。
#       ツールのフォルダを移動した場合は作り直す。トレイメニューでオン/オフし、config.json に保存する。
# ------------------------------------------------------------------
function Get-StartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'CATIA Idle Guard.lnk')
}

function Test-AutoStartup {
    return (Test-Path -LiteralPath (Get-StartupShortcutPath))
}

function Register-AutoStartup {
    $bat = Join-Path $script:ScriptDir 'Start-CatiaIdleGuard.bat'
    if (-not (Test-Path -LiteralPath $bat)) {
        Write-Log -Level WARN -Message "Auto-start not registered: launcher not found / 自動起動を登録できません (起動用 bat が見つかりません): $bat"
        return $false
    }
    $lnk = Get-StartupShortcutPath
    $shell = New-Object -ComObject WScript.Shell
    try {
        if (Test-Path -LiteralPath $lnk) {
            $current = $shell.CreateShortcut($lnk)
            if ([string]$current.TargetPath -eq $bat) { return $true }   # already correct / 登録済み
        }
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath = $bat
        $sc.WorkingDirectory = $script:ScriptDir
        $sc.WindowStyle = 7   # minimized / 最小化
        $sc.Description = 'CATIA V5 Idle Guard'
        $sc.Save()
        Write-Log -Message "Auto-start at sign-in registered / サインイン時の自動起動を登録しました: $lnk -> $bat"
        return $true
    }
    finally {
        Remove-ComReference $shell
    }
}

function Unregister-AutoStartup {
    $lnk = Get-StartupShortcutPath
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Log -Message "Auto-start at sign-in removed / サインイン時の自動起動を解除しました: $lnk"
    }
}

function Repair-AutoStartup {
    # EN: While running, undo a removal or a Task Manager "Disable" of the per-user auto-start.
    #     The only intended way to turn it off is the password-protected tray menu.
    # JP: 動作中に、スタートアップの削除やタスクマネージャーでの「無効化」を元に戻す。
    #     正式に止める方法は、パスワード付きのトレイメニューだけとする。
    if ((Test-IsManaged) -or -not [bool]$script:Config.AutoStartup) { return }
    $lnk = Get-StartupShortcutPath
    $existed = Test-Path -LiteralPath $lnk
    [void](Register-AutoStartup)
    if (-not $existed -and (Test-Path -LiteralPath $lnk)) {
        Write-Log -Level WARN -Message 'Auto-start shortcut was removed and has been restored / 自動起動のショートカットが削除されていたため復元しました'
    }
    # Task Manager stores "Disabled" here (first byte 0x02 = enabled). Removing the value re-enables it.
    # タスクマネージャーの「無効」はここに記録される (先頭バイト 0x02 = 有効)。値を消すと有効に戻る。
    $approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    try {
        $item = Get-ItemProperty -Path $approvedKey -Name 'CATIA Idle Guard.lnk' -ErrorAction Stop
        $bytes = [byte[]]$item.'CATIA Idle Guard.lnk'
        if ($null -ne $bytes -and $bytes.Length -gt 0 -and $bytes[0] -ne 2) {
            Remove-ItemProperty -Path $approvedKey -Name 'CATIA Idle Guard.lnk' -ErrorAction Stop
            Write-Log -Level WARN -Message 'Auto-start was disabled in Task Manager and has been re-enabled / タスクマネージャーで無効にされていた自動起動を有効に戻しました'
        }
    }
    catch { }   # no value = enabled / 値が無ければ有効
}

# ------------------------------------------------------------------
# Settings protection (no administrator rights needed) / 設定の保護 (管理者権限不要)
#   EN: The approved config.json (bytes + SHA-256) is kept in HKCU\Software\CatiaIdleGuard.
#       If config.json is changed, deleted or moved outside the tool, the password of the APPROVED
#       settings is asked. Correct = accept the change. Cancel/wrong = restore the approved file.
#       This deters editing with Notepad; a user who knows the mechanism can still get around it.
#   JP: 承認済みの config.json (中身 + SHA-256) を HKCU\Software\CatiaIdleGuard に控える。
#       ツール以外で config.json が変更・削除・移動されたら、承認済み設定のパスワードを求める。
#       正しければ変更を承認、キャンセル/誤りなら承認済みの内容に戻す。
#       メモ帳での書き換えを防ぐ抑止策であり、仕組みを知る人は回避できる。
# ------------------------------------------------------------------
$script:RegPath = 'HKCU:\Software\CatiaIdleGuard'

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-NormalizedConfigPath {
    try { return [System.IO.Path]::GetFullPath([string]$script:ConfigPath) } catch { return [string]$script:ConfigPath }
}

function Save-ApprovedConfig {
    $path = Get-NormalizedConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if (-not (Test-Path -LiteralPath $script:RegPath)) { New-Item -Path $script:RegPath -Force | Out-Null }
    Set-ItemProperty -Path $script:RegPath -Name 'ConfigPath'   -Value $path
    Set-ItemProperty -Path $script:RegPath -Name 'ConfigHash'   -Value (Get-BytesSha256 $bytes)
    Set-ItemProperty -Path $script:RegPath -Name 'ConfigBackup' -Value ([Convert]::ToBase64String($bytes))
}

function Get-ApprovedConfigState {
    # Returns @{ State = 'first' | 'ok' | 'changed'; Backup = byte[] }
    $none = @{ State = 'first'; Backup = $null }
    try { $r = Get-ItemProperty -Path $script:RegPath -ErrorAction Stop } catch { return $none }
    foreach ($n in 'ConfigPath', 'ConfigHash', 'ConfigBackup') {
        if ($null -eq $r.PSObject.Properties[$n]) { return $none }
    }
    try { $backup = [Convert]::FromBase64String([string]$r.ConfigBackup) } catch { return $none }
    $path = Get-NormalizedConfigPath
    $samePath = [string]::Equals([string]$r.ConfigPath, $path, [System.StringComparison]::OrdinalIgnoreCase)
    if ($samePath -and (Test-Path -LiteralPath $path)) {
        $hash = Get-BytesSha256 ([System.IO.File]::ReadAllBytes($path))
        if ($hash -eq [string]$r.ConfigHash) { return @{ State = 'ok'; Backup = $backup } }
    }
    return @{ State = 'changed'; Backup = $backup }
}

function Test-ConfigMatchesDefaults {
    # True if every known setting in config.json equals the built-in default (missing key = default)
    # config.json の各設定が本体の標準値と同じなら True (項目が無ければ標準値とみなす)
    $path = Get-NormalizedConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        $obj = $text | ConvertFrom-Json
    }
    catch { return $false }
    foreach ($k in @($script:DefaultConfig.Keys)) {
        $def = [string]$script:DefaultConfig[$k]
        $prop = $obj.PSObject.Properties[$k]
        $val = if ($null -ne $prop) { [string]$prop.Value } else { $def }
        if ($val -ne $def) {
            Write-Log -Level WARN -Message "  Differs from default / 標準値と異なる: $k = '$val' (default / 標準値 '$def')"
            return $false
        }
    }
    return $true
}

function Write-DefaultConfig {
    # Write the built-in defaults to config.json / 本体の標準値を config.json に書き出す
    $ordered = [ordered]@{}
    foreach ($k in @($script:DefaultConfig.Keys)) { $ordered[$k] = $script:DefaultConfig[$k] }
    $ordered | ConvertTo-Json | Set-Content -LiteralPath (Get-NormalizedConfigPath) -Encoding UTF8
}

function Invoke-ConfigProtection {
    if ((Test-IsManaged)) { return }   # Program Files install: protected by NTFS / 管理者インストールは NTFS で保護
    $st = Get-ApprovedConfigState
    if ($st.State -eq 'ok') { return }
    if ($st.State -eq 'first') {
        # No approved copy yet (first run, or the registry record was deleted). Never trust the file as it is:
        # it is approved only if it equals the built-in defaults, or with the password.
        # 承認済みの控えが無い (初回、または控えが消された)。ファイルをそのまま信用しない:
        # 本体の標準値と同じ場合か、パスワードが正しい場合だけ承認する。
        if (Test-ConfigMatchesDefaults) {
            Save-ApprovedConfig
            Write-Log -Message 'Settings protection on: config.json equals the defaults and was approved / 設定の保護を開始: config.json は標準値どおりのため承認しました'
            return
        }
        Write-Log -Level WARN -Message 'Settings protection on: config.json differs from the defaults / 設定の保護を開始: config.json が標準値と異なります'
        $path = Get-NormalizedConfigPath
        if ((Test-Path -LiteralPath $path) -and
            (Confirm-Password -Action 'config' -ExpectedHash ([string]$script:DefaultConfig.ExitPasswordHash))) {
            Save-ApprovedConfig
            Import-Settings
            Write-Log -Message 'Non-default config.json approved with password / パスワードにより標準値以外の config.json を承認しました'
        }
        else {
            Write-DefaultConfig
            Save-ApprovedConfig
            Import-Settings
            Write-Log -Level WARN -Message 'config.json reset to the defaults / config.json を標準値に戻しました'
            Show-Balloon -Title 'CATIA Idle Guard' -Text ("Settings reset to defaults.`n設定を標準値に戻しました`nคืนค่าเริ่มต้นแล้ว")
        }
        return
    }

    Write-Log -Level WARN -Message 'config.json was changed, deleted or moved outside the tool / config.json がツール以外で変更・削除・移動されました'
    # Password of the APPROVED settings (not of the edited file) / 編集後のファイルではなく、承認済み設定のパスワード
    $prevHash = [string]$script:DefaultConfig.ExitPasswordHash
    try {
        $text = [System.Text.Encoding]::UTF8.GetString($st.Backup).TrimStart([char]0xFEFF)
        $prev = $text | ConvertFrom-Json
        if ($null -ne $prev.PSObject.Properties['ExitPasswordHash']) { $prevHash = [string]$prev.ExitPasswordHash }
    }
    catch { }

    $path = Get-NormalizedConfigPath
    if ((Test-Path -LiteralPath $path) -and (Confirm-Password -Action 'config' -ExpectedHash $prevHash)) {
        Save-ApprovedConfig
        Import-Settings
        Write-Log -Message 'config.json change accepted with password / パスワードにより config.json の変更を承認しました'
    }
    else {
        [System.IO.File]::WriteAllBytes($path, $st.Backup)
        Save-ApprovedConfig
        Import-Settings
        Write-Log -Level WARN -Message 'config.json restored to the approved settings / config.json を承認済みの設定に戻しました'
        Show-Balloon -Title 'CATIA Idle Guard' -Text ("Settings restored.`n設定を元に戻しました`nคืนค่าการตั้งค่าแล้ว")
    }
}

function Set-ConfigValue {
    # Save one setting to config.json (other settings are kept) / config.json の 1 項目だけを書き換える
    param([string]$Name, $Value)
    $obj = $null
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try { $obj = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $obj = $null }
    }
    if ($null -eq $obj) { $obj = New-Object PSObject }
    $obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    $obj | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    $script:Config[$Name] = $Value
    try { Save-ApprovedConfig } catch { }   # changes made by the tool itself are approved / ツール自身の変更は承認済みにする
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
    $itemAuto = New-Object System.Windows.Forms.ToolStripMenuItem('Start at sign-in / サインイン時に自動起動 / เริ่มอัตโนมัติเมื่อลงชื่อเข้าใช้')
    $itemAuto.Checked = (Test-AutoStartup)
    if ((Test-IsManaged)) {
        $itemAuto.Text = 'Start at sign-in (set by administrator) / サインイン時に自動起動 (管理者設定) / เริ่มอัตโนมัติ (ตั้งค่าโดยผู้ดูแลระบบ)'
        $itemAuto.Checked = $true
        $itemAuto.Enabled = $false
    }
    $itemAuto.Add_Click({
        # $this = the clicked menu item / クリックされたメニュー項目
        if (-not (Confirm-Password -Action 'autostart')) { return }
        try {
            if ($this.Checked) {
                Unregister-AutoStartup
                Set-ConfigValue -Name 'AutoStartup' -Value $false
            }
            else {
                [void](Register-AutoStartup)
                Set-ConfigValue -Name 'AutoStartup' -Value $true
            }
        }
        catch {
            Write-Log -Level ERROR -Message "Auto-start setting failed / 自動起動の設定に失敗: $($_.Exception.Message)"
        }
        $this.Checked = (Test-AutoStartup)
    })
    [void]$menu.Items.Add($itemAuto)
    [void]$menu.Items.Add('-')
    $itemExit = $menu.Items.Add('Exit Idle Guard / Idle Guard を終了 / ปิด Idle Guard')
    $itemExit.Add_Click({
        if (Confirm-Password -Action 'exit') {
            Write-Log -Message 'Exit requested from the tray menu / トレイメニューから終了'
            $script:Running = $false
        }
    })
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
try { Invoke-ConfigProtection }
catch { Write-Log -Level WARN -Message "Settings protection check failed / 設定の保護の確認に失敗: $($_.Exception.Message)" }
if ((Test-IsManaged)) {
    # Auto-start comes from HKLM Run; remove a leftover per-user shortcut / 自動起動は HKLM Run が担当。ユーザー単位の残りを外す
    try { Unregister-AutoStartup } catch { }
}
elseif ($RegisterStartup -and [bool]$script:Config.AutoStartup) {
    try { [void](Register-AutoStartup) }
    catch { Write-Log -Level WARN -Message "Auto-start registration failed / 自動起動の登録に失敗: $($_.Exception.Message)" }
}
Initialize-Tray

$trackedPids = @()
$lastActivity = Get-Date
$lastInputTick = [CatiaIdleGuard.Native]::GetLastInputTick()
$idleLimit = [TimeSpan]::FromMinutes([double]$script:Config.IdleMinutes)
$pollMs = [Math]::Max(200, [int]([double]$script:Config.PollSeconds * 1000))
$lastRepair = [DateTime]::MinValue
$lastConfigCheck = Get-Date
$script:ConfigReloaded = $false

try {
    while ($script:Running) {
        try {
            # Every 15 s: detect changes to config.json / 15 秒ごと: config.json の変更を検出
            if (((Get-Date) - $lastConfigCheck).TotalSeconds -ge 15) {
                $lastConfigCheck = Get-Date
                try { Invoke-ConfigProtection } catch { Write-Log -Level WARN -Message "Settings protection check failed / 設定の保護の確認に失敗: $($_.Exception.Message)" }
            }
            if ($script:ConfigReloaded) {
                $script:ConfigReloaded = $false
                $idleLimit = [TimeSpan]::FromMinutes([double]$script:Config.IdleMinutes)
                $pollMs = [Math]::Max(200, [int]([double]$script:Config.PollSeconds * 1000))
                Write-Log -Message ('Settings applied / 設定を反映 (IdleMinutes={0}, WarningSeconds={1})' -f $script:Config.IdleMinutes, $script:Config.WarningSeconds)
            }

            # Every 60 s: restore per-user auto-start if it was removed or disabled (normal start only)
            # 60 秒ごと: ユーザー単位の自動起動が外されていたら戻す (通常起動時のみ)
            if ($RegisterStartup -and ((Get-Date) - $lastRepair).TotalSeconds -ge 60) {
                $lastRepair = Get-Date
                try { Repair-AutoStartup } catch { Write-Log -Level WARN -Message "Auto-start check failed / 自動起動の確認に失敗: $($_.Exception.Message)" }
            }
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
                        # Keep one short line per language so all three fit / 3 言語が収まるよう各言語 1 行に短くする
                        Show-Balloon -Title 'CATIA Idle Guard' -Text ("CATIA closed. License returned.`n" +
                            "CATIA を終了し、ライセンスを返却`n" +
                            'ปิด CATIA และคืนไลเซนส์แล้ว')
                        $trackedPids = @()
                    }
                    else {
                        Show-Balloon -Title 'CATIA Idle Guard' -Text ("CATIA not closed. See the log.`n" +
                            "CATIA を終了できません。ログ参照`n" +
                            'ปิด CATIA ไม่ได้ กรุณาดู Log')
                        # Grace period so the warning does not repeat immediately / 連続して警告を出し続けないよう、再判定までの猶予を設ける
                        $lastActivity = Get-Date
                    }
                }
            }
        }
        catch {
            # Keep running: log the error and wait before the next idle check
            # 終了せずに動き続ける: エラーを記録し、次の判定まで猶予を置く
            Write-Log -Level ERROR -Message "Unexpected error (continuing) / 予期しないエラー (動作は継続): $($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]"
            $lastActivity = Get-Date
        }

        Wait-Poll -Milliseconds $pollMs
    }
}
catch {
    Write-Log -Level ERROR -Message "Fatal error / 致命的なエラー: $($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]"
}
finally {
    if ($null -ne $script:Tray) {
        $script:Tray.Icon.Visible = $false
        $script:Tray.Icon.Dispose()
    }
    if ($script:HasMutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
    }
    Write-Log -Message 'CATIA Idle Guard stopped / 終了しました。'
}
