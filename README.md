# CATIA Idle Guard

CATIA V5 を一定時間 (既定 15 分) 操作しなかった場合に、未保存文書をバックアップ保存してから CATIA を終了し、ライセンスをサーバへ返却する常駐ツールです。Windows 標準の PowerShell 5.1 だけで動作し、追加インストールは不要です。

## 動作の流れ

1. タスクトレイに常駐し、CATIA V5 本体 (`CNEXT.exe`) の起動を監視します。
2. **CATIA のウィンドウが前面にある状態でのキーボード/マウス入力** だけを「CATIA 操作」として扱います。Excel や Outlook を操作していても CATIA の無操作時間は進みます。
3. 無操作が 15 分続くと警告ダイアログを表示します (60 秒カウントダウン)。
   - 「作業を続行する」を押す、または CATIA ウィンドウを操作すると監視をリセットします。
   - 「今すぐ保存して終了」を押す、または無応答でカウントダウンが終わると終了処理に進みます。
4. 終了処理
   1. COM (`CATIA.Application`) で開いている全文書を列挙します。
   2. 未保存の文書を `BackupFolder\yyyyMMdd_HHmmss\` へ「名前を付けて保存」します。**元ファイルは上書きしません。**
   3. `CATIA.Application.Quit()` で CATIA を終了します。終了時にライセンスが返却されます。
   4. 90 秒以内に終了しない場合は強制終了します (設定で無効化可)。
5. 結果をタスクトレイのバルーン通知とログに記録します。

### 安全側の設計 (データ保護優先)

- COM 接続に失敗した場合や文書の列挙に失敗した場合は **CATIA を終了しません** (`QuitWithoutComAccess=false`)。未保存文書の状態が確認できない状態で終了すると作業内容が失われるためです。
- 1 件でもバックアップ保存に失敗した場合も終了を見送り、次回の無操作判定で再試行します。
- 未保存文書が 1 件も無い場合は、そのまま終了します。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `CatiaIdleGuard.ps1` | 本体 (常駐スクリプト) |
| `config.json` | 設定ファイル |
| `Start-CatiaIdleGuard.bat` | 通常起動用 (コンソール非表示・トレイ常駐) |
| `Test-CatiaIdleGuard.bat` | 動作確認用 (無操作 1 分・警告 20 秒・コンソール表示) |
| `Install-Startup.ps1` | Windows サインイン時の自動起動を登録/解除 |
| `logs\` | 動作ログ (日付別、30 日で自動削除) |

## セットアップ

1. このフォルダ一式を会社 PC の任意の場所 (例: `C:\Tools\CatiaIdleGuard`) に置きます。
2. `config.json` を必要に応じて編集します。
3. `Start-CatiaIdleGuard.bat` をダブルクリックで起動します。タスクトレイに盾アイコンが出れば常駐中です。
4. サインイン時に自動起動させる場合は、PowerShell で次を実行します。

```bat
powershell -ExecutionPolicy Bypass -File "C:\Tools\CatiaIdleGuard\Install-Startup.ps1"
```

解除は `-Remove` を付けて実行します。

### 注意事項

- **管理者権限で実行しないでください。** CATIA と権限レベルが異なると COM 接続に失敗し、終了処理が見送られます。
- Windows PowerShell 5.1 (`powershell.exe`) 用です。PowerShell 7 (`pwsh.exe`) では `GetActiveObject` が使えないため動作しません。
- 会社のグループポリシーで実行ポリシーが `AllSigned` に固定されている場合は `-ExecutionPolicy Bypass` が効きません。その場合は情シスに署名または許可を依頼してください。
- `.ps1` ファイルは **UTF-8 (BOM 付き)** で保存されています。他のエディタで保存し直すときは BOM を維持してください (BOM が無いと日本語が文字化けします)。

## 設定 (`config.json`)

| キー | 既定値 | 説明 |
|---|---|---|
| `IdleMinutes` | `15` | この分数 CATIA 操作が無ければ警告を出す |
| `WarningSeconds` | `60` | 警告ダイアログのカウントダウン秒数 |
| `PollSeconds` | `1` | 入力監視の周期 (秒) |
| `ProcessName` | `"CNEXT"` | CATIA V5 本体のプロセス名 (拡張子なし) |
| `BackupFolder` | `"%USERPROFILE%\\Documents\\CATIA_AutoBackup"` | 未保存文書の保存先。環境変数を使用可 |
| `ForceKillAfterSeconds` | `90` | `Quit()` 後この秒数で終了しなければ強制終了。`0` で強制終了しない |
| `QuitWithoutComAccess` | `false` | COM 接続できない場合でも終了するか。`true` は未保存文書が失われる可能性あり |
| `LogFolder` | `"logs"` | ログ出力先 (相対パスはスクリプトのフォルダ基準) |
| `LogRetentionDays` | `30` | ログの保持日数 |

## 動作確認手順

1. CATIA V5 を起動し、新規 Part を作ってスケッチなどを描き、**保存しない** 状態にします。
2. `Test-CatiaIdleGuard.bat` を実行します (無操作 1 分 / 警告 20 秒)。
3. CATIA 以外のウィンドウ (メモ帳など) を 1 分間操作し続け、CATIA には触れないでください。
4. 警告ダイアログが出たら、そのまま 20 秒待ちます。
5. 確認ポイント
   - `Documents\CATIA_AutoBackup\yyyyMMdd_HHmmss\` に Part が保存され、`_README.txt` がある
   - CATIA が終了している
   - ライセンスサーバ (DSLS の管理画面など) で該当ライセンスが返却されている
   - `logs\CatiaIdleGuard_yyyyMMdd.log` に一連の記録がある
6. 再度実行し、警告ダイアログ中に CATIA ウィンドウをクリックすると、ダイアログが閉じて監視が続行されることを確認します。

## 既知の制限

- 「操作」はキーボード/マウス入力で判定するため、更新 (Update) や計算など **入力の無い長時間処理の最中も無操作として扱われます**。長い処理を走らせる場合は `IdleMinutes` を長めにするか、トレイメニューから一時的に Idle Guard を終了してください。
- 画面ロックやスリープ中も無操作時間は進みます (離席時にライセンスを返す、という目的どおりの動作です)。
- 未保存文書のバックアップは「名前を付けて保存」のため、Product と Part を同時にバックアップした場合、バックアップ側の Product はバックアップ側の Part を参照します。元の Product ファイルは変更されません。
- CATIA 側にモーダルダイアログ (エラー表示など) が開いたままだと COM 呼び出しが応答しないことがあります。その場合は終了処理を見送り、次回に再試行します。
- 複数の CATIA セッションを同時に起動している場合、COM 接続先は最初に登録されたセッションになります。
