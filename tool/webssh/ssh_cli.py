#!/usr/bin/env python3
"""
ssh_cli.py - Command-line SSH client, independent from the web UI.

Two access modes:

  direct (default)   opens its OWN paramiko SSH connection - no Flask,
                     no worker process, no browser involved. Use this to
                     compare against the web terminal and tell whether a
                     problem lives in the SSH layer or the web display
                     layer.

  attach             attaches to an EXISTING detached worker session
                     (same sessions the web page shows). Use this to test
                     the worker<->client path without the browser.

Usage:
  python ssh_cli.py                     auto-detect port, direct connect
  python ssh_cli.py --port 4983         direct connect to a specific port
  python ssh_cli.py --list              list live worker sessions
  python ssh_cli.py --attach <sid>      attach to a worker session

Keys:
  Ctrl+Q    quit locally (session unaffected in attach mode)
  Ctrl+C    forwarded to the remote shell as SIGINT, like real ssh
  Ctrl+D    forwarded to the remote shell (EOF)

Interaction logging (same format as the worker, logs/interactive_*.log):
  every connect step, every keystroke sent, every output chunk received
  (escape sequences visible, e.g. the busybox DSR query shows as \\x1b[6n).
"""

import argparse
import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path

BASE_DIR = Path(__file__).parent.resolve()
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

import paramiko

from ssh_worker import (
    InteractionLog,
    load_logs_config,
    load_ssh_config,
    make_transport_factory,
)

# reuse the exact same detection / session helpers as the web app
from app import detect_process_port, send_ctrl, worker_connect, worker_contexts

# ------------------------------------------------------------------ #
#  Console setup (Windows VT sequences + UTF-8 output)
# ------------------------------------------------------------------ #
IS_WINDOWS = os.name == "nt"
if IS_WINDOWS:
    import ctypes
    import msvcrt

    def enable_vt():
        """Enable ANSI/VT escape processing in the Windows console."""
        try:
            kernel32 = ctypes.windll.kernel32
            h = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            mode = ctypes.c_uint32()
            if kernel32.GetConsoleMode(h, ctypes.byref(mode)):
                kernel32.SetConsoleMode(h, mode.value | 0x0004)
        except Exception:
            pass

else:
    import termios
    import tty

    def enable_vt():
        pass  # POSIX terminals handle VT natively


def setup_stdout():
    enable_vt()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


# ------------------------------------------------------------------ #
#  Keyboard input (non-blocking, Windows msvcrt / POSIX raw tty)
# ------------------------------------------------------------------ #
# Windows console extended key codes -> terminal escape sequences
WIN_EXT_KEYS = {
    "H": "\x1b[A",  # Up
    "P": "\x1b[B",  # Down
    "K": "\x1b[D",  # Left
    "M": "\x1b[C",  # Right
    "G": "\x1b[H",  # Home
    "O": "\x1b[F",  # End
    "I": "\x1b[5~",  # PageUp
    "Q": "\x1b[6~",  # PageDown
    "R": "\x1b[2~",  # Insert
    "S": "\x1b[3~",  # Delete
}

QUIT_KEY = "\x11"  # Ctrl+Q


def read_key():
    """Return the next key as a terminal-ready string, or None."""
    if IS_WINDOWS:
        if msvcrt.kbhit():
            c = msvcrt.getwch()
            if c in ("\x00", "\xe0"):
                c2 = msvcrt.getwch()
                return WIN_EXT_KEYS.get(c2, "")
            return c
        return None
    else:
        import select

        r, _, _ = select.select([sys.stdin], [], [], 0)
        if r:
            return os.read(sys.stdin.fileno(), 1).decode("utf-8", errors="replace")
        return None


# ------------------------------------------------------------------ #
#  Shared helpers
# ------------------------------------------------------------------ #
def write_out(text):
    try:
        sys.stdout.write(text)
        sys.stdout.flush()
    except Exception:
        pass


def console_size():
    size = shutil.get_terminal_size(fallback=(80, 24))
    return size.columns, size.lines


