@echo off
start "" /min conhost.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0winget-upgrade.ps1" -Mode User
