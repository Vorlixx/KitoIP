@echo off
REM ============================================================
REM   KitoIP  -  Launcher
REM   Single entry point. Opens the unified terminal menu
REM   (KitoMenu.ps1). There are no other .bat files.
REM ============================================================
title KitoIP  -  Proxy + IP Toolkit
setlocal
cd /d "%~dp0"

REM UTF-8 console so that Turkish characters and box drawing render.
chcp 65001 >nul 2>&1

set "PS=powershell.exe"
where %PS% >nul 2>&1
if errorlevel 1 (
    echo [ERROR] PowerShell was not found. Windows 7 or newer is required.
    pause
    exit /b 1
)

REM Clear the "Mark of the Web" zone flag that Windows adds to .ps1 files
REM downloaded from the internet. Without this, a freshly cloned repository
REM can refuse to run with an execution/security error.
%PS% -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Filter *.ps1 -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1

%PS% -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0KitoMenu.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [ERROR] The menu closed unexpectedly ^(exit code %RC%^).
    echo         See the message above for details.
    pause
)
exit /b %RC%
