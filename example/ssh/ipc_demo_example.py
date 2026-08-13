#!/usr/bin/env python3
"""
IPC 测试客户端 — 连接 ssh_core_rs 引擎，演示完整的 SSH 交互流程。

用法：
  python ipc_demo_example.py <endpoint_file> [<host> <port> <user> <password>]

流程：
  1. 读取 endpoint 文件获取 TCP 端口和 auth_token
  2. 建立 TCP 连接
  3. hello 握手认证
  4. conn.connect → 建立 SSH 连接到 WSL sshd
  5. 处理 hostkey.resolve 反向 RPC（自动 accept）
  6. channel.open → 打开 shell 通道（带 PTY）
  7. channel.send → 发送命令（whoami / uname -a / echo / ls /）
  8. 接收 channel.data.batch 推送（coalesce 合并后的输出）
  9. channel.close → 关闭通道
 10. conn.disconnect → 断开 SSH 连接
 11. bye → 关闭 IPC 连接

所有发送和接收的消息都会打印到 stdout，并带有时间戳和方向标记。
"""

import socket
import json
import sys
import os
import time
import base64
import threading
from datetime import datetime


def ts():
    """返回当前时间戳字符串"""
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def log(direction, msg):
    """记录一条消息（direction: >>> 发送, <<< 接收, [!] 事件）"""
    # 紧凑格式化 JSON
    if isinstance(msg, (dict, list)):
        text = json.dumps(msg, ensure_ascii=False, separators=(",", ":"))
    else:
        text = str(msg)
    print(f"[{ts()}] {direction} {text}", flush=True)


def read_endpoint(path):
    """读取 endpoint 文件：第一行 tcp://host:port，第二行 auth_token"""
    with open(path, "r") as f:
        lines = f.read().strip().split("\n")
    addr = lines[0].strip()
    token = lines[1].strip()
    # 解析 tcp://127.0.0.1:12345
    parts = addr.split(":")
    port = int(parts[2])
    return port, token


