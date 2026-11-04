#Requires -Version 5.1
<#
.SYNOPSIS
    CATIA Shareable Guard
    EN: Releases CATIA V5 *shareable product* licenses after a period of inactivity. CATIA stays open;
        the commands of the released products are greyed out until the licenses are re-acquired.
    JP: 無操作が続いたとき、CATIA V5 の「シェアラブル製品」のライセンスだけを返却する常駐ツール。
        CATIA は終了しない。返却した製品のコマンドは、再取得するまでグレーアウトする。

.DESCRIPTION
    EN:
    - Keyboard/mouse input while a CATIA (CNEXT.exe) window is in the foreground counts as "CATIA activity".
    - After IdleMinutes without activity: warning with countdown, then the shareable licenses are released
      through CATIA's automation interface (SettingControllers "CATSysDynLicenseSettingCtrl", SetLicense).
    - When the user comes back to CATIA, the same licenses are requested again automatically.
    - The base configuration license is NOT released (CATIA cannot release it without exiting).
    - Diagnostic switches (-ListLicenses, -ReleaseNow, -RequestNow) test the interface on a real PC.
    JP:
    - CATIA (CNEXT.exe) のウィンドウが前面にある状態でのキーボード/マウス入力を「CATIA 操作」とみなす。
    - IdleMinutes の間 操作が無ければ、カウントダウン付きの警告の後、CATIA の自動化インターフェース
      (SettingControllers "CATSysDynLicenseSettingCtrl" の SetLicense) でシェアラブル製品のライセンスを返却する。
    - 利用者が CATIA に戻ると、同じライセンスを自動で再取得する。
    - 基本構成 (コンフィギュレーション) のライセンスは返却しない (CATIA を終了しないと返せないため)。
    - 診断用スイッチ (-ListLicenses, -ReleaseNow, -RequestNow) で、実機でインターフェースの挙動を確認できる。

.PARAMETER ListLicenses
    EN: Print the shareable licenses and their states, then exit. / JP: シェアラブル製品の一覧と状態を表示して終了。
.PARAMETER ReleaseNow
    EN: Release the shareable licenses once, then exit. / JP: シェアラブル製品を 1 回返却して終了。
.PARAMETER RequestNow
    EN: Request the configured shareable licenses once, then exit. / JP: 設定のシェアラブル製品を 1 回要求して終了。

.NOTES
    Windows PowerShell 5.1. Do not run as Administrator (COM needs the same privilege level as CATIA).
    Save as UTF-8 with BOM.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [double]$IdleMinutes,
    [int]$WarningSeconds,
    [switch]$NoTray,
    [switch]$ListLicenses,
    [switch]$ReleaseNow,
    [switch]$RequestNow
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------
# Script folder / スクリプトのフォルダ
# ------------------------------------------------------------------
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) { try { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $script:ScriptDir = $null } }
if (-not $script:ScriptDir -and $ConfigPath) { $script:ScriptDir = Split-Path -Parent $ConfigPath }
if (-not $script:ScriptDir) { $script:ScriptDir = (Get-Location).Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $script:ScriptDir 'config.json' }

# ------------------------------------------------------------------
# Settings / 設定
# ------------------------------------------------------------------
$script:DefaultConfig = [ordered]@{
    IdleMinutes        = 15          # Release after this many minutes without CATIA activity / この分数 CATIA 操作が無ければ返却
    WarningSeconds     = 30          # Countdown before release (0 = no warning) / 返却前のカウントダウン秒数 (0 = 警告なし)
    PollSeconds        = 1
    ProcessName        = 'CNEXT'
    Licenses           = @()         # Shareable products to manage, e.g. "ST1.prd". Empty = all currently granted / 対象製品。空 = 現在取得中のすべて
    ReacquireOnReturn  = $true       # Request the released licenses again when the user returns / 戻ってきたら自動で再取得
    ControllerName     = 'CATSysDynLicenseSettingCtrl'   # CATIA settings controller for shareable products / シェアラブル製品の設定コントローラ
    ReleaseValue       = 'NotRequested'   # SetLicense value to release / 返却時の値
    RequestValue       = 'Requested'      # SetLicense value to request. Some versions want the license name itself / 要求時の値。版によってはライセンス名そのもの
    LogFolder          = 'logs'
    LogRetentionDays   = 30
}

