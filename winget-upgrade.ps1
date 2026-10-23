<#
.SYNOPSIS
  winget でインストール済みアプリを一括アップグレードする。
.PARAMETER Mode
  User    : user スコープのみ更新する（管理者権限なし、UAC なし）
  All     : user スコープを更新した後、UAC を 1 回出して machine スコープも更新する
  Machine : 内部用。All から昇格して呼ばれる
.PARAMETER NoPause
  最後に一時停止しない（タスク スケジューラ用）
.PARAMETER ListOnly
  更新せず、対象の一覧だけを表示する
.PARAMETER ResultFile
  内部用。Machine が結果を親へ渡す JSON のパス
#>
param(
    [ValidateSet('User', 'All', 'Machine')]
    [string]$Mode = 'User',
    [switch]$NoPause,
    [switch]$ListOnly,
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
$AppName = 'winget-upgrade-scripts'
$script:Mutex = $null
$script:Transcribing = $false
# winget が「仕様として更新しない」ことを示す終了コード
$BlockedCodes = @{
    -1978335189 = '適用できる更新がない'                                       # 0x8A15002B
    -1978335090 = 'インストール方式が異なる（アンインストール後に再導入が必要）' # 0x8A15008E
}

# winget は UTF-8 で出力するため、パイプ経由でも日本語が文字化けしないようにする
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Write-Step([string]$Message) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" }

function Exit-Script([int]$Code) {
    if ($script:Transcribing) { try { Stop-Transcript | Out-Null } catch {} }
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch {}; $script:Mutex.Dispose() }
    if (-not $NoPause) { Read-Host 'Enter キーで閉じます' | Out-Null }
    exit $Code
}

function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Install-Winget {
    Write-Step 'winget が見つかりません。導入を試みます（1/2: 登録）'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    } catch { Write-Step "登録に失敗しました: $($_.Exception.Message)" }
    $w = Get-WingetPath
    if ($w) { return $w }

    Write-Step 'winget の導入を試みます（2/2: Microsoft.WinGet.Client 経由）'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope CurrentUser | Out-Null
        Import-Module Microsoft.WinGet.Client
        Repair-WinGetPackageManager
    } catch { Write-Step "導入に失敗しました: $($_.Exception.Message)" }
    return Get-WingetPath
}

# 一覧の表から (Id, Name) を取り出す。列位置は全角文字でずれるため、行末の 4 列（ID・現在・利用可能・ソース）から逆算する
function Get-UpgradeTargets([string]$List) {
    $lines = $List -split "`r?`n"
    $sep = 0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^-{5,}\s*$' } | Select-Object -First 1
    if ($null -eq $sep) { return @() }
    $targets = foreach ($line in $lines[($sep + 1)..($lines.Count - 1)]) {
        $tok = @($line.Trim() -split '\s+')
        if ($tok.Count -lt 5) { break }
        $v = $tok.Count - 3                                  # 現在のバージョン
        if ($tok[$v - 1] -match '^[<>~]+$') { $v-- }         # "< 1.2" のような記号付き
        if ($v -lt 2) { break }
        [pscustomobject]@{ Id = $tok[$v - 1]; Name = ($tok[0..($v - 2)] -join ' ') }
    }
    return @($targets | Group-Object Id | ForEach-Object { $_.Group[0] })
}

# 0: 成功 / Blocked: winget が仕様として更新しない / Failed: それ以外
function Get-Category([int]$Code) {
    if ($Code -eq 0) { return 'Success' }
    if ($Code -in $BlockedCodes.Keys) { return 'Blocked' }
    return 'Failed'
}

function Format-Code([int]$Code) {
    if ($Code -eq 0) { return '成功' }
    if ($BlockedCodes.Contains($Code)) { return "ブロック: $($BlockedCodes[$Code])" }
    return ('失敗 (0x{0:X8})' -f $Code)
}

function New-Result([string]$Scope, [string]$Id, [string]$Name, [int]$Code) {
    [pscustomobject]@{ Scope = $Scope; Id = $Id; Name = $Name; Code = $Code }
}

# パッケージごとに更新し、1 件の失敗で残りを止めない。戻り値は結果の配列
function Invoke-WingetUpgrade([string]$Winget, [string]$Scope) {
    Write-Step "[$Scope スコープ] 更新対象の一覧"
    $list = (& $Winget upgrade --include-unknown --scope $Scope --accept-source-agreements --disable-interactivity | Out-String)
    $listCode = [int]$LASTEXITCODE
    Write-Host $list
    if ($ListOnly) { return @(New-Result $Scope $null '一覧のみ' $listCode) }
    if ($listCode -ne 0) { return @(New-Result $Scope $null '一覧の取得' $listCode) }

    $targets = @(Get-UpgradeTargets $list)
    if ($targets.Count -eq 0) {
        Write-Step "[$Scope スコープ] 更新対象はありません"
        return @(New-Result $Scope $null '更新対象なし' 0)
    }

    $items = @()
    $n = 0
    foreach ($t in $targets) {
        $n++
        Write-Step "[$Scope スコープ] ($n/$($targets.Count)) $($t.Name) [$($t.Id)] を更新します"
        & $Winget upgrade --id $t.Id --exact --include-unknown --scope $Scope --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
        $items += New-Result $Scope $t.Id $t.Name ([int]$LASTEXITCODE)
    }
    return $items
}

