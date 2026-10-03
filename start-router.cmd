@echo off
rem Start the local Codex model router in the background (no console window).
rem Prefers the packaged executable; falls back to pythonw + router.py.
set ROUTER_EXE=%~dp0CodexModelRouter.exe
if exist "%ROUTER_EXE%" (
  start "" /b "%ROUTER_EXE%"
  goto :eof
)
rem Fall back to pythonw when the packaged exe is missing.
set PYTHONW=
for %%p in (pythonw.exe) do if not defined PYTHONW set PYTHONW=%%~$PATH:p
if not defined PYTHONW if exist "%LOCALAPPDATA%\Programs\Python\Python313\pythonw.exe" set PYTHONW=%LOCALAPPDATA%\Programs\Python\Python313\pythonw.exe
if not defined PYTHONW if exist "%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe" set PYTHONW=%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe
if not defined PYTHONW if exist "%LOCALAPPDATA%\Programs\Python\Python311\pythonw.exe" set PYTHONW=%LOCALAPPDATA%\Programs\Python\Python311\pythonw.exe
if not defined PYTHONW (
  echo pythonw.exe not found. Install Python 3.11+ or build CodexModelRouter.exe with build-exe.ps1
  pause
  exit /b 1
)
start "" /b "%PYTHONW%" "%~dp0router.py"
