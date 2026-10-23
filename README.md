# winget-upgrade-scripts

`winget` でインストール済みのアプリを、ダブルクリックだけで一括アップグレードする Windows 用スクリプトです。
`winget` が無い PC では自動で導入します。確認プロンプトには自動で同意し、実行ウィンドウは最小化されます。

## 2 つの起動ファイル

| ファイル | 対象 | UAC |
|---|---|---|
| `winget-upgrade-user.cmd` | ユーザー単位でインストールされたアプリ（`--scope user`） | 出ない |
| `winget-upgrade-all.cmd` | 上記 + PC 全体にインストールされたアプリ（`--scope machine`） | machine スコープの更新時に 1 回出る |

`all` 版は、まず user スコープを通常権限で更新し、その後に管理者権限で machine スコープを更新します。
管理者実行を嫌うアプリ（Spotify など）が失敗しないよう、権限を分けています。

## 動作要件
- Windows 10 1809 (ビルド 17763) 以降 / Windows 11
- Windows PowerShell 5.1（Windows 標準）
- `winget` が無い場合の自動導入にはインターネット接続が必要です

## 使い方
1. リポジトリを clone するか、ZIP をダウンロードして展開します。
2. ZIP の場合は、展開前に ZIP の「プロパティ → 許可する」にチェックを入れるか、展開後に次を実行してブロックを解除します。
   ```powershell
   Get-ChildItem -Recurse <展開先> | Unblock-File
   ```
3. `winget-upgrade-user.cmd` または `winget-upgrade-all.cmd` をダブルクリックします。
   ウィンドウは最小化されてタスクバーに表示されます。開くと進捗を確認でき、終了後は結果を表示して待機します。
4. 起動ウィンドウを一瞬も出したくない場合は、`.cmd` のショートカットを作り、プロパティの実行方法を「最小化」にしてください。

### 事前に対象を確認する（更新はしません）
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\winget-upgrade.ps1 -Mode All -ListOnly
```

## 自動で同意する内容
次の確認には、内容を表示せずに自動で同意します。利用前に内容を理解し、自己責任で使用してください。
- winget のソース契約（`--accept-source-agreements`）
- 各パッケージの使用許諾契約（`--accept-package-agreements`）

## 既知の制約
- インストーラーが独自に出す画面は、`--silent` を付けても表示されることがあります。
- ユーザー単位のパッケージでも、まれに UAC が出ることがあります。「いいえ」を押すとそのパッケージだけが失敗し、残りは続行されます。
- user 版では machine スコープのアプリは更新されません。
- 自動での再起動はしません。
- 最小化中はキャンセルボタンがありません。止めるときはタスクバーのウィンドウを閉じるか、タスク マネージャーで終了してください。
- 2 重起動はできません（実行中に再度起動すると「既に実行中です」と表示されます）。

## 定期実行
タスク スケジューラで、ログオン中のユーザー権限（SYSTEM は不可）で次を実行します。
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<パス>\winget-upgrade.ps1" -Mode User -NoPause
```

## 特定のアプリを更新対象から外す
```powershell
winget pin add --id <パッケージ ID>
```
固定したパッケージは `--all` でも更新されません。

## ログ
デスクトップの `winget-upgrade-scripts-logs` フォルダーに、実行ごとのログが保存されます。
winget 自体の詳細ログは `winget --logs` で開けます。

## ライセンス
[MIT](LICENSE)。無保証です。