function Get-Config {
    param([string]$Path)
    $cfg = [ordered]@{}
    foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
    if (Test-Path -LiteralPath $Path) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value } }
        }
        catch { Write-Warning "config.json could not be read, using defaults / config.json を読めないため既定値で続行: $($_.Exception.Message)" }
    }
    $cfg.Licenses = @($cfg.Licenses | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
    $cfg.LogFolder = [Environment]::ExpandEnvironmentVariables([string]$cfg.LogFolder)
    if (-not [IO.Path]::IsPathRooted([string]$cfg.LogFolder)) { $cfg.LogFolder = Join-Path $script:ScriptDir ([string]$cfg.LogFolder) }
    return $cfg
}
$script:Config = Get-Config -Path $ConfigPath
if ($PSBoundParameters.ContainsKey('IdleMinutes'))    { $script:Config.IdleMinutes    = $IdleMinutes }
if ($PSBoundParameters.ContainsKey('WarningSeconds')) { $script:Config.WarningSeconds = $WarningSeconds }

# ------------------------------------------------------------------
# Logging / ログ
# ------------------------------------------------------------------
function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $script:Config.LogFolder ('CatiaShareableGuard_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))) -Value $line -Encoding UTF8
    }
    catch { }
    Write-Host $line
}

function Remove-OldLogs {
    try {
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { return }
        $limit = (Get-Date).AddDays(-1 * [int]$script:Config.LogRetentionDays)
        Get-ChildItem -LiteralPath $script:Config.LogFolder -Filter 'CatiaShareableGuard_*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

# ------------------------------------------------------------------
# Win32 API (last input time / foreground window) / Win32 API (最終入力時刻 / 前面ウィンドウ)
# ------------------------------------------------------------------
Add-Type -Namespace CatiaShareableGuard -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
public static uint GetLastInputTick() {
    LASTINPUTINFO lii = new LASTINPUTINFO();
    lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
    if (!GetLastInputInfo(ref lii)) return 0;
    return lii.dwTime;
}
public static uint GetForegroundProcessId() {
    IntPtr h = GetForegroundWindow();
    if (h == IntPtr.Zero) return 0;
    uint pid; GetWindowThreadProcessId(h, out pid); return pid;
}
'@
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-FontName {
    param([string]$Preferred, [string]$Fallback)
    try {
        $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
        if ($installed -contains $Preferred) { return $Preferred }
    }
    catch { }
    return $Fallback
}
$script:UiFont = Get-FontName 'Meiryo UI' 'Segoe UI'
$script:ThaiFont = Get-FontName 'Leelawadee UI' 'Tahoma'

# ------------------------------------------------------------------
# Single instance / 多重起動の防止 (not for diagnostic switches / 診断スイッチでは行わない)
# ------------------------------------------------------------------
$script:Diagnostic = ($ListLicenses -or $ReleaseNow -or $RequestNow)
$script:Mutex = $null
$script:HasMutex = $false
if (-not $script:Diagnostic) {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\CatiaShareableGuard')
    try { $script:HasMutex = $script:Mutex.WaitOne(0, $false) }
    catch [System.Threading.AbandonedMutexException] { $script:HasMutex = $true }
    if (-not $script:HasMutex) {
        [void][System.Windows.Forms.MessageBox]::Show("CATIA Shareable Guard is already running.`r`nCATIA Shareable Guard は既に起動しています。`r`nCATIA Shareable Guard กำลังทำงานอยู่แล้ว", 'CATIA Shareable Guard', 'OK', 'Information')
        exit 0
    }
}

# ------------------------------------------------------------------
# CATIA process / input / CATIA プロセス・入力
# ------------------------------------------------------------------
function Get-CatiaProcesses { return ,@(Get-Process -Name $script:Config.ProcessName -ErrorAction SilentlyContinue) }

function Test-CatiaForeground {
    param([int[]]$CatiaPids)
    if (-not $CatiaPids -or $CatiaPids.Count -eq 0) { return $false }
    $fg = [int64][CatiaShareableGuard.Native]::GetForegroundProcessId()
    foreach ($p in $CatiaPids) { if ([int64]$p -eq $fg) { return $true } }
    return $false
}

function Wait-Poll {
    param([int]$Milliseconds)
    $end = (Get-Date).AddMilliseconds($Milliseconds)
    do { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 } while ((Get-Date) -lt $end -and $script:Running)
}

# ------------------------------------------------------------------
# COM helpers (late binding by name) / COM ヘルパー (名前指定の遅延バインディング)
# ------------------------------------------------------------------
function Get-ComErrorText {
    param($ErrorRecord)
    $ex = $ErrorRecord.Exception
    if ($null -ne $ex.InnerException) { return $ex.InnerException.Message }
    return $ex.Message
}
function Get-ComProperty {
    param($Obj, [string]$Name)
    try { $v = [System.__ComObject].InvokeMember($Name, [System.Reflection.BindingFlags]::GetProperty, $null, $Obj, $null) }
    catch { throw "COM get '$Name' failed / COM 取得 '$Name' に失敗: $(Get-ComErrorText $_)" }
    return ,$v
}
function Invoke-ComMethod {
    # Returns @{ Result = return value; Args = argument array after the call (out/ByRef parameters) }
    # 戻り値: @{ Result = 戻り値; Args = 呼び出し後の引数配列 (出力/参照渡しの引数) }
    param($Obj, [string]$Name, [object[]]$Arguments = @())
    $argsCopy = [object[]]$Arguments.Clone()
    try { $v = [System.__ComObject].InvokeMember($Name, [System.Reflection.BindingFlags]::InvokeMethod, $null, $Obj, $argsCopy) }
    catch { throw "COM call '$Name' failed / COM 呼び出し '$Name' に失敗: $(Get-ComErrorText $_)" }
    return @{ Result = $v; Args = $argsCopy }
}
function Remove-ComReference { param($Obj); if ($null -ne $Obj) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Obj) } catch { } } }