class IpcClient:
    def __init__(self, port, token):
        self.port = port
        self.token = token
        self.sock = None
        self.recv_buffer = b""
        self.next_id = 1
        # id → (event, method) 用于跟踪请求
        self.pending = {}
        # 反向 RPC 响应
        self.reverse_responses = {}
        self.running = True
        self.lock = threading.Lock()

    def connect(self):
        """建立 TCP 连接"""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.connect(("127.0.0.1", self.port))
        self.sock.settimeout(1)  # short timeout so drain() respects its duration
        print(f"[{ts()}] === TCP connected to 127.0.0.1:{self.port} ===", flush=True)

    def send_msg(self, msg_dict):
        """发送一条 JSON-RPC 消息（追加 \\n 分帧）"""
        data = json.dumps(msg_dict, ensure_ascii=False, separators=(",", ":"))
        log(">>>", msg_dict)
        self.sock.sendall((data + "\n").encode("utf-8"))

    def send_request(self, method, params=None):
        """发送请求并返回分配的 id"""
        rid = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self.send_msg(msg)
        return rid

    def send_response(self, rid, result):
        """发送对反向 RPC 的响应"""
        msg = {"jsonrpc": "2.0", "id": rid, "result": result}
        self.send_msg(msg)

    def recv_messages(self):
        """从 socket 读取，返回完整消息列表（按 \\n 分帧）"""
        msgs = []
        try:
            data = self.sock.recv(65536)
            if not data:
                self.running = False
                return msgs
            self.recv_buffer += data
        except socket.timeout:
            return msgs

        while b"\n" in self.recv_buffer:
            idx = self.recv_buffer.index(b"\n")
            frame = self.recv_buffer[:idx].strip()
            self.recv_buffer = self.recv_buffer[idx + 1 :]
            if frame:
                try:
                    msg = json.loads(frame.decode("utf-8"))
                    msgs.append(msg)
                except json.JSONDecodeError as e:
                    print(f"[{ts()}] [!] JSON decode error: {e}, frame={frame[:200]}", flush=True)
        return msgs

    def handle_message(self, msg):
        """处理一条收到的消息"""
        has_id = "id" in msg
        has_method = "method" in msg

        if has_id and has_method:
            # 反向 RPC 请求（Rust→Ruby），如 hostkey.resolve
            log("<<<", msg)
            method = msg["method"]
            rid = msg["id"]
            params = msg.get("params", {})
            print(f"[{ts()}] [!] Reverse RPC: method={method}, id={rid}, params={json.dumps(params, ensure_ascii=False)}", flush=True)

            if method == "hostkey.resolve":
                # 自动接受所有主机密钥（演示用）
                action = "accept"
                fingerprint = params.get("fingerprint", "unknown")
                print(f"[{ts()}] [!] hostkey.resolve: accepting fingerprint={fingerprint}", flush=True)
                self.send_response(rid, {"action": action, "fingerprint": fingerprint})
            else:
                # 未知的反向 RPC，返回 reject
                self.send_response(rid, {"action": "reject"})

        elif has_id and not has_method:
            # RPC 响应
            log("<<<", msg)
            rid = msg["id"]
            if rid in self.pending:
                del self.pending[rid]
            # 保存响应
            with self.lock:
                self.reverse_responses[rid] = msg
            return msg

        elif not has_id and has_method:
            # 推送通知（notification）
            method = msg.get("method", "")
            params = msg.get("params", {})

            if method == "channel.data.batch":
                # 解析 batch items
                items = params.get("items", [])
                total_bytes = 0
                for item in items:
                    ch_id = item.get("id", "?")
                    b64_data = item.get("data", "")
                    raw = base64.b64decode(b64_data) if b64_data else b""
                    total_bytes += len(raw)
                    # 尝试解码为文本
                    try:
                        text = raw.decode("utf-8")
                        preview = text[:500]
                    except UnicodeDecodeError:
                        preview = f"<binary {len(raw)} bytes>"
                    print(f"[{ts()}] [DATA] channel={ch_id} bytes={len(raw)}", flush=True)
                    print(f"          ┌──────────────────────────────────────────", flush=True)
                    for line in preview.split("\n"):
                        print(f"          │ {line}", flush=True)
                    print(f"          └──────────────────────────────────────────", flush=True)
            elif method == "channel.eof":
                ch_id = params.get("id", "?")
                reason = params.get("reason", "?")
                print(f"[{ts()}] [EOF] channel={ch_id} reason={reason}", flush=True)
            elif method == "channel.extended_data":
                ch_id = params.get("id", "?")
                ext = params.get("ext", "?")
                b64_data = params.get("data", "")
                raw = base64.b64decode(b64_data) if b64_data else b""
                try:
                    text = raw.decode("utf-8")
                except UnicodeDecodeError:
                    text = f"<binary {len(raw)} bytes>"
                print(f"[{ts()}] [STDERR] channel={ch_id} ext={ext}", flush=True)
                print(f"          │ {text[:500]}", flush=True)
            elif method == "conn.ready":
                print(f"[{ts()}] [EVENT] conn.ready: {json.dumps(params, ensure_ascii=False)}", flush=True)
            elif method == "conn.closed":
                print(f"[{ts()}] [EVENT] conn.closed: {json.dumps(params, ensure_ascii=False)}", flush=True)
            elif method == "conn.failed":
                print(f"[{ts()}] [EVENT] conn.failed: {json.dumps(params, ensure_ascii=False)}", flush=True)
            else:
                log("<<<", msg)

        else:
            log("<<<", msg)

    def wait_response(self, rid, timeout=30):
        """等待指定 id 的响应"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if rid in self.reverse_responses:
                    return self.reverse_responses.pop(rid)
            # 读取更多消息
            msgs = self.recv_messages()
            if not msgs:
                time.sleep(0.05)
                continue
            for msg in msgs:
                result = self.handle_message(msg)
                if result and result.get("id") == rid:
                    with self.lock:
                        self.reverse_responses.pop(rid, None)
                    return result
        return None

    def call(self, method, params=None, timeout=30):
        """发送 RPC 请求并等待响应"""
        rid = self.send_request(method, params)
        resp = self.wait_response(rid, timeout)
        if resp is None:
            print(f"[{ts()}] [!] TIMEOUT waiting for response to {method} (id={rid})", flush=True)
            return None
        if "error" in resp:
            print(f"[{ts()}] [!] ERROR response: {resp['error']}", flush=True)
            return resp
        return resp

    def drain(self, duration=2.0):
        """排空接收缓冲区内所有推送消息，持续指定时间"""
        end = time.time() + duration
        while time.time() < end:
            msgs = self.recv_messages()
            if not msgs:
                time.sleep(0.1)
                continue
            for msg in msgs:
                self.handle_message(msg)


def main():
    if len(sys.argv) < 2:
        print("Usage: python ipc_demo_client.py <endpoint_file> [host port user password]")
        sys.exit(1)

    endpoint_file = sys.argv[1]
    host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    port = int(sys.argv[3]) if len(sys.argv) > 3 else 22
    user = sys.argv[4] if len(sys.argv) > 4 else "yui"
    password = sys.argv[5] if len(sys.argv) > 5 else "3d73fdc3"

    print(f"{'='*70}", flush=True)
    print(f"  ssh_core_rs IPC Demo Client", flush=True)
    print(f"  Endpoint file: {endpoint_file}", flush=True)
    print(f"  SSH target: {user}@{host}:{port}", flush=True)
    print(f"  Started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", flush=True)
    print(f"{'='*70}", flush=True)

    # Step 0: 读取 endpoint 文件
    print(f"\n[{ts()}] --- Step 0: Read endpoint file ---", flush=True)
    ipc_port, auth_token = read_endpoint(endpoint_file)
    print(f"[{ts()}] Endpoint: tcp://127.0.0.1:{ipc_port}", flush=True)
    print(f"[{ts()}] Auth token: {auth_token[:16]}...{auth_token[-8:]}", flush=True)

    # Step 1: 建立 TCP 连接
    print(f"\n[{ts()}] --- Step 1: Connect to IPC gateway ---", flush=True)
    client = IpcClient(ipc_port, auth_token)
    client.connect()

    # Step 2: hello 握手
    print(f"\n[{ts()}] --- Step 2: hello handshake ---", flush=True)
    resp = client.call("hello", {"auth_token": auth_token, "ver": "1.0", "client_id": "demo-client"})
    if resp is None or "error" in resp:
        print(f"[{ts()}] [!] hello failed, exiting", flush=True)
        sys.exit(1)
    capabilities = resp.get("result", {}).get("capabilities", [])
    ver = resp.get("result", {}).get("ver", "?")
    print(f"[{ts()}] hello ok: capabilities={capabilities}, ver={ver}", flush=True)

    # Step 3: engine.ping
    print(f"\n[{ts()}] --- Step 3: engine.ping ---", flush=True)
    resp = client.call("engine.ping")
    if resp:
        print(f"[{ts()}] engine.ping result: {json.dumps(resp.get('result', {}), ensure_ascii=False)}", flush=True)

    # Step 4: conn.connect
    print(f"\n[{ts()}] --- Step 4: conn.connect (SSH to {host}:{port}) ---", flush=True)
    resp = client.call("conn.connect", {
        "host": host,
        "port": port,
        "user": user,
        "auth": {
            "type": "password",
            "password": password,
        },
        "connect_timeout_ms": 15000,
    }, timeout=30)

    conn_id = None
    fingerprint = None
    if resp and "result" in resp:
        conn_id = resp["result"].get("conn_id")
        fingerprint = resp["result"].get("fingerprint")
        print(f"[{ts()}] conn.connect ok: conn_id={conn_id}, fingerprint={fingerprint}", flush=True)
    else:
        print(f"[{ts()}] [!] conn.connect failed, exiting", flush=True)
        sys.exit(1)

    # Step 5: conn.list
    print(f"\n[{ts()}] --- Step 5: conn.list ---", flush=True)
    resp = client.call("conn.list")
    if resp:
        print(f"[{ts()}] conn.list result: {json.dumps(resp.get('result', {}), ensure_ascii=False)}", flush=True)

    # Step 6: channel.open (shell with PTY)
    print(f"\n[{ts()}] --- Step 6: channel.open (shell + PTY) ---", flush=True)
    resp = client.call("channel.open", {
        "conn_id": conn_id,
        "type": "shell",
        "cols": 120,
        "rows": 40,
        "term": "xterm-256color",
    }, timeout=15)

    ch_id = None
    if resp and "result" in resp:
        ch_id = resp["result"].get("channel_id")
        print(f"[{ts()}] channel.open ok: channel_id={ch_id}", flush=True)
    else:
        print(f"[{ts()}] [!] channel.open failed, exiting", flush=True)
        sys.exit(1)

    # Step 7: 发送命令并接收输出
    commands = [
        "whoami\n",
        "uname -a\n",
        "echo '--- testing ---'\n",
        "ls /\n",
        "exit\n",
    ]

    for cmd in commands:
        print(f"\n[{ts()}] --- channel.send: {cmd.strip()!r} ---", flush=True)
        b64 = base64.b64encode(cmd.encode("utf-8")).decode("ascii")
        resp = client.call("channel.send", {
            "id": ch_id,
            "data": b64,
        }, timeout=5)
        if resp:
            print(f"[{ts()}] channel.send ok: {json.dumps(resp.get('result', {}), ensure_ascii=False)}", flush=True)

        # 排空推送数据
        client.drain(2.0)

    # Step 8: 等待 channel.eof
    print(f"\n[{ts()}] --- Waiting for channel.eof / conn.closed ---", flush=True)
    client.drain(3.0)

    # Step 9: channel.close (if not already closed)
    print(f"\n[{ts()}] --- Step 9: channel.close ---", flush=True)
    resp = client.call("channel.close", {"id": ch_id}, timeout=5)
    if resp:
        print(f"[{ts()}] channel.close result: {json.dumps(resp.get('result', {}), ensure_ascii=False)}", flush=True)

    # Step 10: conn.disconnect
    print(f"\n[{ts()}] --- Step 10: conn.disconnect ---", flush=True)
    resp = client.call("conn.disconnect", {"id": conn_id}, timeout=10)
    if resp:
        print(f"[{ts()}] conn.disconnect result: {json.dumps(resp.get('result', {}), ensure_ascii=False)}", flush=True)

    # Step 11: engine.stats
    print(f"\n[{ts()}] --- Step 11: engine.stats ---", flush=True)
    resp = client.call("engine.stats")
    if resp:
        print(f"[{ts()}] engine.stats result: {json.dumps(resp.get('result', {}), ensure_ascii=False)}", flush=True)

    # Step 12: bye
    print(f"\n[{ts()}] --- Step 12: bye ---", flush=True)
    resp = client.call("bye")
    if resp:
        print(f"[{ts()}] bye result: {json.dumps(resp.get('result', {}), ensure_ascii=False)}", flush=True)

    # 排空剩余消息
    client.drain(1.0)

    print(f"\n{'='*70}", flush=True)
    print(f"  Demo complete at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", flush=True)
    print(f"{'='*70}", flush=True)

    client.sock.close()


if __name__ == "__main__":
    main()
