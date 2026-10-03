#Requires -Version 5.1
<#
.SYNOPSIS
  卸载 CodexModelRouter：停止并删除计划任务、（可选）移除受信任证书。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File uninstall.ps1
  powershell -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveCert
#>
param(
  [string]$InstallDir = $PSScriptRoot,
  [string]$TaskName = "CodexModelRouter",
  [switch]$RemoveCert
)

$ErrorActionPreference = "Continue"
Write-Host "== CodexModelRouter uninstall ==" -ForegroundColor Cyan

# 1) 计划任务
schtasks /end /tn $TaskName 2>$null | Out-Null
schtasks /delete /tn $TaskName /f 2>$null | Out-Null
Write-Host "scheduled task '$TaskName' removed (if it existed)"

# 2) 进程（只结束本目录下的实例）
Get-Process CodexModelRouter -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and $_.Path.StartsWith((Resolve-Path $InstallDir).Path, [System.StringComparison]::OrdinalIgnoreCase) } |
  ForEach-Object { Write-Host "stopping pid $($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
Get-Process pythonw -ErrorAction SilentlyContinue |
  ForEach-Object {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -and $cmd -like "*$InstallDir*router.py*") { Write-Host "stopping pythonw pid $($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
  }

# 3) 证书
if ($RemoveCert) {
  $certs = Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Subject -like "*Codex Model Router Local CA*" }
  foreach ($c in $certs) { Write-Host "removing trusted CA $($c.Thumbprint)"; Remove-Item -LiteralPath $c.PSPath -Force }
  if (-not $certs) { Write-Host "no Codex Model Router CA found in CurrentUser\Root" }
} else {
  Write-Host "kept the trusted CA (use -RemoveCert to remove it)"
}

Write-Host ""
Write-Host "Done. Files under $InstallDir were left in place." -ForegroundColor Green
Write-Host "Remember to point ~/.codex/config.toml back to your previous provider settings."
