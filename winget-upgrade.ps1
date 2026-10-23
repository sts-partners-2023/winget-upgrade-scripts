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
#>
param(
    [ValidateSet('User', 'All', 'Machine')]
    [string]$Mode = 'User',
    [switch]$NoPause,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$AppName = 'winget-upgrade-scripts'
$script:Mutex = $null
$script:Transcribing = $false

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

function Invoke-WingetUpgrade([string]$Winget, [string]$Scope) {
    if ($ListOnly) {
        Write-Step "[$Scope スコープ] 更新対象の一覧"
        & $Winget upgrade --include-unknown --scope $Scope --accept-source-agreements --disable-interactivity | Out-Host
    } else {
        Write-Step "[$Scope スコープ] アップグレードを開始します"
        & $Winget upgrade --all --include-unknown --scope $Scope --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
    }
    return [int]$LASTEXITCODE
}

function Format-Code([int]$Code) {
    if ($Code -eq 0) { return '成功 (0)' }
    return ('失敗 (0x{0:X8})' -f $Code)
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
$logDir = Join-Path $env:LOCALAPPDATA "$AppName\logs"
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
$results = [ordered]@{}
if ($Mode -in 'User', 'All') {
    $results['user'] = Invoke-WingetUpgrade $winget 'user'
}
if ($Mode -eq 'Machine') {
    $results['machine'] = Invoke-WingetUpgrade $winget 'machine'
}
if ($Mode -eq 'All') {
    if ($ListOnly) {
        $results['machine'] = Invoke-WingetUpgrade $winget 'machine'
    } else {
        Write-Step '[machine スコープ] 管理者権限で実行します（UAC が表示されます）'
        try {
            $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Machine -NoPause' -f $PSCommandPath
            $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Minimized -Wait -PassThru -ArgumentList $argList
            $results['machine'] = $p.ExitCode
        } catch {
            Write-Step "管理者での実行を開始できませんでした（UAC で拒否された可能性があります）: $($_.Exception.Message)"
            $results['machine'] = -1
        }
    }
}

# ---- 結果 ----
Write-Host ''
Write-Step '結果'
$worst = 0
foreach ($k in $results.Keys) {
    Write-Host ("  {0,-8}: {1}" -f $k, (Format-Code $results[$k]))
    if ($results[$k] -ne 0) { $worst = 1 }
}
if ($Mode -eq 'User') {
    Write-Host '  machine スコープは対象外です。全件を更新するには winget-upgrade-all.cmd を使ってください。'
}
Write-Host "  ログ: $logFile （winget の詳細ログは 'winget --logs' で開けます）"
Exit-Script $worst