function Connect-Catia {
    try { return [Runtime.InteropServices.Marshal]::GetActiveObject('CATIA.Application') }
    catch { Write-Log -Level WARN -Message "COM connection to CATIA failed / CATIA への COM 接続に失敗: $($_.Exception.Message)"; return $null }
}

# ------------------------------------------------------------------
# Shareable licenses / シェアラブル製品のライセンス
# ------------------------------------------------------------------
function Get-DynLicenseController {
    param($Catia)
    $ctrls = Get-ComProperty $Catia 'SettingControllers'
    return (Invoke-ComMethod $ctrls 'Item' @([string]$script:Config.ControllerName)).Result
}

function Get-ShareableLicenseNames {
    # List of shareable product identifiers (e.g. "ST1.prd") / シェアラブル製品の識別子一覧
    param($Ctrl)
    # GetLicensesList has one out parameter (array of strings) / GetLicensesList は出力引数 1 つ (文字列配列)
    $r = Invoke-ComMethod $Ctrl 'GetLicensesList' @($null)
    $list = $r.Args[0]
    if ($null -eq $list -and $null -ne $r.Result) { $list = $r.Result }
    if ($null -eq $list) { return ,@() }
    return ,@($list | ForEach-Object { [string]$_ })
}

function Get-ShareableLicenseState {
    # EN: Returns the state text of one license. Tries GetLicense, then GetLicenseInfo (two call shapes).
    # JP: ライセンス 1 件の状態文字列を返す。GetLicense、次に GetLicenseInfo (2 通りの呼び方) を試す。
    param($Ctrl, [string]$Name)
    try { $v = (Invoke-ComMethod $Ctrl 'GetLicense' @($Name)).Result; if ($null -ne $v) { return [string]$v } } catch { }
    try { $r = Invoke-ComMethod $Ctrl 'GetLicenseInfo' @($Name, $null); if ($null -ne $r.Args[1]) { return [string]$r.Args[1] }; if ($null -ne $r.Result) { return [string]$r.Result } } catch { }
    try { $v = (Invoke-ComMethod $Ctrl 'GetLicenseInfo' @($Name)).Result; if ($null -ne $v) { return [string]$v } } catch { }
    return '?'
}

