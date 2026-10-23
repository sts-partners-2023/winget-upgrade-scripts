# winget-upgrade-scripts

`winget` でインストール済みのアプリを、ダブルクリックだけで一括アップグレードする Windows 用スクリプトです。
`winget` が無い PC では自動で導入します。確認プロンプトには自動で同意し、実行画面を表示して進捗を確認できます。

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
   実行ウィンドウが開き、進捗を確認できます。終了後は結果を表示して待機します。
4. 画面を出したくない場合は、`.cmd` のショートカットを作り、プロパティの実行方法を「最小化」にしてください。

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
- 止めるときは実行ウィンドウを閉じるか、タスク マネージャーで終了してください。
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

## 結果の判定基準
更新前に一覧を取得し、対象のパッケージを 1 件ずつ更新します。1 件が失敗しても残りは続行します。
最後に、スコープ（user / machine）ごとの件数と、パッケージごとの結果を表示します。

```
user    : 対象 3 件 / 成功 1 / 失敗 1 / ブロック 1
    Amazon Kindle [Amazon.Kindle]: 失敗 (0x80190193)
    Anki Launcher [Anki.Anki]: ブロック: インストール方式が異なる（アンインストール後に再導入が必要）
    Google Cloud SDK [Google.CloudSDK]: 成功
```

| 表示 | 条件 |
|---|---|
| 成功 | winget の終了コードが 0 |
| ブロック | winget が仕様として更新しない（インストール方式が異なる、適用できる更新がない） |
| 失敗 | 上記以外の終了コード。UAC を拒否した場合も失敗（-1）になります |
| 更新対象なし | 更新前の一覧に対象が無かった |

失敗が 1 件でもあれば、スクリプト全体の終了コードは 1 です。ブロックは終了コードに含めません。

## ログ
デスクトップの `winget-upgrade-scripts-logs` フォルダーに、実行ごとのログが保存されます。
winget 自体の詳細ログは `winget --logs` で開けます。

## ライセンス
[MIT](LICENSE)。無保証です。
