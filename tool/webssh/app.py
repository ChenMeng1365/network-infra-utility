#!/usr/bin/env python3
"""
WebSSH - Port Auto-Detect Web Terminal (detached-worker architecture)

Browser ──WebSocket── Flask(薄代理) ──本地TCP── ssh_worker.py(独立进程,持有SSH)
                                             └─ sessions/ctx_*.json 上下文落盘

Key property: the SSH session lives in a separate worker process.
If the page crashes / refreshes / Flask restarts, the session survives;
the UI can re-attach from the context files (process PID, control port,
target port, state) - tmux-like detach/attach for a web terminal.

Features:
  - Auto-detect local listening port from process name (like portssh.bat)
  - Web-based SSH terminal (xterm.js + WebSocket)
  - Detached worker sessions with context persistence + re-attach
  - Credentials stored in config.yml
  - Session log auto-save + manual download
  - Win10/Win11 compatible
"""

import os
import sys
import json
import time
import uuid
import socket
import signal
import threading
import subprocess
from datetime import datetime
from pathlib import Path

import yaml
import psutil
from flask import Flask, render_template, request, jsonify, send_file, abort
from flask_sock import Sock

# ------------------------------------------------------------------ #
#  Paths & constants
# ------------------------------------------------------------------ #
BASE_DIR = Path(__file__).parent.resolve()
CONFIG_PATH = BASE_DIR / "config.yml"
SESSIONS_DIR = BASE_DIR / "sessions"
WORKER_SCRIPT = BASE_DIR / "ssh_worker.py"

# ------------------------------------------------------------------ #
#  Flask app
# ------------------------------------------------------------------ #
app = Flask(__name__, template_folder=str(BASE_DIR / "templates"))
# flask_sock doesn't expose max_message_size; patch simple_websocket
# so large SFTP directory listings don't hit the default size limit.
import simple_websocket
_orig_server_init = simple_websocket.Server.__init__
def _patched_server_init(self, *args, **kwargs):
    kwargs.setdefault("max_message_size", 10 * 1024 * 1024)  # 10 MB
    kwargs.setdefault("receive_bytes", 65536)
    return _orig_server_init(self, *args, **kwargs)
simple_websocket.Server.__init__ = _patched_server_init
sock = Sock(app)


# ------------------------------------------------------------------ #
#  Config
# ------------------------------------------------------------------ #
def load_config():
    """Load config.yml (re-read each call so edits take effect on next request)."""
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


