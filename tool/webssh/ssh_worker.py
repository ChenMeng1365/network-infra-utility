#!/usr/bin/env python3
"""
ssh_worker.py - Detached SSH session worker process.

Holds ONE paramiko SSH session (the real long connection) in its own
process, independent from Flask. Flask (or any client) talks to it over
a localhost TCP control socket with line-based JSON.

Context persistence:
    sessions/ctx_<id>.json  - who we are, target port, state, control port

Control protocol (one JSON object per line, both directions):
    -> {"op": "attach"}                     client wants live output+input
    -> {"op": "detach"}                     client stops proxying
    -> {"op": "input",  "data": "ls\r"}
    -> {"op": "resize", "cols": 80, "rows": 24}
    -> {"op": "shutdown"}                   terminate the session
    <- {"ev": "hello",  "sid": "...", "state": "connected"}
    <- {"ev": "output", "data": "...", "seq": 42}
    <- {"ev": "state",  "state": "connected"|"disconnected", "why": "..."}
    <- {"ev": "bye"}

Interaction log (logs/interactive_<ts>_<sid>.log, every step recorded):
    <ts> [CONNECT-START] sid=... port=... pid=...
    <ts> [CONNECTED] server=SSH-2.0-...
    <ts> [CLIENT] attach from 127.0.0.1:xxxx (1 attached, state=connected)
    <ts> [IN] 'ls\r'                  <- repr(), escapes visible
    <ts> [OUT] 'HS-API-RELAY:~$ \x1b[6n'
    <ts> [RESIZE] 120x30
    <ts> [DISCONNECTED] why=SSH transport closed
    <ts> [SHUTDOWN] requested by 127.0.0.1:xxxx

Run:  python ssh_worker.py --id <sid> --port <ssh_port> --ctrl-port 0
"""

import argparse
import json
import os
import socket
import sys
import threading
import time
import traceback
from datetime import datetime
from pathlib import Path

import paramiko
import yaml

BASE_DIR = Path(__file__).parent.resolve()
SESSIONS_DIR = BASE_DIR / "sessions"
LOGS_DIR = BASE_DIR / "logs"


# ------------------------------------------------------------------ #
#  Config
# ------------------------------------------------------------------ #
def load_ssh_config():
    with open(BASE_DIR / "config.yml", "r", encoding="utf-8") as f:
        return yaml.safe_load(f).get("ssh", {})


def load_logs_config():
    try:
        with open(BASE_DIR / "config.yml", "r", encoding="utf-8") as f:
            return yaml.safe_load(f).get("logs", {})
    except Exception:
        return {}


# ------------------------------------------------------------------ #
#  Session context file
# ------------------------------------------------------------------ #
def save_context(sid, data):
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    ctx = SESSIONS_DIR / f"ctx_{sid}.json"
    tmp = ctx.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(ctx)


def remove_context(sid):
    p = SESSIONS_DIR / f"ctx_{sid}.json"
    try:
        p.unlink()
    except FileNotFoundError:
        pass


# ------------------------------------------------------------------ #
#  Legacy algorithm lists (embedded O&M relays need them)
# ------------------------------------------------------------------ #
LEGACY_KEX = [
    "diffie-hellman-group-exchange-sha1",
    "diffie-hellman-group14-sha1",
    "diffie-hellman-group1-sha1",
]
LEGACY_KEYS = ["ssh-rsa"]
LEGACY_CIPHERS = [
    "aes128-cbc",
    "aes256-cbc",
    "3des-cbc",
    "arcfour128",
    "arcfour256",
]
LEGACY_MACS = [
    "hmac-sha1",
    "hmac-sha1-96",
    "hmac-md5",
    "hmac-md5-96",
]


def make_transport_factory():
    def transport_factory(sock, **kwargs):
        t = paramiko.Transport(sock, **kwargs)
        try:
            t._preferred_kex = list(t._preferred_kex) + [
                a for a in LEGACY_KEX if a not in t._preferred_kex
            ]
            t._preferred_keys = list(t._preferred_keys) + [
                a for a in LEGACY_KEYS if a not in t._preferred_keys
            ]
            t._preferred_ciphers = list(t._preferred_ciphers) + [
                a for a in LEGACY_CIPHERS if a not in t._preferred_ciphers
            ]
            t._preferred_macs = list(t._preferred_macs) + [
                a for a in LEGACY_MACS if a not in t._preferred_macs
            ]
        except Exception:
            pass
        return t

    return transport_factory