function Test-LicenseHeld {
    # EN: True if the state text means requested/granted. / JP: 状態文字列が「要求中/取得済み」を意味すれば True
    param([string]$State)
    if ([string]::IsNullOrWhiteSpace($State) -or $State -eq '?') { return $false }
    return ($State -notmatch 'NotRequested|NotGranted|Not Requested|Not Granted|Released')
}

function Set-ShareableLicense {
    param($Ctrl, [string]$Name, [string]$Value)
    [void](Invoke-ComMethod $Ctrl 'SetLicense' @($Name, $Value))
}

function Save-LicenseSettings {
    # EN: Make the change effective / persistent. Errors are logged, not fatal. / JP: 変更を確定・保存。失敗はログのみ。
    param($Ctrl)
    foreach ($m in 'Commit', 'SaveRepository') {
        try { [void](Invoke-ComMethod $Ctrl $m @()) }
        catch { Write-Log -Level WARN -Message "$m failed (continuing) / $m に失敗 (続行): $($_.Exception.Message)" }
    }
}

function Get-TargetLicenses {
    # EN: Configured licenses, or all currently held shareable licenses. Returns @{ Names; States }.
    # JP: 設定で指定した製品、または現在取得中のシェアラブル製品すべて。戻り値 @{ Names; States }
    param($Ctrl)
    $all = @()
    try { $all = Get-ShareableLicenseNames $Ctrl }
    catch { Write-Log -Level WARN -Message "GetLicensesList failed / 一覧の取得に失敗: $($_.Exception.Message)" }
    $states = @{}
    foreach ($n in $all) { $states[$n] = Get-ShareableLicenseState $Ctrl $n }
    $configured = @($script:Config.Licenses)
    if ($configured.Count -gt 0) {
        foreach ($n in $configured) { if (-not $states.ContainsKey($n)) { $states[$n] = Get-ShareableLicenseState $Ctrl $n } }
        return @{ Names = $configured; States = $states }
    }
    $held = @($all | Where-Object { Test-LicenseHeld $states[$_] })
    return @{ Names = $held; States = $states }
}

function Write-LicenseReport {
    param($Ctrl)
    $t = Get-TargetLicenses $Ctrl
    Write-Log -Message ("Shareable licenses (controller {0}) / シェアラブル製品一覧:" -f $script:Config.ControllerName)
    if ($t.States.Count -eq 0) { Write-Log -Level WARN -Message '  (none found / 見つかりません)' }
    foreach ($n in ($t.States.Keys | Sort-Object)) {
        $mark = if ($t.Names -contains $n) { 'TARGET / 対象' } else { '' }
        Write-Log -Message ("  {0,-14} state / 状態: {1,-14} {2}" -f $n, $t.States[$n], $mark)
    }
}

function Release-ShareableLicenses {
    # EN: Release target licenses. Returns the names released. / JP: 対象ライセンスを返却。返却した名前を返す。
    $catia = Connect-Catia
    if ($null -eq $catia) { return ,@() }
    $released = New-Object System.Collections.ArrayList
    try {
        $ctrl = Get-DynLicenseController $catia
        $t = Get-TargetLicenses $ctrl
        if ($t.Names.Count -eq 0) { Write-Log -Message 'No shareable license to release / 返却するシェアラブル製品はありません'; return ,@() }
        foreach ($n in $t.Names) {
            try {
                Set-ShareableLicense $ctrl $n ([string]$script:Config.ReleaseValue)
                [void]$released.Add($n)
                Write-Log -Message "Released / 返却: $n (was / 前の状態: $($t.States[$n]))"
            }
            catch { Write-Log -Level ERROR -Message "Release failed / 返却に失敗: $n : $($_.Exception.Message)" }
        }
        Save-LicenseSettings $ctrl
        foreach ($n in $released) { Write-Log -Message "  after / 返却後: $n = $(Get-ShareableLicenseState $ctrl $n)" }
        Remove-ComReference $ctrl
    }
    catch { Write-Log -Level ERROR -Message "Release failed / 返却処理に失敗: $($_.Exception.Message)" }
    finally { Remove-ComReference $catia }
    return ,@($released)
}

