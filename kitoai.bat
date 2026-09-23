@echo off
REM KitoAi - one-click launcher (Windows)
REM Starts the web dashboard backend and opens the browser.
cd /d "%~dp0"
echo Starting KitoAi dashboard...
start "" cmd /c "python run.py --web"
timeout /t 3 /nobreak >nul
start "" http://127.0.0.1:8666
echo KitoAi is running at http://127.0.0.1:8666
echo Close this window to keep the dashboard running in its own window.
