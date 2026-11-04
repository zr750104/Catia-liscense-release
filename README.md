# CATIA Idle Guard

**EN:** A tray-resident tool for CATIA V5. If CATIA is not used for a set time (default 15 minutes), it saves unsaved documents to a backup folder, quits CATIA, and returns the license to the server. It runs on Windows PowerShell 5.1, which is built into Windows, so nothing extra needs to be installed.

**JP:** CATIA V5 を一定時間 (既定 15 分) 操作しなかった場合に、未保存文書をバックアップ保存してから CATIA を終了し、ライセンスをサーバへ返却する常駐ツールです。Windows 標準の PowerShell 5.1 だけで動作し、追加インストールは不要です。

---

## How it works / 動作の流れ

1. **EN:** Stays in the system tray and watches for the CATIA V5 process (`CNEXT.exe`).
   **JP:** タスクトレイに常駐し、CATIA V5 本体 (`CNEXT.exe`) の起動を監視します。
2. **EN:** Only keyboard/mouse input **while a CATIA window is in the foreground** counts as CATIA activity. Using Excel or Outlook does not reset the CATIA idle time.
   **JP:** **CATIA のウィンドウが前面にある状態でのキーボード/マウス入力** だけを「CATIA 操作」として扱います。Excel や Outlook を操作していても CATIA の無操作時間は進みます。
3. **EN:** After 15 minutes without activity, a warning dialog appears with a 60-second countdown.
   **JP:** 無操作が 15 分続くと警告ダイアログを表示します (60 秒カウントダウン)。
   - **EN:** Click **"Continue working"**, or use a CATIA window, to reset the timer.
     **JP:** **「作業を続行する」** を押す、または CATIA ウィンドウを操作すると監視をリセットします。
   - **EN:** Click **"Save and quit now"**, or let the countdown end, to start the shutdown.
     **JP:** **「今すぐ保存して終了」** を押す、または無応答でカウントダウンが終わると終了処理に進みます。
