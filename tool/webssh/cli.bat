@echo off
cd /d "%~dp0"

REM ---- CLI SSH terminal, independent from the web UI ----
REM Direct mode   : own paramiko connection (no web / worker involved)
REM Attach mode   : attach to an existing worker session
REM
REM Usage:
REM   cli.bat                auto-detect port, direct connect
REM   cli.bat --port 4983    direct connect to a specific port
REM   cli.bat --list         list live worker sessions
REM   cli.bat --attach SID   attach to a worker session

set PY=C:\Python314\python.exe
if not exist "%PY%" set PY=python

"%PY%" ssh_cli.py %*