function Request-ShareableLicenses {
    # EN: Request the given licenses again. Returns names NOT obtained. / JP: 指定ライセンスを再要求。取得できなかった名前を返す。
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return ,@() }
    $catia = Connect-Catia
    if ($null -eq $catia) { return ,@($Names) }
    $failed = New-Object System.Collections.ArrayList
    try {
        $ctrl = Get-DynLicenseController $catia
        foreach ($n in $Names) {
            $value = [string]$script:Config.RequestValue
            if ($value -eq '') { $value = $n }
            try { Set-ShareableLicense $ctrl $n $value; Write-Log -Message "Requested / 要求: $n" }
            catch {
                # Some versions expect the license name as the value / 版によっては値にライセンス名を渡す
                try { Set-ShareableLicense $ctrl $n $n; Write-Log -Message "Requested (name as value) / 要求 (値=名前): $n" }
                catch { [void]$failed.Add($n); Write-Log -Level ERROR -Message "Request failed / 要求に失敗: $n : $($_.Exception.Message)" }
            }
        }
        Save-LicenseSettings $ctrl
        foreach ($n in $Names) {
            $st = Get-ShareableLicenseState $ctrl $n
            Write-Log -Message "  after / 要求後: $n = $st"
            if (-not (Test-LicenseHeld $st) -and -not ($failed -contains $n)) { [void]$failed.Add($n) }
        }
        Remove-ComReference $ctrl
    }
    catch { Write-Log -Level ERROR -Message "Request failed / 要求処理に失敗: $($_.Exception.Message)"; foreach ($n in $Names) { if (-not ($failed -contains $n)) { [void]$failed.Add($n) } } }
    finally { Remove-ComReference $catia }
    return ,@($failed)
}

# ------------------------------------------------------------------
# Diagnostic switches / 診断スイッチ
# ------------------------------------------------------------------
if ($script:Diagnostic) {
    Write-Log -Message 'Diagnostic mode / 診断モード'
    $catia = Connect-Catia
    if ($null -eq $catia) { exit 1 }
    try {
        $ctrl = Get-DynLicenseController $catia
        Write-LicenseReport $ctrl
        Remove-ComReference $ctrl
    }
    catch { Write-Log -Level ERROR -Message "Controller access failed / コントローラの取得に失敗: $($_.Exception.Message)" }
    Remove-ComReference $catia
    if ($ReleaseNow) { $r = Release-ShareableLicenses; Write-Log -Message "Released / 返却: $($r -join ', ')" }
    if ($RequestNow) {
        $names = @($script:Config.Licenses)
        if ($names.Count -eq 0) { Write-Log -Level WARN -Message 'RequestNow needs "Licenses" in config.json / RequestNow は config.json の Licenses が必要' }
        else { $f = Request-ShareableLicenses $names; Write-Log -Message "Not obtained / 未取得: $($f -join ', ')" }
    }
    exit 0
}