def pick_port():
    """Auto-detect the SSH port using the same logic as the web app.
    Supports multiple process names (string or list in config)."""
    cfg = load_ssh_config()
    raw = cfg.get("process_name", "")
    if isinstance(raw, list):
        names = [str(n) for n in raw if n]
    elif raw:
        names = [str(raw)]
    else:
        names = []

    ports = []
    for name in names:
        results = detect_process_port(name)
        for proc in results:
            ports.extend(p["port"] for p in proc.get("ports", []))
    if not ports:
        return None
    if len(ports) > 1:
        write_out(
            f"\r\n*** 检测到多个端口: {', '.join(str(p) for p in ports)}"
            f"（使用第一个，或用 --port 指定） ***\r\n"
        )
    return ports[0]


# ------------------------------------------------------------------ #
#  Mode 1: direct connection (fully independent from web/worker)
# ------------------------------------------------------------------ #
def run_direct(port):
    logs_cfg = load_logs_config()
    ilog = InteractionLog(f"cli_{port}", enabled=logs_cfg.get("interactive", True))
    if logs_cfg.get("trace"):
        try:
            paramiko.util.log_to_file(
                str(BASE_DIR / "logs" / f"paramiko_cli_{port}.log"), level="DEBUG"
            )
        except Exception:
            pass

    cfg = load_ssh_config()
    write_out(f"\r\n*** 直连模式: {cfg.get('host')}:{port} (用户 {cfg.get('username')}) ***\r\n")

    ilog.log("CONNECT-START", f"mode=direct port={port} pid={os.getpid()}")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(
            hostname=cfg.get("host", "127.0.0.1"),
            port=port,
            username=cfg.get("username", ""),
            password=cfg.get("password", ""),
            look_for_keys=False,
            allow_agent=False,
            timeout=10,
            transport_factory=make_transport_factory(),
        )
    except Exception as e:
        ilog.log("CONNECT-FAILED", repr(e))
        write_out(f"\r\n*** 连接失败: {e} ***\r\n\r\n按任意键退出...")
        read_key()
        ilog.close()
        return

    transport = client.get_transport()
    keepalive = float(cfg.get("keepalive_interval", 0))
    if transport is not None and keepalive > 0:
        transport.set_keepalive(keepalive)

    channel = client.invoke_shell(term="xterm-256color")
    try:
        cols, rows = console_size()
        channel.resize_pty(width=cols, height=rows)
    except Exception:
        pass

    try:
        ver = transport.remote_version if transport else "?"
    except Exception:
        ver = "?"
    ilog.log("CONNECTED", f"server={ver}")
    if ilog.path:
        write_out(f"*** 交互日志: {ilog.path.name} ***\r\n")
    write_out("*** 已连接。Ctrl+Q 本地退出；Ctrl+C 发送到远端 ***\r\n\r\n")

    closed = threading.Event()
    why = [""]

    def reader():
        try:
            while not closed.is_set():
                if channel.recv_ready():
                    data = channel.recv(4096).decode("utf-8", errors="replace")
                    if not data:
                        break
                    ilog.log("OUT", repr(data))
                    write_out(data)
                elif channel.exit_status_ready() and not channel.recv_ready():
                    time.sleep(0.2)
                    if not channel.recv_ready():
                        why[0] = "远端 shell 已退出"
                        break
                elif transport is None or not transport.is_active():
                    why[0] = "SSH 连接已关闭"
                    break
                else:
                    time.sleep(0.02)
        except Exception as e:
            why[0] = f"读取错误: {e!r}"
        finally:
            closed.set()

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    last_size = console_size()
    try:
        while not closed.is_set():
            key = read_key()
            if key:
                if key == QUIT_KEY:
                    why[0] = "本地退出 (Ctrl+Q)"
                    break
                ilog.log("IN", repr(key))
                try:
                    channel.send(key)
                except Exception as e:
                    why[0] = f"发送失败: {e!r}"
                    break
            # follow console resizes
            size = console_size()
            if size != last_size:
                last_size = size
                ilog.log("RESIZE", f"{size[0]}x{size[1]}")
                try:
                    channel.resize_pty(width=size[0], height=size[1])
                except Exception:
                    pass
            time.sleep(0.01)
    finally:
        closed.set()
        t.join(timeout=1)
        try:
            channel.close()
        except Exception:
            pass
        try:
            client.close()
        except Exception:
            pass
        ilog.log("DISCONNECTED", f"why={why[0] or 'exit'}")
        ilog.close()
        write_out(f"\r\n\r\n*** 会话结束: {why[0] or 'exit'} ***\r\n")


