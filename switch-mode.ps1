#Requires -Version 5.1
<#
.SYNOPSIS
  Switch CodexModelRouter between "router" mode (DeepSeek + ChatGPT) and "native" mode (official ChatGPT only).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File switch-mode.ps1 -Mode status
  powershell -ExecutionPolicy Bypass -File switch-mode.ps1 -Mode native
  powershell -ExecutionPolicy Bypass -File switch-mode.ps1 -Mode router
#>
param(
  [ValidateSet("router", "native", "status")]
  [string]$Mode = "status",
  [string]$ConfigPath = (Join-Path $env:USERPROFILE ".codex\config.toml"),
  [string]$TaskName = "CodexModelRouter",
  [int]$TlsPort = 8789,
  [switch]$NoTaskAction
)

$ErrorActionPreference = "Stop"
$RouterUrl = "https://127.0.0.1:$TlsPort/backend-api"
$script:ConfigBackup = $null

function Get-CodexHome {
  if ($env:CODEX_HOME) { return $env:CODEX_HOME }
  return (Join-Path $env:USERPROFILE ".codex")
}

function Read-ConfigLines {
  if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config.toml not found: $ConfigPath" }
  return ,([System.IO.File]::ReadAllLines($ConfigPath))
}

function Save-ConfigLines([string[]]$lines) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
  $script:ConfigBackup = "$ConfigPath.bak-$stamp"
  Copy-Item -LiteralPath $ConfigPath -Destination $script:ConfigBackup -Force
  $tmp = "$ConfigPath.tmp-$stamp"
  [System.IO.File]::WriteAllLines($tmp, $lines, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
}

function Set-KeyLine([string[]]$lines, [string]$key, [string]$value) {
  $pattern = "^\s*$([regex]::Escape($key))\s*="
  $done = $false
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($line -match $pattern) {
      if (-not $done) { $out.Add("$key = $value"); $done = $true }
      else { $out.Add("# " + $line) }
    } else {
      $out.Add($line)
    }
  }
  if (-not $done) {
    $insertAt = 0
    for ($i = 0; $i -lt $out.Count; $i++) {
      if ($out[$i] -match "^\s*model_provider\s*=") { $insertAt = $i + 1; break }
      if ($out[$i] -match "^\s*model\s*=") { $insertAt = $i + 1 }
    }
    $out.Insert($insertAt, "$key = $value")
  }
  return ,$out.ToArray()
}

function Remove-KeyLine([string[]]$lines, [string]$key) {
  $pattern = "^\s*$([regex]::Escape($key))\s*="
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($line -match $pattern) { $out.Add("# (native mode) " + $line.Trim()) }
    else { $out.Add($line) }
  }
  return ,$out.ToArray()
}

function Get-Mode([string[]]$lines) {
  $line = $lines | Where-Object { $_ -match "^\s*chatgpt_base_url\s*=" } | Select-Object -First 1
  if (-not $line) { return "native" }
  if ($line -match "127\.0\.0\.1:$TlsPort") { return "router" }
  return "custom"
}

function Get-AccountInfo {
  $authPath = Join-Path (Get-CodexHome) "auth.json"
  if (-not (Test-Path -LiteralPath $authPath)) { return "auth.json not found" }
  try {
    $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    $token = $auth.tokens.id_token
    if (-not $token) { return "auth_mode=$($auth.auth_mode); no id_token" }
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    while ($payload.Length % 4) { $payload += '=' }
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $claim = $json.'https://api.openai.com/auth'
    $plan = if ($claim) { $claim.chatgpt_plan_type } else { $null }
    $workspace = if ($claim) { $claim.chatgpt_account_id } else { $null }
    return "email=$($json.email)  plan=$plan  workspace/account=$($auth.tokens.account_id)"
  } catch {
    return "could not parse auth.json: $($_.Exception.Message)"
  }
}

function Show-Status {
  $lines = Read-ConfigLines
  $mode = Get-Mode $lines
  Write-Host "== CodexModelRouter status ==" -ForegroundColor Cyan
  Write-Host ("mode              : {0}" -f $mode)
  Write-Host ("config            : {0}" -f $ConfigPath)
  foreach ($k in @("model", "model_provider", "chatgpt_base_url")) {
    $v = $lines | Where-Object { $_ -match "^\s*$([regex]::Escape($k))\s*=" } | Select-Object -First 1
    Write-Host ("{0,-18}: {1}" -f $k, $(if ($v) { $v.Trim() } else { "(not set)" }))
  }
  $target = (Get-Process CodexModelRouter -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1)
  if ($target) {
    $listening = (netstat -ano | Select-String -Pattern ":$TlsPort\s+.*LISTENING") -ne $null
    Write-Host ("router process    : pid {0}, https :{1} listening = {2}" -f $target.Id, $TlsPort, $listening)
  } else {
    Write-Host "router process    : not running"
  }
  $task = schtasks /query /tn $TaskName /fo LIST 2>$null
  $taskStatus = if ($task) { ($task | Select-String "Status:" | Select-Object -First 1) } else { "not registered" }
  Write-Host ("scheduled task    : {0}" -f $(if ($taskStatus) { "$taskStatus".Trim() } else { "not registered" }))
  Write-Host ("account           : {0}" -f (Get-AccountInfo))
}

switch ($Mode) {
  "status" { Show-Status; break }
  "router" {
    $lines = Read-ConfigLines
    $lines = Set-KeyLine $lines "model_provider" '"openai"'
    $lines = Set-KeyLine $lines "chatgpt_base_url" ('"{0}"' -f $RouterUrl)
    Save-ConfigLines $lines
    Write-Host "config updated -> router mode (backup: $script:ConfigBackup)"
    if (-not $NoTaskAction) {
      schtasks /change /tn $TaskName /enable 2>$null | Out-Null
      schtasks /run /tn $TaskName 2>$null | Out-Null
      Start-Sleep -Seconds 4
    }
    Write-Host "router mode is active. Restart the Codex / ChatGPT desktop app to apply." -ForegroundColor Yellow
    break
  }
  "native" {
    $lines = Read-ConfigLines
    $lines = Set-KeyLine $lines "model_provider" '"openai"'
    $lines = Remove-KeyLine $lines "chatgpt_base_url"
    Save-ConfigLines $lines
    Write-Host "config updated -> native mode (backup: $script:ConfigBackup)"
    if (-not $NoTaskAction) {
      schtasks /end /tn $TaskName 2>$null | Out-Null
      schtasks /change /tn $TaskName /disable 2>$null | Out-Null
      Get-Process CodexModelRouter -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Write-Host "native mode is active: Codex talks to ChatGPT directly. Restart the Codex / ChatGPT desktop app." -ForegroundColor Yellow
    break
  }
}
