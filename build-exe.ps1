# Rebuild CodexModelRouter.exe from router.py.
# Run this after editing router.py, then restart the router.
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Join-Path $env:TEMP "codex-model-router-build"

# Prefer a real Python install; the Microsoft Store alias (WindowsApps\python.exe)
# is an empty stub that silently does nothing.
$python = @(
  "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
  "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
  "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
  "$env:ProgramFiles\Python313\python.exe",
  "$env:ProgramFiles\Python312\python.exe",
  "$env:ProgramFiles\Python311\python.exe",
  "C:\Python313\python.exe",
  "C:\Python312\python.exe",
  "C:\Python311\python.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $python) {
  $found = (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if ($found -and $found -notlike "*\WindowsApps\*") { $python = $found }
}
if (-not $python) { throw "python.exe not found. Install Python 3.11+ (with PyInstaller) or set `$python manually." }

Write-Host "Building from $here\router.py ..."
& $python -m PyInstaller --noconfirm --onefile --noconsole `
  --name CodexModelRouter `
  --icon "$here\CodexModelRouter.ico" `
  --distpath "$work\dist" --workpath "$work\build" --specpath "$work" `
  "$here\router.py"

$built = Join-Path $work "dist\CodexModelRouter.exe"
if (-not (Test-Path $built)) { throw "build failed: $built not found" }

Copy-Item $built "$here\CodexModelRouter.exe" -Force
Write-Host "Updated: $here\CodexModelRouter.exe"
Write-Host "Now restart the router (stop it, then run start-router.cmd or the scheduled task)."