# ------------------------------------------------------------------ #
#  Process / port detection  (replaces tasklist + netstat from bat)
# ------------------------------------------------------------------ #
def detect_process_port(process_name):
    """
    Find all processes whose name contains *process_name* (case-insensitive)
    and collect their LISTENING ports.

    Strategy (aligned with portssh.bat behaviour):
      1. psutil per-process net_connections() -- fast, but silently skips
         processes we can't query (SYSTEM / elevated ones).
      2. Fallback/merge: netstat -ano (same as the .bat). netstat shows
         ALL listening sockets regardless of process permissions, and we
         match PIDs by name from psutil.

    Returns a list of dicts:
        [{"pid": 13644, "name": "bh_am_pfe_tunnel.exe",
          "ports": [{"port": 4983, "address": "127.0.0.1", "full": "127.0.0.1:4983"}]}]
    """
    results = []
    if not process_name:
        return results

    name_lower = process_name.lower()

    # --- Collect PIDs by name (psutil; may need multiple passes) ---
    pid_to_name = {}
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            proc_name = proc.info.get("name", "") or ""
            if name_lower in proc_name.lower():
                pid_to_name[proc.info["pid"]] = proc_name
        except (psutil.AccessDenied, psutil.NoSuchProcess):
            continue

    if not pid_to_name:
        return results

    # --- Collect listening ports per PID ---
    ports_by_pid = {}

    # Pass 1: psutil per-process connections
    for pid in pid_to_name:
        try:
            conns = psutil.Process(pid).net_connections(kind="inet")
        except (psutil.AccessDenied, psutil.NoSuchProcess):
            conns = []
        for conn in conns:
            if conn.status == psutil.CONN_LISTEN and conn.laddr:
                ports_by_pid.setdefault(pid, []).append(
                    {
                        "port": conn.laddr.port,
                        "address": str(conn.laddr.ip),
                        "full": f"{conn.laddr.ip}:{conn.laddr.port}",
                    }
                )

    # Pass 2 (fallback for inaccessible PIDs): netstat -ano,
    # same source of truth as portssh.bat / shell mode.
    missing = [pid for pid in pid_to_name if pid not in ports_by_pid]
    if missing:
        try:
            netstat_out = subprocess.run(
                ["netstat", "-ano"],
                capture_output=True,
                text=True,
                timeout=15,
                errors="replace",
            ).stdout
            for line in netstat_out.splitlines():
                parts = line.split()
                if len(parts) >= 5 and parts[3] == "LISTENING":
                    try:
                        pid = int(parts[4])
                    except ValueError:
                        continue
                    if pid not in missing:
                        continue
                    local_addr = parts[1]
                    if local_addr.startswith("["):  # IPv6 [addr]:port
                        port_part = local_addr.rsplit("]", 1)[-1].lstrip(":")
                    else:
                        port_part = local_addr.rsplit(":", 1)[-1]
                    try:
                        port = int(port_part)
                    except ValueError:
                        continue
                    ports_by_pid.setdefault(pid, []).append(
                        {
                            "port": port,
                            "address": local_addr.rsplit(":", 1)[0],
                            "full": local_addr,
                        }
                    )
        except Exception:
            pass

    for pid, proc_name in pid_to_name.items():
        ports = ports_by_pid.get(pid, [])
        # Deduplicate by port number
        seen = set()
        uniq_ports = []
        for p in ports:
            if p["port"] not in seen:
                seen.add(p["port"])
                uniq_ports.append(p)
        if uniq_ports:
            results.append({"pid": pid, "name": proc_name, "ports": uniq_ports})

    return results


# ------------------------------------------------------------------ #
#  Session log
# ------------------------------------------------------------------ #
def save_session_log(log_buffer, config):
    """Persist *log_buffer* (list of str) to a timestamped .txt file."""
    if not config.get("logs", {}).get("auto_save", True):
        return None
    if not log_buffer:
        return None

    log_dir = BASE_DIR / config.get("logs", {}).get("dir", "logs")
    log_dir.mkdir(parents=True, exist_ok=True)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    filepath = log_dir / f"session_{ts}.txt"

    content = "".join(log_buffer)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

    return str(filepath)


# ------------------------------------------------------------------ #
#  Worker session management
# ------------------------------------------------------------------ #
def worker_contexts():
    """Read all session context files; returns list of dicts.
    Stale files (worker process gone) are cleaned up."""
    out = []
    if not SESSIONS_DIR.exists():
        return out
    for f in sorted(SESSIONS_DIR.glob("ctx_*.json")):
        try:
            ctx = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        pid = ctx.get("pid")
        alive = False
        if pid:
            try:
                p = psutil.Process(pid)
                alive = p.is_running() and p.status() != psutil.STATUS_ZOMBIE
                # guard against PID reuse: process cmdline should contain ssh_worker
                try:
                    cmd = " ".join(p.cmdline())
                    alive = alive and "ssh_worker" in cmd
                except Exception:
                    pass
            except psutil.NoSuchProcess:
                alive = False
        ctx["alive"] = alive
        if not alive:
            try:
                f.unlink()
            except Exception:
                pass
            continue
        out.append(ctx)
    return out