# ------------------------------------------------------------------
# Warning dialog / 警告ダイアログ
# ------------------------------------------------------------------
function Show-WarningDialog {
    param([int]$Seconds, [int[]]$CatiaPids)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'CATIA Shareable Guard'
    $form.ClientSize = New-Object System.Drawing.Size(640, 300)
    $form.StartPosition = 'CenterScreen'; $form.TopMost = $true; $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.ControlBox = $false

    $newLabel = {
        param([int]$Y, [int]$H, [string]$FontName, [double]$Size)
        $l = New-Object System.Windows.Forms.Label; $l.AutoSize = $false
        $l.Location = New-Object System.Drawing.Point(15, $Y); $l.Size = New-Object System.Drawing.Size(610, $H)
        $l.Font = New-Object System.Drawing.Font($FontName, $Size); $form.Controls.Add($l); return $l
    }.GetNewClosure()
    $labelEn = & $newLabel 10 58 'Segoe UI' 9.5
    $labelJp = & $newLabel 72 58 $script:UiFont 9.5
    $labelTh = & $newLabel 134 62 $script:ThaiFont 10

    $btnContinue = New-Object System.Windows.Forms.Button
    $btnContinue.Text = "Continue working`r`n作業を続行する"; $btnContinue.Size = New-Object System.Drawing.Size(260, 52)
    $btnContinue.Location = New-Object System.Drawing.Point(45, 210); $btnContinue.Font = New-Object System.Drawing.Font($script:UiFont, 9.5)
    $btnContinue.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Controls.Add($btnContinue); $form.CancelButton = $btnContinue
    $btnNow = New-Object System.Windows.Forms.Button
    $btnNow.Text = "Release now`r`n今すぐ返却する"; $btnNow.Size = New-Object System.Drawing.Size(260, 52)
    $btnNow.Location = New-Object System.Drawing.Point(335, 210); $btnNow.Font = New-Object System.Drawing.Font($script:UiFont, 9.5)
    $btnNow.DialogResult = [System.Windows.Forms.DialogResult]::OK; $form.Controls.Add($btnNow)
    foreach ($cap in @(@{ X = 45; T = 'ทำงานต่อ' }, @{ X = 335; T = 'คืนไลเซนส์ทันที' })) {
        $l = New-Object System.Windows.Forms.Label; $l.AutoSize = $false; $l.TextAlign = 'MiddleCenter'
        $l.Location = New-Object System.Drawing.Point($cap.X, 266); $l.Size = New-Object System.Drawing.Size(260, 28)
        $l.Font = New-Object System.Drawing.Font($script:ThaiFont, 10); $l.Text = $cap.T; $form.Controls.Add($l)
    }

    $state = @{ Remaining = $Seconds; Result = 'Timeout'; LastTick = [CatiaShareableGuard.Native]::GetLastInputTick() }
    $testForeground = ${function:Test-CatiaForeground}
    $mins = $script:Config.IdleMinutes
    $update = {
        $sec = $state.Remaining
        $labelEn.Text = ("CATIA has not been used for {0} minutes.`r`n" + 'In {1} seconds the shareable product licenses will be released. CATIA stays open; the commands of those products become unavailable until you come back.') -f $mins, $sec
        $labelJp.Text = ("{0} 分間 CATIA の操作がありません。`r`n" + '{1} 秒後にシェアラブル製品のライセンスを返却します。CATIA は閉じません。戻ってくるまで、その製品のコマンドは使えなくなります。') -f $mins, $sec
        $labelTh.Text = ("ไม่ได้ใช้งาน CATIA มาแล้ว {0} นาที`r`n" + 'ในอีก {1} วินาที จะคืนไลเซนส์ของ Shareable Product โดย CATIA ยังเปิดอยู่ คำสั่งของผลิตภัณฑ์เหล่านั้นจะใช้ไม่ได้จนกว่าคุณจะกลับมา') -f $mins, $sec
    }.GetNewClosure()
    & $update
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000
    $timer.Add_Tick({
        $state.Remaining = $state.Remaining - 1
        $tick = [CatiaShareableGuard.Native]::GetLastInputTick()
        if ($tick -ne $state.LastTick) {
            $state.LastTick = $tick
            if (& $testForeground -CatiaPids $CatiaPids) { $state.Result = 'Continue'; $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; return }
        }
        if ($state.Remaining -le 0) { $state.Result = 'Timeout'; $form.DialogResult = [System.Windows.Forms.DialogResult]::Ignore; return }
        & $update
    }.GetNewClosure())
    $timer.Start()
    $form.Add_Shown({ $form.Activate() }.GetNewClosure())
    $dr = $form.ShowDialog(); $timer.Stop(); $timer.Dispose(); $form.Dispose()
    if ($dr -eq [System.Windows.Forms.DialogResult]::OK) { return 'ReleaseNow' }
    if ($dr -eq [System.Windows.Forms.DialogResult]::Cancel) { return 'Continue' }
    return $state.Result
}

