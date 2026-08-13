@echo off
REM ssh_core_rs engine launcher for Windows
REM Starts the Rust SSH core engine in foreground mode.
REM Called by Ruby Client.spawn_engine via Process.spawn.
REM
REM This is the Rust-based replacement for the Erlang ssh_core engine.
REM It implements the exact same IPC protocol, so Ruby can switch between
REM the two backends by changing the engine_binary_path in client.rb.

setlocal

set SCRIPT_DIR=%~dp0
set SRC_DIR=%SCRIPT_DIR%..

REM Delete stale endpoint file so Ruby can detect fresh startup
set EP_FILE=%TEMP%\ssh_core_%USERNAME%.endpoint
if exist "%EP_FILE%" del "%EP_FILE%"

REM Check if pre-built binary exists
set BINARY=%SRC_DIR%\target\release\ssh_core_rs.exe
if exist "%BINARY%" goto :run

REM Build if not yet compiled
echo Building ssh_core_rs (release)...
where cargo >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo Error: cargo not found in PATH. Please install Rust toolchain.
    exit /b 1
)
cargo build --release --manifest-path "%SRC_DIR%\Cargo.toml"
if %ERRORLEVEL% neq 0 (
    echo Error: cargo build failed.
    exit /b 1
)

:run
REM Run the engine in foreground (blocks until shutdown)
"%BINARY%"

endlocal
