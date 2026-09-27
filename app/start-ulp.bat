@echo off
title Ultra Low Power Mode Launcher
rem ---- auto elevate to administrator ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges, please click "Yes" in the UAC window...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0UltraLowPower.ps1"
if %errorlevel% neq 0 pause