4. **EN:** Shutdown steps / **JP:** 終了処理
   1. **EN:** Lists all open documents via COM (`CATIA.Application`).
      **JP:** COM (`CATIA.Application`) で開いている全文書を列挙します。
   2. **EN:** Saves unsaved documents with "Save As" to `BackupFolder\yyyyMMdd_HHmmss\`. **Original files are NOT overwritten.**
      **JP:** 未保存の文書を `BackupFolder\yyyyMMdd_HHmmss\` へ「名前を付けて保存」します。**元ファイルは上書きしません。**
   3. **EN:** Quits CATIA with `CATIA.Application.Quit()`. The license is returned when CATIA exits.
      **JP:** `CATIA.Application.Quit()` で CATIA を終了します。終了時にライセンスが返却されます。
   4. **EN:** If CATIA does not exit within 90 seconds, it is force-killed (can be disabled).
      **JP:** 90 秒以内に終了しない場合は強制終了します (設定で無効化可)。
5. **EN:** The result is shown as a tray notification and written to the log.
   **JP:** 結果をタスクトレイのバルーン通知とログに記録します。

### Safety first (data protection) / 安全側の設計 (データ保護優先)

- **EN:** If the COM connection fails, or the document list cannot be read, CATIA is **NOT** closed (`QuitWithoutComAccess=false`). Closing CATIA without knowing which documents are unsaved could lose work.
  **JP:** COM 接続に失敗した場合や文書の列挙に失敗した場合は **CATIA を終了しません** (`QuitWithoutComAccess=false`)。未保存文書の状態が確認できないまま終了すると作業内容が失われるためです。
- **EN:** If even one backup save fails, CATIA is not closed and the tool retries at the next idle check.
  **JP:** 1 件でもバックアップ保存に失敗した場合も終了を見送り、次回の無操作判定で再試行します。
- **EN:** If there are no unsaved documents, CATIA is simply closed.
  **JP:** 未保存文書が 1 件も無い場合は、そのまま終了します。

---

## Files / ファイル構成

| File / ファイル | Purpose (EN) | 役割 (JP) |
|---|---|---|
| `CatiaIdleGuard.ps1` | Main script (runs in the background) | 本体 (常駐スクリプト) |
| `config.json` | Settings | 設定ファイル |
| `Start-CatiaIdleGuard.bat` | Normal start (no console, tray icon) | 通常起動用 (コンソール非表示・トレイ常駐) |
| `Test-CatiaIdleGuard.bat` | Test start (1 min idle, 20 s warning, console visible) | 動作確認用 (無操作 1 分・警告 20 秒・コンソール表示) |
| `Install-Startup.ps1` | Register/unregister auto-start at Windows sign-in | Windows サインイン時の自動起動を登録/解除 |
| `docs/QuickGuide.html` | User guide and download page (EN / JA / TH switch) | 使い方ガイド兼ダウンロードページ (英日タイ切替) |
| `docs/CatiaIdleGuard_QuickGuide.pdf` | One-page printable guide (EN / JA / TH) | 印刷用 1 枚ガイド (英日タイ併記) |
| `tools/build_guide.py` | Embeds the tool files into the HTML guide | ツール一式を HTML ガイドに埋め込む |
| `logs\` | Daily logs, deleted after 30 days | 動作ログ (日付別、30 日で自動削除) |

---

## Setup / セットアップ

1. **EN:** Copy this whole folder to the company PC, for example `C:\Tools\CatiaIdleGuard`.
   **JP:** このフォルダ一式を会社 PC の任意の場所 (例: `C:\Tools\CatiaIdleGuard`) に置きます。
2. **EN:** Edit `config.json` if needed.
   **JP:** `config.json` を必要に応じて編集します。
3. **EN:** Double-click `Start-CatiaIdleGuard.bat`. A shield icon in the system tray means it is running.
   **JP:** `Start-CatiaIdleGuard.bat` をダブルクリックで起動します。タスクトレイに盾アイコンが出れば常駐中です。
4. **EN:** To start it automatically at sign-in, run the following in PowerShell. Add `-Remove` to unregister.
   **JP:** サインイン時に自動起動させる場合は、PowerShell で次を実行します。解除は `-Remove` を付けて実行します。

```bat
powershell -ExecutionPolicy Bypass -File "C:\Tools\CatiaIdleGuard\Install-Startup.ps1"
```

### Notes / 注意事項

- **EN:** **Do NOT run as Administrator.** If the privilege level differs from CATIA, the COM connection fails and the shutdown is skipped.
  **JP:** **管理者権限で実行しないでください。** CATIA と権限レベルが異なると COM 接続に失敗し、終了処理が見送られます。
- **EN:** This is for Windows PowerShell 5.1 (`powershell.exe`). It does not work on PowerShell 7 (`pwsh.exe`) because `GetActiveObject` is not available there.
  **JP:** Windows PowerShell 5.1 (`powershell.exe`) 用です。PowerShell 7 (`pwsh.exe`) では `GetActiveObject` が使えないため動作しません。
- **EN:** If company Group Policy forces the execution policy to `AllSigned`, `-ExecutionPolicy Bypass` has no effect. Ask IT to sign or allow the script.
  **JP:** 会社のグループポリシーで実行ポリシーが `AllSigned` に固定されている場合は `-ExecutionPolicy Bypass` が効きません。その場合は情シスに署名または許可を依頼してください。
- **EN:** The `.ps1` files are saved as **UTF-8 with BOM**. Keep the BOM when you edit them, otherwise Japanese text will be garbled.
  **JP:** `.ps1` ファイルは **UTF-8 (BOM 付き)** で保存されています。他のエディタで保存し直すときは BOM を維持してください (BOM が無いと日本語が文字化けします)。
- **EN:** On-screen text (warning dialog, tray menu, notifications, backup `_README.txt`) is in **English, Japanese and Thai**. Logs are English/Japanese. Each language in the dialog has its own font: Segoe UI (English), Meiryo UI (Japanese, Segoe UI if missing), Leelawadee UI (Thai, Tahoma if missing). On Windows without Japanese fonts, Japanese may appear as boxes, but English and Thai stay readable.
  **JP:** 画面表示 (警告ダイアログ、トレイメニュー、通知、バックアップの `_README.txt`) は **英語・日本語・タイ語** の 3 言語です。ログは英日併記です。ダイアログは言語ごとにフォントを分けています: Segoe UI (英語)、Meiryo UI (日本語、無ければ Segoe UI)、Leelawadee UI (タイ語、無ければ Tahoma)。日本語フォントの無い Windows では日本語が □ 表示になる場合がありますが、英語とタイ語は表示されます。

---

## Settings (`config.json`) / 設定

| Key / キー | Default / 既定値 | Description (EN) | 説明 (JP) |
|---|---|---|---|
| `IdleMinutes` | `15` | Show the warning after this many minutes without CATIA activity | この分数 CATIA 操作が無ければ警告を出す |
| `WarningSeconds` | `60` | Countdown of the warning dialog (seconds) | 警告ダイアログのカウントダウン秒数 |
| `PollSeconds` | `1` | Monitoring interval (seconds) | 入力監視の周期 (秒) |
| `ProcessName` | `"CNEXT"` | CATIA V5 process name, without `.exe` | CATIA V5 本体のプロセス名 (拡張子なし) |
| `BackupFolder` | `"%USERPROFILE%\\Documents\\CATIA_AutoBackup"` | Where unsaved documents are saved. Environment variables allowed | 未保存文書の保存先。環境変数を使用可 |
| `ForceKillAfterSeconds` | `90` | Force-kill if CATIA has not exited this many seconds after `Quit()`. `0` = never | `Quit()` 後この秒数で終了しなければ強制終了。`0` で強制終了しない |
| `QuitWithoutComAccess` | `false` | Quit even if COM is unavailable. `true` may lose unsaved work | COM 接続できない場合でも終了するか。`true` は未保存文書が失われる可能性あり |
| `LogFolder` | `"logs"` | Log folder. Relative paths are from the script folder | ログ出力先 (相対パスはスクリプトのフォルダ基準) |
| `LogRetentionDays` | `30` | Days to keep logs | ログの保持日数 |

---

## How to test / 動作確認手順

1. **EN:** Start CATIA V5, create a new Part, draw a sketch, and **do not save it**.
   **JP:** CATIA V5 を起動し、新規 Part を作ってスケッチなどを描き、**保存しない** 状態にします。
2. **EN:** Run `Test-CatiaIdleGuard.bat` (1 min idle / 20 s warning).
   **JP:** `Test-CatiaIdleGuard.bat` を実行します (無操作 1 分 / 警告 20 秒)。
3. **EN:** For 1 minute, use another window such as Notepad and do not touch CATIA.
   **JP:** CATIA 以外のウィンドウ (メモ帳など) を 1 分間操作し続け、CATIA には触れないでください。
4. **EN:** When the warning dialog appears, wait 20 seconds.
   **JP:** 警告ダイアログが出たら、そのまま 20 秒待ちます。
5. **EN:** Check the following / **JP:** 確認ポイント
   - **EN:** The Part and `_README.txt` are in `Documents\CATIA_AutoBackup\yyyyMMdd_HHmmss\`.
     **JP:** `Documents\CATIA_AutoBackup\yyyyMMdd_HHmmss\` に Part が保存され、`_README.txt` がある
   - **EN:** CATIA has closed.
     **JP:** CATIA が終了している
   - **EN:** The license server (for example the DSLS admin tool) shows the license as returned.
     **JP:** ライセンスサーバ (DSLS の管理画面など) で該当ライセンスが返却されている
   - **EN:** `logs\CatiaIdleGuard_yyyyMMdd.log` records the whole sequence.
     **JP:** `logs\CatiaIdleGuard_yyyyMMdd.log` に一連の記録がある
6. **EN:** Run it again. While the warning dialog is shown, click a CATIA window. The dialog should close and monitoring should continue.
   **JP:** 再度実行し、警告ダイアログ中に CATIA ウィンドウをクリックすると、ダイアログが閉じて監視が続行されることを確認します。

---

## Known limitations / 既知の制限

- **EN:** Activity is detected from keyboard/mouse input, so **long operations without input (Update, calculations) are treated as idle**. For long jobs, increase `IdleMinutes` or exit Idle Guard from the tray menu.
  **JP:** 「操作」はキーボード/マウス入力で判定するため、更新 (Update) や計算など **入力の無い長時間処理の最中も無操作として扱われます**。長い処理を走らせる場合は `IdleMinutes` を長めにするか、トレイメニューから一時的に Idle Guard を終了してください。
- **EN:** Idle time keeps counting while the screen is locked or the PC is asleep. This is intended: the license is returned when you are away.
  **JP:** 画面ロックやスリープ中も無操作時間は進みます (離席時にライセンスを返す、という目的どおりの動作です)。
- **EN:** Backups use "Save As". If a Product and its Parts are backed up together, the backup Product links to the backup Parts. The original Product file is not changed.
  **JP:** 未保存文書のバックアップは「名前を付けて保存」のため、Product と Part を同時にバックアップした場合、バックアップ側の Product はバックアップ側の Part を参照します。元の Product ファイルは変更されません。
- **EN:** If a modal dialog (such as an error message) is open in CATIA, COM calls may not respond. The shutdown is then skipped and retried later.
  **JP:** CATIA 側にモーダルダイアログ (エラー表示など) が開いたままだと COM 呼び出しが応答しないことがあります。その場合は終了処理を見送り、次回に再試行します。
- **EN:** If several CATIA sessions run at once, COM connects to the first registered session.
  **JP:** 複数の CATIA セッションを同時に起動している場合、COM 接続先は最初に登録されたセッションになります。

---

## Quick guide (PDF) / 使い方ガイド (PDF)

- **EN:** A one-page user guide in English, Japanese and Thai is in `docs/CatiaIdleGuard_QuickGuide.pdf`. The source is `docs/guide.html`.
  **JP:** 利用者向けの 1 枚ものガイド (英語・日本語・タイ語) は `docs/CatiaIdleGuard_QuickGuide.pdf` にあります。元データは `docs/guide.html` です。
- **EN:** An HTML version with a language switch (English / 日本語 / ไทย) is in `docs/QuickGuide.html`. Open it in a browser; it works offline. It always opens in English; add `#ja` or `#th` to the address to open it in Japanese or Thai.
  **JP:** 言語を切り替えられる HTML 版 (English / 日本語 / ไทย) は `docs/QuickGuide.html` です。ブラウザで開くだけで、オフラインでも使えます。開くと常に英語で表示されます。アドレスの末尾に `#ja` か `#th` を付けると、最初から日本語かタイ語で開きます。
- **EN:** `docs/QuickGuide.html` is also the **download page**: the tool files are embedded in it as `CatiaIdleGuard.zip` and as individual files. To distribute the tool, send only this one HTML file. Users click the download button and follow the steps on the page.
  **JP:** `docs/QuickGuide.html` は **ダウンロードページ** を兼ねます。ツール一式が `CatiaIdleGuard.zip` と個別ファイルとして埋め込まれているので、配布はこの HTML 1 ファイルを送るだけです。利用者はダウンロードボタンを押し、ページの手順どおりに進めます。
- **EN:** After changing any tool file, re-embed the files with the command below, then commit `docs/QuickGuide.html`.
  **JP:** ツールのファイルを変更したら、次のコマンドで埋め込みを更新し、`docs/QuickGuide.html` をコミットしてください。

```bash
python3 tools/build_guide.py
```