def spawn_worker(ssh_port):
    """Start a detached ssh_worker.py for *ssh_port*. Returns (sid, error)."""
    sid = uuid.uuid4().hex[:12]
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    # detached: own process group, survives Flask exit
    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS

    try:
        proc = subprocess.Popen(
            [sys.executable, str(WORKER_SCRIPT),
             "--id", sid, "--port", str(ssh_port), "--ctrl-port", "0"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            creationflags=creationflags,
            cwd=str(BASE_DIR),
        )
    except Exception as e:
        return None, f"failed to spawn worker: {e}"

    # wait for the context file to appear (worker binds ctrl socket, then
    # persists ctx with the real ctrl port)
    ctx_path = SESSIONS_DIR / f"ctx_{sid}.json"
    deadline = time.time() + 15
    while time.time() < deadline:
        if ctx_path.exists():
            try:
                ctx = json.loads(ctx_path.read_text(encoding="utf-8"))
                if ctx.get("ctrl_port"):
                    return sid, None
            except Exception:
                pass
        if proc.poll() is not None:
            return None, "worker process exited during startup"
        time.sleep(0.1)
    return None, "worker startup timeout"


def worker_connect(sid, timeout=5.0):
    """Connect to a worker's control socket. Returns socket or None."""
    ctx_path = SESSIONS_DIR / f"ctx_{sid}.json"
    try:
        ctx = json.loads(ctx_path.read_text(encoding="utf-8"))
    except Exception:
        return None
    port = ctx.get("ctrl_port")
    if not port:
        return None
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        return s
    except Exception:
        return None


def send_ctrl(s, obj):
    try:
        s.sendall((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
        return True
    except Exception:
        return False


# ------------------------------------------------------------------ #
#  HTTP routes
# ------------------------------------------------------------------ #
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/detect")
def api_detect():
    """Detect process listening ports. Supports multiple process names."""
    config = load_config()
    # Accept ?process= override (single name or comma-separated)
    override = request.args.get("process", "")
    if override:
        names = [n.strip() for n in override.split(",") if n.strip()]
    else:
        raw = config.get("ssh", {}).get("process_name", "")
        if isinstance(raw, list):
            names = [str(n) for n in raw if n]
        elif raw:
            names = [str(raw)]
        else:
            names = []

    all_results = []
    for name in names:
        all_results.extend(detect_process_port(name))
    return jsonify(
        {
            "process_names": names,
            "results": all_results,
            "manual_port": config.get("ssh", {}).get("port"),
        }
    )


@app.route("/api/config")
def api_config():
    """Return non-sensitive config (no password)."""
    config = load_config()
    return jsonify(
        {
            "ssh": {
                "username": config.get("ssh", {}).get("username", ""),
                "host": config.get("ssh", {}).get("host", "127.0.0.1"),
                "process_name": config.get("ssh", {}).get("process_name", ""),
                "port": config.get("ssh", {}).get("port"),
            },
            "web": {
                "host": config.get("web", {}).get("host", "127.0.0.1"),
                "port": config.get("web", {}).get("port", 8080),
            },
            "terminal": {
                "scrollback": config.get("terminal", {}).get("scrollback", 10000),
            },
            "toolbar": config.get("toolbar", {}),
        }
    )


@app.route("/api/sessions")
def api_sessions():
    """List live detached worker sessions (page crash -> re-attach)."""
    return jsonify({"sessions": worker_contexts()})


@app.route("/api/sessions/<sid>/shutdown", methods=["POST"])
def api_session_shutdown(sid):
    """Terminate a worker session."""
    if "/" in sid or not sid.isalnum():
        abort(400)
    s = worker_connect(sid)
    if s is None:
        # stale context - just clean the file
        try:
            (SESSIONS_DIR / f"ctx_{sid}.json").unlink()
        except FileNotFoundError:
            pass
        return jsonify({"ok": True, "note": "stale context removed"})
    send_ctrl(s, {"op": "shutdown"})
    try:
        s.close()
    except Exception:
        pass
    return jsonify({"ok": True})


@app.route("/api/logs")
def api_logs():
    """List saved session logs (page-level + worker interaction logs)."""
    config = load_config()
    log_dir = BASE_DIR / config.get("logs", {}).get("dir", "logs")
    logs = []
    if log_dir.exists():
        # session_*.txt      - page-side output capture
        # interactive_*.log  - worker-side step-by-step interaction log
        files = list(log_dir.glob("session_*.txt")) + list(log_dir.glob("interactive_*.log"))
        for f in sorted(files, key=lambda p: p.stat().st_mtime, reverse=True):
            st = f.stat()
            logs.append(
                {
                    "name": f.name,
                    "size": st.st_size,
                    "time": datetime.fromtimestamp(st.st_mtime).strftime(
                        "%Y-%m-%d %H:%M:%S"
                    ),
                }
            )
    return jsonify({"logs": logs})


@app.route("/api/logs/<filename>")
def api_download_log(filename):
    """Download a specific session log file."""
    if not (filename.startswith("session_") or filename.startswith("interactive_")):
        abort(404)
    config = load_config()
    log_dir = BASE_DIR / config.get("logs", {}).get("dir", "logs")
    filepath = log_dir / filename
    if not filepath.exists():
        abort(404)
    return send_file(str(filepath), as_attachment=True, download_name=filename)


@app.route("/api/logs/<filename>/content")
def api_log_content(filename):
    """Return the text content of a log file (for in-browser preview tab)."""
    if not (filename.startswith("session_") or filename.startswith("interactive_")):
        abort(404)
    config = load_config()
    log_dir = BASE_DIR / config.get("logs", {}).get("dir", "logs")
    filepath = log_dir / filename
    if not filepath.exists():
        abort(404)
    try:
        content = filepath.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return jsonify({"name": filename, "content": content})


EXTENSION_DIR = BASE_DIR / "extension"


@app.route("/api/extensions")
def api_extensions():
    """List and parse Markdown extension toolbars from the extension/ directory.

    Each .md file in extension/ becomes one toolbar group set. The Markdown
    structure is parsed as follows:
      - File name (without .md) = top-level toolbar name
      - Headings (# ~ ######)   = directory / button names (nested by level)
      - ```shell ... ``` blocks = command scripts attached to the nearest preceding heading
      - Text between heading and code block = comment/tooltip

    Returns a list of toolbar group sets, each with:
      { "name": "<filename>", "groups": [ { name, tools: [...], children: [...] } ] }
    """
    results = []
    if not EXTENSION_DIR.exists():
        return jsonify({"extensions": []})

    import re

    def parse_markdown(text):
        """Parse markdown into a tree of nodes.

        Each node: { name, comment, command, children, level }
        Headings create hierarchical nodes; code blocks attach to the last heading node.
        """
        lines = text.split("\n")
        root = {"name": "", "comment": "", "command": None, "children": [], "level": 0}
        # stack: [root, h1_node, h2_node, ...] - tracks heading nesting
        stack = [root]
        last_heading_node = None
        comment_lines = []

        i = 0
        while i < len(lines):
            line = lines[i]

            # Heading
            m = re.match(r"^(#{1,6})\s+(.+)", line)
            if m:
                level = len(m.group(1))
                name = m.group(2).strip()
                # Pop stack to find parent (level > parent's level)
                while len(stack) > 1 and stack[-1]["level"] >= level:
                    stack.pop()
                parent = stack[-1]
                node = {
                    "name": name,
                    "comment": "",
                    "command": None,
                    "children": [],
                    "level": level,
                }
                parent["children"].append(node)
                stack.append(node)
                last_heading_node = node
                comment_lines = []
                i += 1
                continue

            # Code block (```shell ... ```)
            if line.strip().startswith("```"):
                code_lines = []
                i += 1
                while i < len(lines):
                    if lines[i].strip().startswith("```"):
                        i += 1
                        break
                    code_lines.append(lines[i])
                    i += 1
                code = "\n".join(code_lines)
                if last_heading_node is not None:
                    last_heading_node["command"] = code
                comment_lines = []
                continue

            # Regular text line (comment for the nearest heading)
            if line.strip() and last_heading_node is not None:
                comment_lines.append(line.strip())
                last_heading_node["comment"] = " ".join(comment_lines)

            i += 1

        return root

    for md_file in sorted(EXTENSION_DIR.glob("*.md")):
        try:
            text = md_file.read_text(encoding="utf-8", errors="replace")
            tree = parse_markdown(text)
            # The root's children are the top-level groups
            results.append({
                "name": md_file.stem,
                "root": tree,
            })
        except Exception:
            continue

    return jsonify({"extensions": results})


@app.route("/api/extensions/import", methods=["POST"])
def api_extensions_import():
    """Import a toolbar markdown file into extension/ (temporary import).

    Allows adding a toolbar group set without touching the server
    filesystem manually. Re-importing the same filename overwrites
    the previous version. The page then just reloads toolbars.
    """
    if "file" not in request.files:
        return jsonify({"error": "no file uploaded"}), 400
    f = request.files["file"]
    raw_name = f.filename or ""
    if not raw_name.strip():
        return jsonify({"error": "empty filename"}), 400
    # sanitize: keep only the basename, force .md suffix
    name = Path(raw_name).name
    if not name.lower().endswith(".md"):
        name += ".md"
    # block Windows reserved device names just in case
    if name.split(".")[0].upper() in {
        "CON", "PRN", "AUX", "NUL",
        *(f"COM{i}" for i in range(1, 10)),
        *(f"LPT{i}" for i in range(1, 10)),
    }:
        return jsonify({"error": "invalid filename"}), 400
    EXTENSION_DIR.mkdir(parents=True, exist_ok=True)
    f.save(EXTENSION_DIR / name)
    return jsonify({"ok": True, "name": name})


# ------------------------------------------------------------------ #
#  WebSocket  – thin proxy to worker control socket
# ------------------------------------------------------------------ #
@sock.route("/ws/ssh")
def ws_ssh(ws):
    """
    Browser <-> worker bridge.

    Query params:
        port=NNNN            start a NEW worker session for this SSH port
        attach=<sid>         attach to an EXISTING worker session

    Client -> worker (JSON, forwarded verbatim):
        {"op": "input",  "data": "ls\r"}
        {"op": "resize", "cols": 80, "rows": 24}
        {"op": "detach"}

    Worker -> client (JSON):
        {"ev": "hello",  "sid": ..., "state": ..., "scrollback": [...]}
        {"ev": "output", "data": "...", "seq": N}
        {"ev": "state",  "state": "connected"|"disconnected", "why": ...}
        {"ev": "bye"}
    """
    attach_sid = request.args.get("attach")
    ssh_port = request.args.get("port", type=int)

    # --- resolve / create worker ---
    if attach_sid:
        if not attach_sid.isalnum():
            ws.send(json.dumps({"type": "error", "data": "bad session id"}))
            return
        s = worker_connect(attach_sid)
        if s is None:
            ws.send(json.dumps({
                "type": "error",
                "data": f"无法接入会话 {attach_sid}：worker 不在线（可能已被清理）",
            }))
            return
        sid = attach_sid
    elif ssh_port:
        sid, err = spawn_worker(ssh_port)
        if err:
            ws.send(json.dumps({"type": "error", "data": f"启动会话进程失败: {err}"}))
            return
        s = worker_connect(sid)
        if s is None:
            ws.send(json.dumps({
                "type": "error",
                "data": "会话进程已启动但控制通道连接失败",
            }))
            return
    else:
        ws.send(json.dumps({"type": "error", "data": "No port or session specified"}))
        return

    log_buffer = []

    # --- thread: worker -> browser ---
    def worker_to_ws():
        # The control socket was created with a short connect timeout.
        # For the long-lived proxy loop that timeout must be removed,
        # otherwise a quiet period (>5s no output) raises TimeoutError
        # and gets misreported as a broken backend channel.
        try:
            s.settimeout(None)
        except Exception:
            pass
        buf = b""
        try:
            while True:
                chunk = s.recv(65536)
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
                        # forward scrollback so the terminal shows history
                        for item in ev.get("scrollback", []):
                            ws.send(json.dumps({
                                "type": "output", "data": item.get("data", ""),
                            }))
                        log_buffer.extend(
                            item.get("data", "") for item in ev.get("scrollback", [])
                        )
                        # sid must reach the browser: without it the
                        # frontend cannot track the new session and the
                        # toolbar target state stays stale after connect.
                        ws.send(json.dumps({
                            "type": "status",
                            "data": "connected" if ev.get("state") == "connected" else ev.get("state", ""),
                            "sid": ev.get("sid"),
                        }))
                    elif ev.get("ev") == "output":
                        data = ev.get("data", "")
                        log_buffer.append(data)
                        ws.send(json.dumps({"type": "output", "data": data}))
                    elif ev.get("ev") == "state":
                        why = ev.get("why", "")
                        ws.send(json.dumps({
                            "type": "status" if ev.get("state") == "connected" else "error",
                            "data": why or ev.get("state", ""),
                        }))
                    elif ev.get("ev") == "bye":
                        ws.send(json.dumps({"type": "status", "data": "会话已由 worker 结束"}))
                        return
                    else:
                        # Forward any other event (sftp_list, sftp_progress,
                        # sftp_done, sftp_error, sftp_home, sftp_mkdir_done)
                        # as a typed message to the browser.
                        ws.send(json.dumps({"type": ev.get("ev", "event"),
                                            "data": ev}))
        except Exception as e:
            # worker control socket broke unexpectedly (SSH died, worker
            # exited, etc.) - tell the browser WHY instead of a bare close.
            try:
                ws.send(json.dumps({
                    "type": "error",
                    "data": f"后端会话通道中断: {e!r}",
                }))
            except Exception:
                pass
        finally:
            try:
                ws.close()
            except Exception:
                pass

    t = threading.Thread(target=worker_to_ws, daemon=True)
    t.start()

    # --- main loop: browser -> worker ---
    try:
        while True:
            msg = ws.receive()
            if msg is None:
                break
            try:
                data = json.loads(msg)
            except (json.JSONDecodeError, ValueError):
                continue

            if data.get("type") == "input":
                send_ctrl(s, {"op": "input", "data": data.get("data", "")})
            elif data.get("type") == "resize":
                send_ctrl(s, {"op": "resize",
                              "cols": data.get("cols", 80),
                              "rows": data.get("rows", 24)})
            elif data.get("type") == "sftp_list":
                send_ctrl(s, {"op": "sftp_list", "path": data.get("path", "/")})
            elif data.get("type") == "sftp_home":
                send_ctrl(s, {"op": "sftp_home"})
            elif data.get("type") == "sftp_upload_start":
                send_ctrl(s, {"op": "sftp_upload_start",
                              "path": data.get("path", ""),
                              "size": data.get("size", 0)})
            elif data.get("type") == "sftp_upload_chunk":
                send_ctrl(s, {"op": "sftp_upload_chunk",
                              "data": data.get("data", "")})
            elif data.get("type") == "sftp_upload_end":
                send_ctrl(s, {"op": "sftp_upload_end"})
            elif data.get("type") == "sftp_mkdir":
                send_ctrl(s, {"op": "sftp_mkdir", "path": data.get("path", "")})
            elif data.get("type") == "sftp_download_start":
                send_ctrl(s, {"op": "sftp_download_start", "path": data.get("path", "")})
    except Exception:
        pass
    finally:
        # page closed/crashed -> tell worker we detached; session keeps living
        send_ctrl(s, {"op": "detach"})
        try:
            s.close()
        except Exception:
            pass
        t.join(timeout=2)
        save_session_log(log_buffer, load_config())


# ------------------------------------------------------------------ #
#  Entry point
# ------------------------------------------------------------------ #
if __name__ == "__main__":
    config = load_config()
    web_cfg = config.get("web", {})
    host = web_cfg.get("host", "127.0.0.1")
    port = web_cfg.get("port", 8080)

    print(f"WebSSH server starting at http://{host}:{port}")
    print(f"Detached worker sessions dir: {SESSIONS_DIR}")
    print("Press Ctrl+C to stop\n")

    # threaded=True is REQUIRED: the WebSocket proxy holds its handler
    # for the whole session; single-threaded mode would freeze all other
    # requests (page refresh, /api/detect, ...) while a terminal is open.
    app.run(host=host, port=port, debug=False, threaded=True)
