<#
.SYNOPSIS
    Windows サインイン時に CATIA Idle Guard を自動起動するショートカットをスタートアップフォルダに作成/削除する。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Startup.ps1          # 登録
    powershell -ExecutionPolicy Bypass -File .\Install-Startup.ps1 -Remove  # 解除
#>
[CmdletBinding()]
param([switch]$Remove)

$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'CATIA Idle Guard.lnk'
$bat = Join-Path $PSScriptRoot 'Start-CatiaIdleGuard.bat'

if ($Remove) {
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "削除しました: $lnk"
    }
    else {
        Write-Host '登録されていません。'
    }
    return
}

if (-not (Test-Path -LiteralPath $bat)) { throw "起動用バッチが見つかりません: $bat" }

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath = $bat
$sc.WorkingDirectory = $PSScriptRoot
$sc.WindowStyle = 7   # 最小化
$sc.Description = 'CATIA V5 Idle Guard'
$sc.Save()
Write-Host "登録しました: $lnk"
Write-Host '次回サインイン時から自動起動します。今すぐ起動する場合は Start-CatiaIdleGuard.bat を実行してください。'
