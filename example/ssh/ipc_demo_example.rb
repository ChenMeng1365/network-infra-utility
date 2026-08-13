#!/usr/bin/env ruby
# frozen_string_literal: true
#
# IPC Demo Client (Ruby) — 连接 ssh_core_rs 引擎，演示完整 SSH 交互流程
#
# 用法：
#   ruby ipc_demo_example.rb <endpoint_file> [host port user password]
#
# 零第三方 gem 依赖，仅使用标准库 (socket, json, base64, thread)
#
# 流程：
#   1. 读取 endpoint 文件获取 TCP 端口和 auth_token
#   2. 建立 TCP 连接
#   3. hello 握手认证
#   4. conn.connect → 建立 SSH 连接到 WSL sshd
#   5. 处理 hostkey.resolve 反向 RPC（自动 accept）
#   6. channel.open → 打开 shell 通道（带 PTY）
#   7. channel.send → 发送命令（whoami / uname -a / echo / ls / exit）
#   8. 接收 channel.data.batch 推送（coalesce 合并后的输出）
#   9. channel.close → 关闭通道
#  10. conn.disconnect → 断开 SSH 连接
#  11. engine.stats
#  12. bye → 关闭 IPC 连接

require "socket"
require "json"
require "base64"
require "time"
require "thread"

# ── helpers ──────────────────────────────────────────────────────────

def ts
  Time.now.strftime("%H:%M:%S.") + format("%03d", (Time.now.usec / 1000.0).floor)
end

def log(direction, obj)
  text = obj.is_a?(String) ? obj : JSON.generate(obj)
  puts "[#{ts}] #{direction} #{text}"
  STDOUT.flush
end

def read_endpoint(path)
  lines = File.read(path, encoding: "utf-8").strip.split("\n")
  addr = lines[0].strip
  token = lines[1].strip
  # tcp://127.0.0.1:12345
  port = addr.split(":").last.to_i
  [port, token]
end

def safe_decode(data, encoding = "UTF-8")
  data.force_encoding(encoding).encode("UTF-8", invalid: :replace, undef: :replace)
rescue StandardError
  "<binary #{data.bytesize} bytes>"
end

# ── IPC Client ───────────────────────────────────────────────────────

