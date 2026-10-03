@echo off
rem Stop the local Codex model router.
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":8788" ^| findstr LISTENING') do taskkill /F /PID %%p
