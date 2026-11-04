#Requires -Version 5.1
<#
.SYNOPSIS
    EN: Administrator install of CATIA Idle Guard for all users.
    JP: 管理者による CATIA Idle Guard の全ユーザー向けインストール。

.DESCRIPTION
    EN:
    - Copies the tool to C:\Program Files\CatiaIdleGuard. Normal users can read but cannot change it,
      so config.json (time limits, password hash) cannot be edited without administrator rights.
    - Registers auto-start for every user in HKLM\...\Run. Turning it off in Task Manager also needs
      administrator rights.
    - Logs go to %LOCALAPPDATA%\CatiaIdleGuard\logs of each user (Program Files is read-only for users).
    - Per-user copies (for example in Downloads) detect this install and step aside.
    JP:
    - ツールを C:\Program Files\CatiaIdleGuard にコピーする。一般ユーザーは読めるが変更できないため、
      config.json (時間設定・パスワードのハッシュ) は管理者権限なしに編集できない。
    - 全ユーザーの自動起動を HKLM\...\Run に登録する。タスクマネージャーで無効にするにも管理者権限が必要。
    - ログは各ユーザーの %LOCALAPPDATA%\CatiaIdleGuard\logs に出力する (Program Files はユーザーが書き込めないため)。
    - ユーザー単位のコピー (ダウンロードフォルダなど) は、このインストールを検出して自ら終了する。

.EXAMPLE
    # Run in PowerShell "as administrator" / PowerShell を「管理者として実行」して実行
    powershell -ExecutionPolicy Bypass -File .\Install-AllUsers.ps1           # install / インストール
    powershell -ExecutionPolicy Bypass -File .\Install-AllUsers.ps1 -Remove   # uninstall / アンインストール
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'CatiaIdleGuard')
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as administrator. / PowerShell を「管理者として実行」で開いてから実行してください。'
}

$runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runName = 'CATIA Idle Guard'

if ($Remove) {
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    Write-Host 'Uninstalled. Running copies stop at the next sign-out. / アンインストールしました。動作中のツールは次回サインアウトで止まります。'
    return
}

# Source folder (where this script is) / コピー元 (このスクリプトのフォルダ)
$src = $PSScriptRoot
if (-not $src) { try { $src = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $src = (Get-Location).Path } }

$files = @('CatiaIdleGuard.ps1', 'config.json', 'README.md')
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $f))) { throw "File not found / ファイルが見つかりません: $f" }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
foreach ($f in $files) {
    Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $InstallDir $f) -Force
}
Get-ChildItem -LiteralPath $InstallDir -File | Unblock-File   # remove "downloaded from the internet" mark / ダウンロードの印を外す

# Installed config: managed mode, per-user logs, no per-user auto-start / 管理モード・ログはユーザーごと・ユーザー単位の自動起動なし
$cfgPath = Join-Path $InstallDir 'config.json'
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg | Add-Member -NotePropertyName ManagedInstall -NotePropertyValue $true -Force
$cfg | Add-Member -NotePropertyName AutoStartup -NotePropertyValue $false -Force
$cfg | Add-Member -NotePropertyName LogFolder -NotePropertyValue '%LOCALAPPDATA%\CatiaIdleGuard\logs' -Force
$cfg | ConvertTo-Json | Set-Content -LiteralPath $cfgPath -Encoding UTF8

# Launcher shown as "CATIA Idle Guard.bat" in Task Manager / タスクマネージャーに「CATIA Idle Guard.bat」と表示される起動用 bat
$launcher = Join-Path $InstallDir 'CATIA Idle Guard.bat'
@(
    '@echo off'
    'rem CATIA Idle Guard (all-users install). Started at sign-in from HKLM Run.'
    'start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0CatiaIdleGuard.ps1" -ConfigPath "%~dp0config.json"'
) | Set-Content -LiteralPath $launcher -Encoding ASCII

Set-ItemProperty -Path $runKey -Name $runName -Value ('"{0}"' -f $launcher)

Write-Host "Installed / インストールしました: $InstallDir"
Write-Host 'It starts for every user at the next sign-in. / 次回サインインから全ユーザーで自動起動します。'
Write-Host 'Do not start it from this administrator window (CATIA must run at the same privilege level). / この管理者ウィンドウからは起動しないでください (CATIA と権限レベルを合わせるため)。'