# ------------------------------------------------------------------ #
#  Interaction log - every step of the session, written by the worker
#  process itself so it survives page refreshes / Flask restarts.
#
#  Format:  <ts> [TAG] <payload>
#  Tags:    CONNECT-START / CONNECTED / CONNECT-FAILED / IN / OUT /
#           RESIZE / CLIENT / DISCONNECTED / SHUTDOWN / ERROR
#  Payload for IN/OUT uses repr() so escape sequences stay visible
#  (e.g. the busybox DSR query shows as \x1b[6n) for debugging.
# ------------------------------------------------------------------ #
class InteractionLog:
    def __init__(self, sid, enabled=True):
        self.enabled = enabled
        self.f = None
        self.path = None
        self.lock = threading.Lock()
        if enabled:
            try:
                LOGS_DIR.mkdir(parents=True, exist_ok=True)
                ts = datetime.now().strftime("%Y%m%d_%H%M%S")
                self.path = LOGS_DIR / f"interactive_{ts}_{sid}.log"
                self.f = open(self.path, "a", encoding="utf-8", errors="backslashreplace")
            except Exception:
                self.enabled = False
                self.f = None

    def log(self, tag, text=""):
        if not self.enabled or self.f is None:
            return
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        line = f"{ts} [{tag}] {text}\n"
        try:
            with self.lock:
                self.f.write(line)
                self.f.flush()
        except Exception:
            pass

    def close(self):
        if self.f is not None:
            try:
                self.f.close()
            except Exception:
                pass
            self.f = None