# ------------------------------------------------------------------
# Tray / タスクトレイ
# ------------------------------------------------------------------
$script:Tray = $null
function Initialize-Tray {
    if ($NoTray) { return }
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = [System.Drawing.SystemIcons]::Information; $icon.Text = 'CATIA Shareable Guard'; $icon.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemStatus = $menu.Items.Add('Status / 状態 / สถานะ: Starting / 起動中 / กำลังเริ่มต้น'); $itemStatus.Enabled = $false
    [void]$menu.Items.Add('-')
    $itemRelease = $menu.Items.Add('Release shareable licenses now / 今すぐ返却 / คืนไลเซนส์ทันที')
    $itemRelease.Add_Click({ $script:ManualAction = 'release' })
    $itemRequest = $menu.Items.Add('Re-acquire released licenses / 再取得 / ขอไลเซนส์คืน')
    $itemRequest.Add_Click({ $script:ManualAction = 'request' })
    $itemLog = $menu.Items.Add('Open log folder / ログフォルダを開く / เปิดโฟลเดอร์ Log')
    $itemLog.Add_Click({ if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null }; Start-Process explorer.exe $script:Config.LogFolder })
    [void]$menu.Items.Add('-')
    $itemExit = $menu.Items.Add('Exit Shareable Guard / 終了 / ปิด')
    $itemExit.Add_Click({ $script:Running = $false })
    $icon.ContextMenuStrip = $menu
    $script:Tray = @{ Icon = $icon; Status = $itemStatus }
}
function Set-TrayStatus {
    param([string]$English, [string]$Japanese, [string]$Thai)
    if ($null -ne $script:Tray) {
        $script:Tray.Status.Text = "Status / 状態 / สถานะ: $English / $Japanese / $Thai"
        $tip = 'CATIA Shareable Guard - ' + $English; if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:Tray.Icon.Text = $tip
    }
}
function Show-Balloon { param([string]$Text); if ($null -ne $script:Tray) { try { $script:Tray.Icon.ShowBalloonTip(5000, 'CATIA Shareable Guard', $Text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { } } }

# ------------------------------------------------------------------
# Main loop / メインループ
# ------------------------------------------------------------------
$script:Running = $true
$script:ManualAction = $null
Write-Log -Message ('CATIA Shareable Guard started / 起動 (IdleMinutes={0}, WarningSeconds={1}, Licenses={2})' -f $script:Config.IdleMinutes, $script:Config.WarningSeconds, $(if ($script:Config.Licenses.Count) { $script:Config.Licenses -join ',' } else { 'all held / 取得中すべて' }))
Remove-OldLogs
Initialize-Tray

$trackedPids = @()
$lastActivity = Get-Date
$lastInputTick = [CatiaShareableGuard.Native]::GetLastInputTick()
$idleLimit = [TimeSpan]::FromMinutes([double]$script:Config.IdleMinutes)
$pollMs = [Math]::Max(200, [int]([double]$script:Config.PollSeconds * 1000))
$releasedNames = @()          # licenses we released and should re-acquire / 返却済みで再取得すべきライセンス
$lastRetry = [DateTime]::MinValue

try {
    while ($script:Running) {
        try {
            $pids = @((Get-CatiaProcesses) | ForEach-Object { [int]$_.Id })
            if ($pids.Count -eq 0) {
                if ($trackedPids.Count -gt 0) { Write-Log -Message 'CATIA exited / CATIA の終了を検出'; $trackedPids = @(); $releasedNames = @() }
                Set-TrayStatus 'CATIA not running' 'CATIA 未起動' 'CATIA ไม่ได้เปิดอยู่'
                Wait-Poll -Milliseconds $pollMs; continue
            }
            $newPids = @($pids | Where-Object { $trackedPids -notcontains $_ })
            if ($newPids.Count -gt 0) { Write-Log -Message "CATIA detected / CATIA を検出 (PID: $($newPids -join ', '))"; $lastActivity = Get-Date }
            $trackedPids = $pids

            $activeNow = $false
            $tick = [CatiaShareableGuard.Native]::GetLastInputTick()
            if ($tick -ne $lastInputTick) {
                $lastInputTick = $tick
                if (Test-CatiaForeground -CatiaPids $pids) { $lastActivity = Get-Date; $activeNow = $true }
            }

            # Manual actions from the tray / トレイからの手動操作
            if ($script:ManualAction -eq 'release') {
                $script:ManualAction = $null
                $r = Release-ShareableLicenses
                if ($r.Count -gt 0) { $releasedNames = @($releasedNames + $r | Select-Object -Unique); Show-Balloon ("Released / 返却 / คืนแล้ว: " + ($r -join ', ')) }
                $lastActivity = Get-Date
            }
            elseif ($script:ManualAction -eq 'request') {
                $script:ManualAction = $null
                if ($releasedNames.Count -gt 0) {
                    $f = Request-ShareableLicenses $releasedNames
                    $releasedNames = @($f)
                    if ($f.Count -eq 0) { Show-Balloon 'Licenses re-acquired / 再取得しました / ขอไลเซนส์คืนแล้ว' } else { Show-Balloon ("Not available / 取得できません / ไม่ว่าง: " + ($f -join ', ')) }
                }
                $lastActivity = Get-Date
            }

            if ($releasedNames.Count -gt 0) {
                # Released state: re-acquire when the user is back / 返却中: 利用者が戻ったら再取得
                Set-TrayStatus ("Released: " + ($releasedNames -join ',')) '返却中' 'คืนไลเซนส์แล้ว'
                $retryDue = ((Get-Date) - $lastRetry).TotalSeconds -ge 60
                if ([bool]$script:Config.ReacquireOnReturn -and $activeNow -and $retryDue) {
                    $lastRetry = Get-Date
                    Write-Log -Message 'User is back, re-acquiring / 利用者が戻ったため再取得'
                    $f = Request-ShareableLicenses $releasedNames
                    $releasedNames = @($f)
                    if ($f.Count -eq 0) { Show-Balloon 'Licenses re-acquired / 再取得しました / ขอไลเซนส์คืนแล้ว' }
                    else { Show-Balloon ("License not available now, retrying in 1 min / 今は取得できません。1 分後に再試行 / ไม่ว่าง ลองใหม่ใน 1 นาที: " + ($f -join ', ')) }
                }
            }
            else {
                $idle = (Get-Date) - $lastActivity
                $remain = $idleLimit - $idle
                if ($remain.TotalSeconds -gt 0) {
                    $r = '{0:mm\:ss}' -f $remain
                    Set-TrayStatus "Monitoring - release in $r" "監視中 - 返却まで $r" "กำลังตรวจสอบ - คืนในอีก $r"
                }
                else {
                    Write-Log -Message ('No CATIA activity for {0:F1} min / {0:F1} 分間 CATIA 操作なし' -f $idle.TotalMinutes)
                    $answer = 'Timeout'
                    if ([int]$script:Config.WarningSeconds -gt 0) {
                        Set-TrayStatus 'Warning shown' '警告表示中' 'กำลังแสดงคำเตือน'
                        $answer = Show-WarningDialog -Seconds ([int]$script:Config.WarningSeconds) -CatiaPids $pids
                        Write-Log -Message "Warning dialog result / 警告の結果: $answer"
                    }
                    if ($answer -eq 'Continue') { $lastActivity = Get-Date; $lastInputTick = [CatiaShareableGuard.Native]::GetLastInputTick() }
                    else {
                        Set-TrayStatus 'Releasing' '返却処理中' 'กำลังคืน'
                        $r = Release-ShareableLicenses
                        if ($r.Count -gt 0) {
                            $releasedNames = @($r)
                            $lastInputTick = [CatiaShareableGuard.Native]::GetLastInputTick()
                            Show-Balloon ("Shareable licenses released. Click CATIA to get them back.`nライセンスを返却しました。CATIA をクリックすると再取得します`nคืนไลเซนส์แล้ว คลิก CATIA เพื่อขอคืน")
                        }
                        else {
                            Show-Balloon "Nothing released. See the log.`n返却できませんでした。ログ参照`nคืนไม่ได้ กรุณาดู Log"
                            $lastActivity = Get-Date
                        }
                    }
                }
            }
        }
        catch {
            Write-Log -Level ERROR -Message "Unexpected error (continuing) / 予期しないエラー (継続): $($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]"
            $lastActivity = Get-Date
        }
        Wait-Poll -Milliseconds $pollMs
    }
}
catch { Write-Log -Level ERROR -Message "Fatal error / 致命的なエラー: $($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]" }
finally {
    if ($null -ne $script:Tray) { $script:Tray.Icon.Visible = $false; $script:Tray.Icon.Dispose() }
    if ($script:HasMutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
    Write-Log -Message 'CATIA Shareable Guard stopped / 終了しました'
}
