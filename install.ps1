#Requires -Version 5.1
<#
.SYNOPSIS
  一键安装 CodexModelRouter：生成本地证书 -> 信任证书 -> 打包 exe -> 注册开机自启任务 -> 启动。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install.ps1
  powershell -ExecutionPolicy Bypass -File install.ps1 -InstallDir D:\Project\CodexModelRouter
#>
param(
  [string]$InstallDir = $PSScriptRoot,
  [int]$Port = 8788,
  [int]$TlsPort = 8789,
  [string]$TaskName = "CodexModelRouter",
  [switch]$SkipBuild,
  [switch]$SkipTask
)

$ErrorActionPreference = "Stop"
$InstallDir = (Resolve-Path $InstallDir).Path
Write-Host "== CodexModelRouter install ==" -ForegroundColor Cyan
Write-Host "install dir: $InstallDir"

function Find-Python {
  # Real installs first: the Microsoft Store alias (WindowsApps\python.exe) is a
  # stub that silently does nothing.
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:ProgramFiles\Python313\python.exe",
    "$env:ProgramFiles\Python312\python.exe",
    "$env:ProgramFiles\Python311\python.exe"
  ) | Where-Object { $_ -and (Test-Path $_) }
  if (-not $candidates) {
    $found = (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($found -and $found -notlike "*\WindowsApps\*") { $candidates = @($found) }
  }
  return $candidates | Select-Object -First 1
}

$python = Find-Python

# 1) 证书
if (-not (Test-Path "$InstallDir\tls\server.crt") -or -not (Test-Path "$InstallDir\tls\ca.crt")) {
  if (-not $python) { throw "需要 Python 来生成证书；请先安装 Python 3.11+，或手动提供 tls\server.crt / server.key / ca.crt" }
  Write-Host "[1/5] generating TLS certificate ..."
  & $python "$InstallDir\make-tls-cert.py"
} else {
  Write-Host "[1/5] TLS certificate already present"
}

# 2) 信任证书（当前用户 -> 受信任的根证书颁发机构）
$caPath = "$InstallDir\tls\ca.crt"
$ca = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($caPath)
$inStore = Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Thumbprint -eq $ca.Thumbprint }
if ($inStore) {
  Write-Host "[2/5] CA already trusted ($($ca.Thumbprint))"
} else {
  Write-Host "[2/5] trusting CA in CurrentUser\Root ..."
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "CurrentUser")
  $store.Open("ReadWrite"); $store.Add($ca); $store.Close()
  Write-Host "      added: $($ca.Thumbprint)"
}

# 3) 放行清单（决定哪些接口使用浏览器风格请求头）
$allowList = "$InstallDir\browser-header-paths.txt"
if (-not (Test-Path $allowList)) {
  Write-Host "[3/5] creating default browser-header-paths.txt"
  @(
    "# 只有列在这里的请求路径会使用浏览器风格请求头，其余保持原样。",
    "# 每行一个路径前缀；文件每次请求都会重新读取，改完立即生效。",
    "/backend-api/profiles/me"
  ) | Set-Content -LiteralPath $allowList -Encoding UTF8
} else {
  Write-Host "[3/5] browser-header-paths.txt already present"
}

# 4) exe（没有就打包；失败则退回 pythonw）
$exe = "$InstallDir\CodexModelRouter.exe"
if ($SkipBuild) {
  Write-Host "[4/5] build skipped"
} elseif (Test-Path $exe) {
  Write-Host "[4/5] CodexModelRouter.exe already present"
} elseif ($python) {
  Write-Host "[4/5] building CodexModelRouter.exe ..."
  try { & "$InstallDir\build-exe.ps1" } catch { Write-Warning "build failed: $_" }
} else {
  Write-Warning "no python found; will fall back to pythonw + router.py"
}

# 5) 计划任务（登录时启动 + 每 5 分钟自检）
if ($SkipTask) {
  Write-Host "[5/5] scheduled task skipped"
} else {
  Write-Host "[5/5] registering scheduled task '$TaskName' ..."
  if (Test-Path $exe) { $command = $exe; $arguments = "" }
  else {
    $pythonw = "$(Split-Path $python -Parent)\pythonw.exe"
    $command = $pythonw; $arguments = "`"$InstallDir\router.py`""
  }
  $user = "$env:USERDOMAIN\$env:USERNAME"
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Local model router for Codex (DeepSeek + ChatGPT).</Description>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
      <Repetition><Interval>PT5M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$command</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$InstallDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
  $tmpXml = Join-Path $env:TEMP "codemodelrouter-task.xml"
  Set-Content -LiteralPath $tmpXml -Value $xml -Encoding Unicode
  schtasks /create /tn $TaskName /xml $tmpXml /f | Out-Null
  schtasks /run /tn $TaskName | Out-Null
}

Start-Sleep -Seconds 5
$listening = (Test-NetConnection -ComputerName 127.0.0.1 -Port $TlsPort -InformationLevel Quiet -WarningAction SilentlyContinue)
Write-Host ""
Write-Host "== done ==" -ForegroundColor Green
Write-Host "HTTPS listener 127.0.0.1:$TlsPort -> $(if ($listening) { 'OK' } else { 'NOT listening (check router.log)' })"
Write-Host ""
Write-Host "Now point Codex at the router by putting these lines in $env:USERPROFILE\.codex\config.toml :" -ForegroundColor Yellow
Write-Host @"
model_provider = "openai"
chatgpt_base_url = "https://127.0.0.1:$TlsPort/backend-api"
model_catalog_json = "~/.codex/models.json"

[model_providers.deepseek]
base_url = "http://127.0.0.1:$Port/"
wire_api = "responses"
experimental_bearer_token = "sk-你的-DeepSeek-Key"
"@
Write-Host ""
Write-Host "Then restart the Codex / ChatGPT desktop app."
