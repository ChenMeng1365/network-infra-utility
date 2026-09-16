@echo off
cd /d "%~dp0"

REM ---- Check Python ----
python --version >nul 2>&1
if errorlevel 1 (
    echo Error: Python not found. Please install Python 3.8+ from https://python.org
    pause
    exit /b 1
)

REM ---- Check & install dependencies ----
python -c "import flask, flask_sock, paramiko, yaml, psutil" 2>nul
if errorlevel 1 (
    echo Installing dependencies...
    python -m pip install -r requirements.txt
    if errorlevel 1 (
        echo Error: Failed to install dependencies.
        pause
        exit /b 1
    )
    echo.
)

REM ---- Read port from config.yml ----
for /f "tokens=2 delims=: " %%p in ('python -c "import yaml; c=yaml.safe_load(open('config.yml','r',encoding='utf-8')); print(c.get('web',{}).get('port',9999))" 2^>nul') do set WEBPORT=%%p
if not defined WEBPORT set WEBPORT=9999

echo ============================================
echo  WebSSH - Port Auto-Detect Web Terminal
echo  Starting at http://127.0.0.1:%WEBPORT%
echo  Press Ctrl+C to stop
echo ============================================
echo.

REM ---- Open browser after 2 seconds ----
start "" cmd /c "timeout /t 2 >nul & start http://127.0.0.1:%WEBPORT%"

REM ---- Start server ----
python app.py
pause
