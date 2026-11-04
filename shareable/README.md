# CATIA Shareable Guard

**EN:** A second tool with a different approach. After a period of inactivity it releases only the **shareable product** licenses. CATIA stays open. The commands of the released products are greyed out until the licenses are re-acquired, which happens automatically when the user comes back to CATIA.

**JP:** 別のアプローチのツールです。無操作が続いたとき、**シェアラブル製品**のライセンスだけを返却します。CATIA は終了しません。返却した製品のコマンドは、再取得するまでグレーアウトします。利用者が CATIA に戻ると自動で再取得します。

---

## How it differs from CATIA Idle Guard / Idle Guard との違い

| | CATIA Idle Guard | CATIA Shareable Guard |
|---|---|---|
| **EN:** What is released / **JP:** 返却するもの | All licenses (CATIA exits) / 全ライセンス (CATIA を終了) | Shareable products only / シェアラブル製品のみ |
| **EN:** CATIA stays open / **JP:** CATIA は開いたまま | No / いいえ | Yes / はい |
| **EN:** Base configuration license / **JP:** 基本構成のライセンス | Released / 返却 | **Not released** (impossible without exiting) / **返却されない** (終了しないと返せない) |
| **EN:** Unsaved documents / **JP:** 未保存の文書 | Backed up / バックアップ | Untouched / そのまま |
| **EN:** Coming back / **JP:** 戻ってきたとき | Start CATIA again / CATIA を再起動 | Licenses re-acquired automatically / 自動で再取得 |

---

## How it works / 仕組み

1. **EN:** Input while a CATIA window is in the foreground counts as activity (same as Idle Guard).
   **JP:** CATIA のウィンドウが前面にあるときの入力を操作とみなします (Idle Guard と同じ)。
2. **EN:** After `IdleMinutes` (default 15) a warning with a countdown (`WarningSeconds`, default 30) is shown.
   **JP:** `IdleMinutes` (既定 15 分) 経つと、カウントダウン付きの警告 (`WarningSeconds`、既定 30 秒) を出します。
3. **EN:** The shareable licenses are released through CATIA's automation interface: `SettingControllers.Item("CATSysDynLicenseSettingCtrl")`, `SetLicense(name, "NotRequested")`, then `Commit` / `SaveRepository`. This is the same setting as Tools > Options > General > Licensing > **Shareable Products**.
   **JP:** CATIA の自動化インターフェースでシェアラブル製品を返却します: `SettingControllers.Item("CATSysDynLicenseSettingCtrl")` の `SetLicense(名前, "NotRequested")`、続けて `Commit` / `SaveRepository`。ツール > オプション > 一般 > ライセンス > **シェアラブル製品** と同じ設定です。
4. **EN:** When the user clicks or types in CATIA again, the same licenses are requested again (`SetLicense(name, "Requested")`). If a license is taken by someone else, the tool retries every minute and shows a notification.
   **JP:** 利用者が CATIA を再び操作すると、同じライセンスを再要求します (`SetLicense(名前, "Requested")`)。他の人に取られていれば、1 分ごとに再試行し、通知を出します。
5. **EN:** Tray menu: release now, re-acquire now, open log folder, exit.
   **JP:** トレイメニュー: 今すぐ返却、再取得、ログフォルダを開く、終了。

---

## IMPORTANT: verify the interface first / 重要: まずインターフェースの動作確認

**EN:** Reports on the web disagree on whether `SetLicense` on the shareable-product controller takes effect immediately in a running session. Run the diagnostic launchers in this order, with CATIA running and a shareable product checked in Tools > Options:

**JP:** シェアラブル製品のコントローラに対する `SetLicense` が、実行中のセッションで即時に効くかどうかは、ネット上の報告が分かれています。CATIA を起動し、ツール > オプション でシェアラブル製品にチェックを入れた状態で、次の順に診断用 bat を実行してください:

1. `Diag-ListLicenses.bat` — **EN:** lists the shareable licenses and their states. Note the identifiers (e.g. `ST1.prd`). / **JP:** シェアラブル製品の一覧と状態を表示します。識別子 (例 `ST1.prd`) を控えてください。
2. `Diag-ReleaseNow.bat` — **EN:** releases them once. Then check: are the commands greyed out? Is the box unchecked in Tools > Options > Licensing > Shareable Products? Is the license free on the license server? / **JP:** 1 回返却します。その後、コマンドがグレーアウトしたか、ツール > オプション のチェックが外れたか、ライセンスサーバで空いたかを確認してください。
3. **EN:** Put the identifiers into `"Licenses"` in `config.json` (e.g. `["ST1.prd"]`), then run `Diag-RequestNow.bat` and check that the commands come back.
   **JP:** `config.json` の `"Licenses"` に識別子を入れ (例 `["ST1.prd"]`)、`Diag-RequestNow.bat` を実行して、コマンドが戻るか確認してください。

**EN:** Send the log (`logs\CatiaShareableGuard_yyyyMMdd.log`) after each step. If `SetLicense` does not take effect, the fallback is to drive the Tools > Options dialog itself (UI automation), which is a different implementation.
**JP:** 各ステップの後にログ (`logs\CatiaShareableGuard_yyyyMMdd.log`) を送ってください。`SetLicense` が効かない場合は、ツール > オプション のダイアログを直接操作する方式 (UI オートメーション) に切り替えます。別の実装になります。

---

## Files / ファイル

| File | EN | JP |
|---|---|---|
| `CatiaShareableGuard.ps1` | Main script | 本体 |
| `config.json` | Settings | 設定 |
| `Start-CatiaShareableGuard.bat` | Normal start (tray) | 通常起動 |
| `Test-CatiaShareableGuard.bat` | Test start (1 min idle, 20 s warning) | 動作確認用 (1 分 / 20 秒) |
| `Diag-ListLicenses.bat` | Diagnostic step 1 | 診断 1: 一覧 |
| `Diag-ReleaseNow.bat` | Diagnostic step 2 | 診断 2: 返却 |
| `Diag-RequestNow.bat` | Diagnostic step 3 | 診断 3: 要求 |

## Settings (`config.json`) / 設定

| Key | Default | EN | JP |
|---|---|---|---|
| `IdleMinutes` | `15` | Minutes without CATIA activity before release | 返却までの無操作時間 (分) |
| `WarningSeconds` | `30` | Countdown before release, `0` = none | 返却前のカウントダウン秒数、`0` で警告なし |
| `Licenses` | `[]` | Shareable products to manage. Empty = all currently granted | 対象のシェアラブル製品。空 = 現在取得中のすべて |
| `ReacquireOnReturn` | `true` | Re-acquire when the user returns | 戻ってきたら自動で再取得 |
| `ControllerName` | `CATSysDynLicenseSettingCtrl` | CATIA settings controller | CATIA の設定コントローラ名 |
| `ReleaseValue` | `NotRequested` | `SetLicense` value to release | 返却時の値 |
| `RequestValue` | `Requested` | `SetLicense` value to request. If it fails, the license name itself is tried | 要求時の値。失敗時はライセンス名そのものでも試す |

**EN:** Not included yet (available in Idle Guard, can be added): exit password, settings protection, auto-start at sign-in.
**JP:** 未実装 (Idle Guard にはあり、追加可能): 終了パスワード、設定の保護、サインイン時の自動起動。