# ------------------------------------------------------------------ #
#  Mode 2: attach to an existing worker session
# ------------------------------------------------------------------ #
def run_attach(sid):
    s = worker_connect(sid)
    if s is None:
        write_out(f"\r\n*** 无法接入会话 {sid}: worker 不在线 ***\r\n")
        return
    # long-lived proxy socket must not time out during quiet periods
    try:
        s.settimeout(None)
    except Exception:
        pass

    write_out(f"\r\n*** 接入模式: 会话 {sid} (worker 后端保持不变) ***\r\n")
    write_out("*** Ctrl+Q 返回本地（会话继续运行）；Ctrl+C 发送到远端 ***\r\n\r\n")

    closed = threading.Event()

    def reader():
        buf = b""
        try:
            while not closed.is_set():
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line)
                    except (json.JSONDecodeError, ValueError):
                        continue
                    if ev.get("ev") == "hello":
                        # replay scrollback first
                        for item in ev.get("scrollback", []):
                            write_out(item.get("data", ""))
                        write_out(
                            f"\r\n*** 已接入 (state={ev.get('state')}, "
                            f"{len(ev.get('scrollback', []))} 条历史) ***\r\n"
                        )
                    elif ev.get("ev") == "output":
                        write_out(ev.get("data", ""))
                    elif ev.get("ev") == "state":
                        write_out(f"\r\n*** 状态: {ev.get('state')} {ev.get('why', '')} ***\r\n")
                    elif ev.get("ev") == "bye":
                        write_out("\r\n*** worker 会话已结束 ***\r\n")
                        closed.set()
                        return
        except Exception:
            pass
        finally:
            closed.set()

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    last_size = console_size()
    try:
        while not closed.is_set():
            key = read_key()
            if key:
                if key == QUIT_KEY:
                    break
                send_ctrl(s, {"op": "input", "data": key})
            size = console_size()
            if size != last_size:
                last_size = size
                send_ctrl(s, {"op": "resize", "cols": size[0], "rows": size[1]})
            time.sleep(0.01)
    finally:
        closed.set()
        send_ctrl(s, {"op": "detach"})
        t.join(timeout=1)
        try:
            s.close()
        except Exception:
            pass
        write_out("\r\n\r\n*** 已退出接入（worker 会话继续运行） ***\r\n")


# ------------------------------------------------------------------ #
#  Mode 3: list worker sessions
# ------------------------------------------------------------------ #
def run_list():
    sessions = worker_contexts()
    if not sessions:
        write_out("暂无存活的 worker 会话\r\n")
        return
    write_out(f"{'会话ID':<14} {'状态':<13} {'SSH端口':<8} {'PID':<8} 创建时间\r\n")
    for s in sessions:
        write_out(
            f"{s.get('sid', ''):<14} {s.get('state', ''):<13} "
            f"{s.get('ssh_port', ''):<8} {s.get('pid', ''):<8} {s.get('created', '')}\r\n"
        )
    write_out("\r\n接入: python ssh_cli.py --attach <会话ID>\r\n")


# ------------------------------------------------------------------ #
#  Entry
# ------------------------------------------------------------------ #
def main():
    ap = argparse.ArgumentParser(
        description="命令行 SSH 终端（与 web 界面独立，直连或接入 worker 会话）"
    )
    ap.add_argument("--port", type=int, help="直连指定 SSH 端口")
    ap.add_argument("--attach", metavar="SID", help="接入已存在的 worker 会话")
    ap.add_argument("--list", action="store_true", help="列出存活的 worker 会话")
    args = ap.parse_args()

    setup_stdout()

    if args.list:
        run_list()
        return
    if args.attach:
        run_attach(args.attach)
        return

    port = args.port
    if port is None:
        port = pick_port()
    if not port:
        write_out(
            "\r\n*** 未检测到可用端口。请确认隧道进程在运行，"
            "或用 --port <端口> 手动指定 ***\r\n"
        )
        sys.exit(1)

    if not IS_WINDOWS:
        # POSIX: switch the tty to raw mode so keys go through unfiltered
        old = termios.tcgetattr(sys.stdin)
        tty.setraw(sys.stdin.fileno())
        try:
            run_direct(port)
        finally:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
    else:
        run_direct(port)


if __name__ == "__main__":
    main()