# ------------------------------------------------------------------ #
#  Worker
# ------------------------------------------------------------------ #
class Worker:
    def __init__(self, sid, ssh_port, ctrl_port):
        self.sid = sid
        self.ssh_port = ssh_port
        self.ctrl_port = ctrl_port
        self.state = "connecting"      # connecting|connected|disconnected
        self.why = ""
        self.client = None
        self.channel = None
        self.transport = None

        self.lock = threading.Lock()
        self.clients = []              # attached control connections
        self.scrollback = []           # full output history for re-attach
        self.seq = 0

        self.stop = threading.Event()

        logs_cfg = load_logs_config()
        self.ilog = InteractionLog(sid, enabled=logs_cfg.get("interactive", True))
        self.trace = bool(logs_cfg.get("trace", False))

    # ---------- context ----------
    def ctx(self, **extra):
        return {
            "sid": self.sid,
            "pid": os.getpid(),
            "ssh_port": self.ssh_port,
            "ctrl_port": self.ctrl_port,
            "state": self.state,
            "created": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "alive": True,
            **extra,
        }

    def persist(self):
        save_context(self.sid, self.ctx())

    # ---------- client fan-out ----------
    def add_client(self, conn):
        with self.lock:
            self.clients.append(conn)

    def drop_client(self, conn):
        with self.lock:
            if conn in self.clients:
                self.clients.remove(conn)

    def broadcast(self, obj):
        data = json.dumps(obj, ensure_ascii=False) + "\n"
        dead = []
        with self.lock:
            for c in self.clients:
                try:
                    c.sendall(data.encode("utf-8"))
                except Exception:
                    dead.append(c)
            for c in dead:
                self.clients.remove(c)

    def push_output(self, text):
        self.seq += 1
        self.scrollback.append({"seq": self.seq, "data": text})
        # keep memory bounded
        if len(self.scrollback) > 10000:
            del self.scrollback[: len(self.scrollback) - 10000]
        self.ilog.log("OUT", repr(text))
        self.broadcast({"ev": "output", "data": text, "seq": self.seq})

    # ---------- SSH ----------
    def connect_ssh(self):
        self.ilog.log(
            "CONNECT-START", f"sid={self.sid} port={self.ssh_port} pid={os.getpid()}"
        )
        # optional paramiko debug trace (kex/cipher negotiation details)
        if self.trace:
            try:
                LOGS_DIR.mkdir(parents=True, exist_ok=True)
                paramiko.util.log_to_file(
                    str(LOGS_DIR / f"paramiko_{self.sid}.log"), level="DEBUG"
                )
            except Exception:
                pass

        cfg = load_ssh_config()
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        kwargs = dict(
            hostname=cfg.get("host", "127.0.0.1"),
            port=self.ssh_port,
            username=cfg.get("username", ""),
            password=cfg.get("password", ""),
            look_for_keys=False,
            allow_agent=False,
            timeout=10,
            transport_factory=make_transport_factory(),
        )
        client.connect(**kwargs)
        self.client = client
        self.transport = client.get_transport()

        keepalive = float(cfg.get("keepalive_interval", 0))
        if self.transport is not None and keepalive > 0:
            self.transport.set_keepalive(keepalive)

        self.channel = client.invoke_shell(term="xterm-256color")
        self.state = "connected"
        self.persist()

        try:
            ver = self.transport.remote_version if self.transport else "?"
        except Exception:
            ver = "?"
        self.ilog.log("CONNECTED", f"server={ver}")

    # ---------- reader thread ----------
    def reader_loop(self):
        idle = 0.0
        while not self.stop.is_set():
            try:
                dead = self.transport is None or not self.transport.is_active()
            except Exception:
                dead = True
            if dead and idle > 2.0:
                self.state = "disconnected"
                self.why = "SSH transport closed"
                self.ilog.log("DISCONNECTED", f"why={self.why}")
                self.broadcast({"ev": "state", "state": "disconnected", "why": self.why})
                self.persist()
                break
            if self.channel.recv_ready():
                data = self.channel.recv(4096).decode("utf-8", errors="replace")
                idle = 0.0
                self.push_output(data)
            elif self.channel.exit_status_ready() and not self.channel.recv_ready():
                # give late output a moment to arrive before declaring exit
                time.sleep(0.3)
                if self.channel.recv_ready():
                    continue
                self.state = "disconnected"
                self.why = "channel exited"
                self.ilog.log("DISCONNECTED", f"why={self.why}")
                self.broadcast({"ev": "state", "state": "disconnected", "why": self.why})
                self.persist()
                break
            else:
                time.sleep(0.02)
                idle += 0.02

    # ---------- control connection handler ----------
    def handle_client(self, conn, addr):
        # IMPORTANT: register BEFORE sending hello, otherwise broadcast()
        # has no receivers and live output never reaches this client
        # (they would only ever see stale scrollback replays).
        self.add_client(conn)
        f = conn.makefile("r", encoding="utf-8", errors="replace")
        try:
            with self.lock:
                n = len(self.clients)
            self.ilog.log(
                "CLIENT",
                f"attach from {addr[0]}:{addr[1]} ({n} attached, state={self.state})",
            )
            conn.sendall(
                (json.dumps({
                    "ev": "hello",
                    "sid": self.sid,
                    "state": self.state,
                    "seq": self.seq,
                    "scrollback": self.scrollback[-1000:],
                }, ensure_ascii=False) + "\n").encode("utf-8")
            )
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                op = msg.get("op")
                if op == "input":
                    data = msg.get("data", "")
                    self.ilog.log("IN", repr(data))
                    try:
                        self.channel.send(data)
                    except Exception as e:
                        self.ilog.log("ERROR", f"channel.send failed: {e!r}")
                elif op == "resize":
                    cols = int(msg.get("cols", 80))
                    rows = int(msg.get("rows", 24))
                    self.ilog.log("RESIZE", f"{cols}x{rows}")
                    try:
                        self.channel.resize_pty(width=cols, height=rows)
                    except Exception as e:
                        self.ilog.log("ERROR", f"resize_pty failed: {e!r}")
                elif op == "detach":
                    self.ilog.log("CLIENT", f"detach from {addr[0]}:{addr[1]}")
                    break
                elif op == "shutdown":
                    self.ilog.log("SHUTDOWN", f"requested by {addr[0]}:{addr[1]}")
                    self.stop.set()
                    self.broadcast({"ev": "bye"})
                    break
        except Exception as e:
            self.ilog.log("ERROR", f"control conn {addr} error: {e!r}")
        finally:
            self.drop_client(conn)
            try:
                conn.close()
            except Exception:
                pass

    # ---------- main ----------
    def run(self):
        # 1) bind control socket FIRST (port 0 = auto-assign), so Flask
        #    can learn our port even if SSH connect is slow/failing.
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", self.ctrl_port))
        srv.listen(8)
        self.ctrl_port = srv.getsockname()[1]
        self.persist()

        # 2) connect SSH (state file reflects connecting|connected|failed)
        try:
            self.connect_ssh()
        except Exception as e:
            self.state = "disconnected"
            self.why = f"SSH connect failed: {e}"
            self.ilog.log("CONNECT-FAILED", self.why)
            self.persist()
            # give Flask a moment to read the context, then exit
            time.sleep(3)
            remove_context(self.sid)
            srv.close()
            self.ilog.close()
            return

        threading.Thread(target=self.reader_loop, daemon=True).start()

        # 3) accept control connections until session ends
        try:
            srv.settimeout(1.0)
            while not self.stop.is_set() and self.state != "disconnected":
                try:
                    conn, addr = srv.accept()
                except socket.timeout:
                    continue
                threading.Thread(
                    target=self.handle_client, args=(conn, addr), daemon=True
                ).start()
        finally:
            self.state = "disconnected"
            self.persist()
            self.ilog.log("DISCONNECTED", f"why={self.why or 'worker exit'}")
            # give attached clients (Flask -> browser proxy) a moment to
            # receive the "disconnected" state event before we tear down
            # the control socket; otherwise the browser only ever sees a
            # bare WebSocket close with no reason.
            try:
                time.sleep(0.7)
            except Exception:
                pass
            try:
                self.channel.close()
            except Exception:
                pass
            try:
                self.client.close()
            except Exception:
                pass
            remove_context(self.sid)
            srv.close()
            self.ilog.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", required=True)
    ap.add_argument("--port", type=int, required=True, help="SSH target port")
    ap.add_argument("--ctrl-port", type=int, default=0, help="control listen port (0=auto)")
    args = ap.parse_args()

    w = Worker(args.id, args.port, args.ctrl_port)
    try:
        w.run()
    except Exception:
        traceback.print_exc()
        remove_context(args.id)


if __name__ == "__main__":
    main()
