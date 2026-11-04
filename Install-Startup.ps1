<#
.SYNOPSIS
    EN: Creates/removes a shortcut in the Startup folder so CATIA Idle Guard starts automatically at Windows sign-in.
    JP: Windows サインイン時に CATIA Idle Guard を自動起動するショートカットをスタートアップフォルダに作成/削除する。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Startup.ps1          # Register / 登録
    powershell -ExecutionPolicy Bypass -File .\Install-Startup.ps1 -Remove  # Unregister / 解除
#>
[CmdletBinding()]
param([switch]$Remove)

$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'CATIA Idle Guard.lnk'
$bat = Join-Path $PSScriptRoot 'Start-CatiaIdleGuard.bat'

if ($Remove) {
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "Removed / 削除しました: $lnk"
    }
    else {
        Write-Host 'Not registered. / 登録されていません。'
    }
    return
}

if (-not (Test-Path -LiteralPath $bat)) { throw "Launcher not found / 起動用バッチが見つかりません: $bat" }

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = $bat
$sc.WorkingDirectory = $PSScriptRoot
$sc.WindowStyle = 7   # Minimized / 最小化
$sc.Description = 'CATIA V5 Idle Guard'
$sc.Save()
Write-Host "Registered / 登録しました: $lnk"
Write-Host 'It will start automatically from the next sign-in. To start now, run Start-CatiaIdleGuard.bat.'
Write-Host '次回サインイン時から自動起動します。今すぐ起動する場合は Start-CatiaIdleGuard.bat を実行してください。'