class IpcClient
  attr_reader :port, :token

  def initialize(port, token)
    @port = port
    @token = token
    @sock = nil
    @recv_buffer = +""
    @next_id = 1
    @pending = {}            # id => true (跟踪待响应请求)
    @responses = {}          # id => parsed JSON hash
    @mutex = Mutex.new
    @running = true
  end

  def connect
    @sock = TCPSocket.new("127.0.0.1", @port)
    @sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    puts "[#{ts}] === TCP connected to 127.0.0.1:#{@port} ==="
    STDOUT.flush
  end

  # ── 发送 ──

  def send_msg(hash)
    log(">>>", hash)
    @sock.write(JSON.generate(hash) + "\n")
  end

  def send_request(method, params = nil)
    rid = @next_id
    @next_id += 1
    msg = { "jsonrpc" => "2.0", "id" => rid, "method" => method }
    msg["params"] = params if params
    send_msg(msg)
    rid
  end

  def send_response(rid, result)
    send_msg("jsonrpc" => "2.0", "id" => rid, "result" => result)
  end

  # ── 接收 ──

  # 从 socket 读取并分帧，返回完整 JSON 消息数组
  # 用 IO.select 等待数据到达（最多 wait_sec 秒），唤醒后循环读空缓冲区
  def recv_messages(wait_sec = 0.5)
    msgs = []
    begin
      readable = IO.select([@sock], nil, nil, wait_sec)
      return msgs unless readable

      # IO.select 返回后，循环 read_nonblock 直到 :wait_readable
      loop do
        chunk = @sock.read_nonblock(65536, exception: false)
        case chunk
        when :wait_readable
          break
        when nil              # EOF
          @running = false
          break
        else
          @recv_buffer << chunk
        end
      end
    rescue IO::WaitReadable
      # nothing
    rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
      @running = false
    end

    while (idx = @recv_buffer.index("\n"))
      frame = @recv_buffer[0...idx].strip
      @recv_buffer = @recv_buffer[(idx + 1)..] || +""
      next if frame.empty?

      begin
        msgs << JSON.parse(frame)
      rescue JSON::ParserError => e
        puts "[#{ts}] [!] JSON decode error: #{e.message}, frame=#{frame[0, 200]}"
        STDOUT.flush
      end
    end
    msgs
  end

  # ── 消息分发 ──

  def handle_message(msg)
    has_id = msg.key?("id")
    has_method = msg.key?("method")

    if has_id && has_method
      # 反向 RPC 请求（Rust→客户端），如 hostkey.resolve
      log("<<<", msg)
      method = msg["method"]
      rid = msg["id"]
      params = msg["params"] || {}
      puts "[#{ts}] [!] Reverse RPC: method=#{method}, id=#{rid}, params=#{JSON.generate(params)}"
      STDOUT.flush

      case method
      when "hostkey.resolve"
        fingerprint = params["fingerprint"] || "unknown"
        puts "[#{ts}] [!] hostkey.resolve: accepting fingerprint=#{fingerprint}"
        STDOUT.flush
        send_response(rid, "action" => "accept", "fingerprint" => fingerprint)
      else
        send_response(rid, "action" => "reject")
      end

    elsif has_id && !has_method
      # RPC 响应
      log("<<<", msg)
      rid = msg["id"]
      @mutex.synchronize { @pending.delete(rid) }
      @mutex.synchronize { @responses[rid] = msg }
      msg

    elsif !has_id && has_method
      # 推送通知（notification）
      handle_notification(msg["method"], msg["params"] || {})
    else
      log("<<<", msg)
    end
  end

  def handle_notification(method, params)
    case method
    when "channel.data.batch"
      items = params["items"] || []
      items.each do |item|
        ch_id = item["id"] || "?"
        b64 = item["data"] || ""
        raw = b64.empty? ? "" : Base64.strict_decode64(b64)
        text = safe_decode(raw.dup)
        preview = text[0, 500]
        puts "[#{ts}] [DATA] channel=#{ch_id} bytes=#{raw.bytesize}"
        puts "          \u250C\u2500" * 1 + "\u2500" * 40
        preview.split("\n").each { |line| puts "          \u2502 #{line}" }
        puts "          \u2514\u2500" * 1 + "\u2500" * 40
        STDOUT.flush
      end

    when "channel.eof"
      ch_id = params["id"] || "?"
      reason = params["reason"] || "?"
      puts "[#{ts}] [EOF] channel=#{ch_id} reason=#{reason}"
      STDOUT.flush

    when "channel.extended_data"
      ch_id = params["id"] || "?"
      ext = params["ext"] || "?"
      b64 = params["data"] || ""
      raw = b64.empty? ? "" : Base64.strict_decode64(b64)
      text = safe_decode(raw.dup)
      puts "[#{ts}] [STDERR] channel=#{ch_id} ext=#{ext}"
      puts "          \u2502 #{text[0, 500]}"
      STDOUT.flush

    when "conn.ready"
      puts "[#{ts}] [EVENT] conn.ready: #{JSON.generate(params)}"
      STDOUT.flush

    when "conn.closed"
      puts "[#{ts}] [EVENT] conn.closed: #{JSON.generate(params)}"
      STDOUT.flush

    when "conn.failed"
      puts "[#{ts}] [EVENT] conn.failed: #{JSON.generate(params)}"
      STDOUT.flush

    else
      log("<<<", "method" => method, "params" => params)
    end
  end

  # ── 等待 / 调用 ──

  def wait_response(rid, timeout = 30)
    deadline = Time.now + timeout
    while Time.now < deadline
      @mutex.synchronize { return @responses.delete(rid) if @responses.key?(rid) }

      remaining = deadline - Time.now
      wait_sec = remaining < 0.5 ? remaining : 0.5
      wait_sec = 0 if wait_sec < 0
      msgs = recv_messages(wait_sec)
      next if msgs.empty?

      found = nil
      msgs.each do |msg|
        result = handle_message(msg)
        found = result if result&.is_a?(Hash) && result["id"] == rid
      end
      return found if found
    end
    nil
  end

  def call(method, params = nil, timeout: 30)
    rid = send_request(method, params)
    resp = wait_response(rid, timeout)
    if resp.nil?
      puts "[#{ts}] [!] TIMEOUT waiting for response to #{method} (id=#{rid})"
      STDOUT.flush
      return nil
    end
    if resp.key?("error")
      puts "[#{ts}] [!] ERROR response: #{resp['error']}"
      STDOUT.flush
    end
    resp
  end

  # 排空推送消息，持续 duration 秒
  def drain(duration = 2.0)
    end_time = Time.now + duration
    while Time.now < end_time
      remaining = end_time - Time.now
      wait_sec = remaining < 0.5 ? remaining : 0.5
      wait_sec = 0 if wait_sec < 0
      msgs = recv_messages(wait_sec)
      next if msgs.empty?
      msgs.each { |msg| handle_message(msg) }
    end
  end

  def close
    @sock&.close
    @sock = nil
  end