# ---- 権限の確認 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Mode -ne 'Machine' -and $isAdmin) {
    Write-Host '管理者として実行しないでください。通常のユーザー権限で起動してください。'
    Exit-Script 1
}
if ($Mode -eq 'Machine' -and -not $isAdmin) {
    Write-Host '-Mode Machine は管理者権限が必要です。'
    Exit-Script 1
}

# ---- 2 重起動の防止（Machine は親が保持しているので取得しない） ----
if ($Mode -ne 'Machine') {
    $script:Mutex = New-Object System.Threading.Mutex($false, "Local\$AppName")
    if (-not $script:Mutex.WaitOne(0)) {
        $script:Mutex.Dispose(); $script:Mutex = $null
        Write-Host '既に実行中です。'
        Exit-Script 1
    }
}

# ---- ログ ----
$logDir = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName-logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Mode)
Start-Transcript -Path $logFile | Out-Null
$script:Transcribing = $true
Write-Step "モード: $Mode / ログ: $logFile"

# ---- OS の確認 ----
if ([Environment]::OSVersion.Version.Build -lt 17763) {
    Write-Host 'winget は Windows 10 1809 (ビルド 17763) 以降が必要です。'
    Exit-Script 1
}

# ---- winget の検出と導入 ----
$winget = Get-WingetPath
if (-not $winget) {
    if ($Mode -eq 'Machine') {
        Write-Host 'winget が見つかりません。'
        Exit-Script 1
    }
    $winget = Install-Winget
}
if (-not $winget) {
    Write-Host 'winget を導入できませんでした。Microsoft Store の「アプリ インストーラー」を導入してください:'
    Write-Host 'https://apps.microsoft.com/detail/9nblggh4nns1'
    Exit-Script 1
}
Write-Step "winget: $winget ($(& $winget --version))"

# ---- アップグレード ----
$items = @()
if ($Mode -in 'User', 'All') {
    $items += Invoke-WingetUpgrade $winget 'user'
}
if ($Mode -eq 'Machine') {
    $items += Invoke-WingetUpgrade $winget 'machine'
}
if ($Mode -eq 'All') {
    if ($ListOnly) {
        $items += Invoke-WingetUpgrade $winget 'machine'
    } else {
        Write-Step '[machine スコープ] 管理者権限で実行します（UAC が表示されます）'
        $childResult = Join-Path $env:TEMP ("{0}-machine-{1}.json" -f $AppName, $PID)
        Remove-Item $childResult -ErrorAction SilentlyContinue
        try {
            $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Machine -NoPause -ResultFile "{1}"' -f $PSCommandPath, $childResult
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList $argList
            if (Test-Path $childResult) {
                $items += @(Get-Content $childResult -Raw -Encoding UTF8 | ConvertFrom-Json)
            } else {
                $items += New-Result 'machine' $null '管理者側の実行' ([int]$p.ExitCode)
            }
        } catch {
            Write-Step "管理者での実行を開始できませんでした（UAC で拒否された可能性があります）: $($_.Exception.Message)"
            $items += New-Result 'machine' $null '管理者側の実行' -1
        } finally {
            Remove-Item $childResult -ErrorAction SilentlyContinue
        }
    }
}

# Machine は結果を親へ渡す
if ($Mode -eq 'Machine' -and $ResultFile) {
    ConvertTo-Json -InputObject @($items) | Set-Content -Path $ResultFile -Encoding UTF8
}

# ---- 結果 ----
Write-Host ''
Write-Step '結果'
$failed = 0
foreach ($scope in 'user', 'machine') {
    $s = @($items | Where-Object { $_.Scope -eq $scope })
    if ($s.Count -eq 0) { continue }
    $pkgs = @($s | Where-Object { $_.Id })
    if ($pkgs.Count -eq 0) {
        # パッケージ単位ではない結果（更新なし・一覧のみ・取得失敗など）
        $r = $s[0]
        $text = if ($r.Code -eq 0) { $r.Name } else { '{0}: {1}' -f $r.Name, (Format-Code $r.Code) }
        if ($r.Code -ne 0) { $failed++ }
        Write-Host ("  {0,-8}: {1}" -f $scope, $text)
        continue
    }
    $ok = @($pkgs | Where-Object { (Get-Category $_.Code) -eq 'Success' }).Count
    $blocked = @($pkgs | Where-Object { (Get-Category $_.Code) -eq 'Blocked' }).Count
    $ng = @($pkgs | Where-Object { (Get-Category $_.Code) -eq 'Failed' }).Count
    $failed += $ng
    Write-Host ("  {0,-8}: 対象 {1} 件 / 成功 {2} / 失敗 {3} / ブロック {4}" -f $scope, $pkgs.Count, $ok, $ng, $blocked)
    foreach ($i in $pkgs) {
        Write-Host ("      {0} [{1}]: {2}" -f $i.Name, $i.Id, (Format-Code $i.Code))
    }
}
if ($Mode -eq 'User') {
    Write-Host '  machine スコープは対象外です。全件を更新するには winget-upgrade-all.cmd を使ってください。'
}
Write-Host "  ログ: $logFile （winget の詳細ログは 'winget --logs' で開けます）"
# ブロック（winget が仕様として更新しないもの）は終了コードには含めない
Exit-Script ([int]($failed -gt 0))
