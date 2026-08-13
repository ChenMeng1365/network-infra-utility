@echo off
REM ssh_core engine launcher for Windows
REM Starts the Erlang ssh_core application in foreground mode.
REM Called by Ruby Client.spawn_engine via Process.spawn.

setlocal

set SCRIPT_DIR=%~dp0
set SSH_CORE_DIR=%SCRIPT_DIR%..
set EBIN_DIR=%SSH_CORE_DIR%\_build\default\lib\ssh_core\ebin

REM Use Erlang OTP from the system PATH or default install location
where erl.exe >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set ERL=erl.exe
) else (
    set ERL="C:\Program Files\Erlang OTP\bin\erl.exe"
)

REM Delete stale endpoint file so Ruby can detect fresh startup
set EP_FILE=%TEMP%\ssh_core_%USERNAME%.endpoint
if exist "%EP_FILE%" del "%EP_FILE%"

REM Start the Erlang VM: load ssh_core ebin, start the application, keep running
REM No -sname: we don't need Erlang distribution, and it causes name conflicts
%ERL% -noshell -noinput -pa "%EBIN_DIR%" -eval "application:ensure_all_started(ssh_core)"

endlocal