end

# ── main ─────────────────────────────────────────────────────────────

def main
  if ARGV.empty?
    warn "Usage: ruby ipc_demo_client.rb <endpoint_file> [host port user password]"
    exit 1
  end

  endpoint_file = ARGV[0]
  host = ARGV[1] || "127.0.0.1"
  port = (ARGV[2] || 22).to_i
  user = ARGV[3] || "yui"
  password = ARGV[4] || "3d73fdc3"

  puts "=" * 70
  puts "  ssh_core_rs IPC Demo Client (Ruby)"
  puts "  Endpoint file: #{endpoint_file}"
  puts "  SSH target: #{user}@#{host}:#{port}"
  puts "  Started at: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
  puts "=" * 70
  STDOUT.flush

  # Step 0: 读取 endpoint 文件
  puts "\n[#{ts}] --- Step 0: Read endpoint file ---"
  STDOUT.flush
  ipc_port, auth_token = read_endpoint(endpoint_file)
  puts "[#{ts}] Endpoint: tcp://127.0.0.1:#{ipc_port}"
  puts "[#{ts}] Auth token: #{auth_token[0, 16]}...#{auth_token[-8, 8]}"
  STDOUT.flush

  # Step 1: 建立 TCP 连接
  puts "\n[#{ts}] --- Step 1: Connect to IPC gateway ---"
  STDOUT.flush
  client = IpcClient.new(ipc_port, auth_token)
  client.connect

  # Step 2: hello 握手
  puts "\n[#{ts}] --- Step 2: hello handshake ---"
  STDOUT.flush
  resp = client.call("hello", { "auth_token" => auth_token, "ver" => "1.0", "client_id" => "demo-client" })
  if resp.nil? || resp.key?("error")
    puts "[#{ts}] [!] hello failed, exiting"
    exit 1
  end
  result = resp["result"] || {}
  capabilities = result["capabilities"] || []
  ver = result["ver"] || "?"
  puts "[#{ts}] hello ok: capabilities=#{capabilities}, ver=#{ver}"
  STDOUT.flush

  # Step 3: engine.ping
  puts "\n[#{ts}] --- Step 3: engine.ping ---"
  STDOUT.flush
  resp = client.call("engine.ping")
  if resp
    puts "[#{ts}] engine.ping result: #{JSON.generate(resp['result'] || {})}"
    STDOUT.flush
  end

  # Step 4: conn.connect
  puts "\n[#{ts}] --- Step 4: conn.connect (SSH to #{host}:#{port}) ---"
  STDOUT.flush
  resp = client.call("conn.connect", {
    "host" => host,
    "port" => port,
    "user" => user,
    "auth" => {
      "type" => "password",
      "password" => password
    },
    "connect_timeout_ms" => 15000
  }, timeout: 30)

  conn_id = nil
  fingerprint = nil
  if resp && resp.key?("result")
    conn_id = resp["result"]["conn_id"]
    fingerprint = resp["result"]["fingerprint"]
    puts "[#{ts}] conn.connect ok: conn_id=#{conn_id}, fingerprint=#{fingerprint}"
  else
    puts "[#{ts}] [!] conn.connect failed, exiting"
    exit 1
  end
  STDOUT.flush

  # Step 5: conn.list
  puts "\n[#{ts}] --- Step 5: conn.list ---"
  STDOUT.flush
  resp = client.call("conn.list")
  if resp
    puts "[#{ts}] conn.list result: #{JSON.generate(resp['result'] || {})}"
    STDOUT.flush
  end

  # Step 6: channel.open (shell with PTY)
  puts "\n[#{ts}] --- Step 6: channel.open (shell + PTY) ---"
  STDOUT.flush
  resp = client.call("channel.open", {
    "conn_id" => conn_id,
    "type" => "shell",
    "cols" => 120,
    "rows" => 40,
    "term" => "xterm-256color"
  }, timeout: 15)

  ch_id = nil
  if resp && resp.key?("result")
    ch_id = resp["result"]["channel_id"]
    puts "[#{ts}] channel.open ok: channel_id=#{ch_id}"
  else
    puts "[#{ts}] [!] channel.open failed, exiting"
    exit 1
  end
  STDOUT.flush

  # Step 7: 发送命令并接收输出
  commands = [
    "whoami\n",
    "uname -a\n",
    "echo '--- testing ---'\n",
    "ls /\n",
    "exit\n"
  ]

  commands.each do |cmd|
    puts "\n[#{ts}] --- channel.send: #{cmd.strip.inspect} ---"
    STDOUT.flush
    b64 = Base64.strict_encode64(cmd.encode("utf-8"))
    resp = client.call("channel.send", { "id" => ch_id, "data" => b64 }, timeout: 5)
    if resp
      puts "[#{ts}] channel.send ok: #{JSON.generate(resp['result'] || {})}"
      STDOUT.flush
    end

    # 排空推送数据
    client.drain(2.0)
  end

  # Step 8: 等待 channel.eof
  puts "\n[#{ts}] --- Waiting for channel.eof / conn.closed ---"
  STDOUT.flush
  client.drain(3.0)

  # Step 9: channel.close
  puts "\n[#{ts}] --- Step 9: channel.close ---"
  STDOUT.flush
  resp = client.call("channel.close", { "id" => ch_id }, timeout: 5)
  if resp
    puts "[#{ts}] channel.close result: #{JSON.generate(resp['result'] || {})}"
    STDOUT.flush
  end

  # Step 10: conn.disconnect
  puts "\n[#{ts}] --- Step 10: conn.disconnect ---"
  STDOUT.flush
  resp = client.call("conn.disconnect", { "id" => conn_id }, timeout: 10)
  if resp
    puts "[#{ts}] conn.disconnect result: #{JSON.generate(resp['result'] || {})}"
    STDOUT.flush
  end

  # Step 11: engine.stats
  puts "\n[#{ts}] --- Step 11: engine.stats ---"
  STDOUT.flush
  resp = client.call("engine.stats")
  if resp
    puts "[#{ts}] engine.stats result: #{JSON.generate(resp['result'] || {})}"
    STDOUT.flush
  end

  # Step 12: bye
  puts "\n[#{ts}] --- Step 12: bye ---"
  STDOUT.flush
  resp = client.call("bye")
  if resp
    puts "[#{ts}] bye result: #{JSON.generate(resp['result'] || {})}"
    STDOUT.flush
  end

  # 排空剩余消息
  client.drain(1.0)

  puts "\n" + ("=" * 70)
  puts "  Demo complete at: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
  puts "=" * 70
  STDOUT.flush

  client.close
end

main
