#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 非交互式 SSH 演示客户端 — 自动连接 WSL，执行预设命令，记录全部输出
#
# 用法（在项目根目录执行）：
#   ruby example/ssh/auto_demo_example.rb
#
# 依赖：Ruby >= 3.0，项目库（service/ssh/lib），Rust 引擎已编译

PROJECT_ROOT = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(PROJECT_ROOT, "service", "ssh", "lib"))
require "network_infra_utility/ssh"
require "base64"
require "time"
require "stringio"
require "fileutils"
require "yaml"
require "socket"

# ─── WSL 预热 ──────────────────────────────────────────────────
# WSL2 无长驻进程时会自动休眠，导致 IP 不可达。
# 连接前先唤醒 WSL、启动 sshd、等待端口就绪。
module WSLWarmup
  WSL_DISTRO = "Ubuntu-22.04"
  WSL_IP     = "192.168.1.100"  # 替换为你的 WSL IP
  SSH_PORT   = 22

  def self.warmup!
    print "[WARMUP] 唤醒 WSL (#{WSL_DISTRO})... "
    `wsl -d #{WSL_DISTRO} -- echo ok 2>&1`
    print "done\n"

    print "[WARMUP] 启动 sshd... "
    `wsl -d #{WSL_DISTRO} -- sudo service ssh start 2>&1`
    print "done\n"

    print "[WARMUP] 等待 #{WSL_IP}:#{SSH_PORT} 可达... "
    10.times do
      begin
        s = TCPSocket.new(WSL_IP, SSH_PORT)
        s.close
        puts "done"
        return true
      rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
        sleep 1
      end
    end
    warn "FAIL: 端口 #{SSH_PORT} 在 10 秒内未就绪"
    false
  end
end

module NetworkInfraUtility
  module SSH
    class DemoClient
      def initialize(host:, port:, user:, password:, log_file:)
        @host = host
        @port = port
        @user = user
        @password = password
        @log_file = log_file
        @client = nil
        @session = nil
        @terminal = nil
        @output_queue = Queue.new
        @raw_output = +""
      end

      def run
        puts "=" * 60
        puts "  SSH 非交互式演示 — Ruby( IPC ) ↔ Rust Engine ↔ WSL SSH"
        puts "=" * 60
        puts

        # 0. 唤醒 WSL 并启动 sshd
        puts "[0/6] 预热 WSL..."
        unless WSLWarmup.warmup!
          raise "WSL 预热失败，无法连接"
        end

        # 1. 启动引擎
        puts "[1/6] 启动 Rust 引擎..."
        # Vault 需要 master_password（AES-256-GCM 凭据加密）
        # 使用临时配置目录，避免污染用户配置
        demo_config_dir = File.join(Dir.tmpdir, "ssh_demo_config_#{Process.pid}")
        FileUtils.mkdir_p(demo_config_dir) unless Dir.exist?(demo_config_dir)
        settings_path = File.join(demo_config_dir, "settings.yml")
        File.write(settings_path, { "master_password" => "demo_master_pwd_2026" }.to_yaml)

        @client = Client.new(backend: :rust, config_dir: demo_config_dir)
        @client.start_engine
        puts "      引擎已启动 (backend: #{@client.backend})"

        # 设置引擎异常退出回调
        @client.on_engine_exit do |reason|
          warn "\n[ENGINE EXIT] reason=#{reason}"
        end

        # 2. 自动接受主机密钥
        puts "[2/6] 配置主机密钥自动接受..."
        @client.host_key.on_prompt do |host, port, fingerprint|
          puts "      [HOSTKEY] 首次连接 #{host}:#{port}"
          puts "      [HOSTKEY] 指纹: #{fingerprint}"
          puts "      [HOSTKEY] 自动接受"
          :accept
        end

        # 3. 连接 WSL
        puts "[3/6] 正在连接 #{@user}@#{@host}:#{@port} ..."
        @session = @client.connect(
          host: @host,
          port: @port,
          user: @user,
          auth: { type: "password", password: @password }
        )
        puts "      SSH 连接成功 (conn_id: #{@session.conn_id})"

        # 4. 打开终端通道
        puts "[4/6] 打开终端通道..."
        @terminal = @session.open_terminal(cols: 100, rows: 30)
        puts "      终端通道已打开 (channel_id: #{@terminal.channel_id})"

        # 订阅 channel.data 推送，收集输出
        # 注意：Coalesce 已经订阅了 channel.data 并 feed 到 terminal，
        # 但我们也需要订阅来收集原始输出用于显示。
        # 使用 channel_id 过滤本通道的数据。
        @client.ipc.subscribe("channel.data") do |params|
          next unless params[:id] == @terminal.channel_id

          data = Base64.decode64(params[:data])
          @raw_output << data
          @output_queue << data
        end

        # 也订阅 coalesce 批量推送
        @client.ipc.subscribe("channel.data.batch") do |params|
          items = params[:items] || []
          items.each do |item|
            next unless item[:id] == @terminal.channel_id

            data = Base64.decode64(item[:data])
            @raw_output << data
            @output_queue << data
          end
        end

        # 订阅连接状态事件
        @client.ipc.subscribe("conn.closed") do |params|
          puts "\n[WARN] 连接被远端关闭: #{params.inspect}"
          @output_queue << nil  # 哨兵值，通知收集线程结束
        end

        @client.ipc.subscribe("conn.failed") do |params|
          puts "\n[ERROR] 连接失败: #{params.inspect}"
          @output_queue << nil
        end

        # 启动会话日志记录（terminal.logger 会记录 feed 的所有数据）
        @terminal.start_logging(@log_file)
        puts "      会话日志记录到: #{@log_file}"

        # 等待远程 shell 初始化
        puts "[5/6] 等待远程 Shell 初始化..."
        drain_output(2.0)

        puts "[6/6] 执行预设命令序列"
        puts "-" * 60

        commands = [
          "echo '=== SSH Demo Start ==='",
          "whoami",
          "hostname",
          "uname -a",
          "echo '--- Network Info ---'",
          "ip addr show eth0 2>/dev/null || ip addr show ens33 2>/dev/null || echo 'no eth0/ens33'",
          "echo '--- Disk Info ---'",
          "df -h / 2>/dev/null",
          "echo '--- Memory Info ---'",
          "free -h 2>/dev/null || cat /proc/meminfo | head -5",
          "echo '--- Date/Time ---'",
          "date",
          "echo '=== SSH Demo End ==='",
        ]

        commands.each_with_index do |cmd, i|
          puts "\n>>> [#{i + 1}/#{commands.length}] #{cmd}"
          @terminal.puts(cmd)
          drain_output(1.0)
        end

        puts "\n" + "-" * 60
        puts "所有命令执行完毕。"

        cleanup

      rescue => e
        warn "\n[ERROR] #{e.class}: #{e.message}"
        warn e.backtrace.first(10).join("\n")
        cleanup
      end

      private

      # 在指定时间内收集并显示所有到达的输出
      def drain_output(timeout)
        deadline = Time.now + timeout
        loop do
          remaining = deadline - Time.now
          break if remaining <= 0

          data = @output_queue.pop(timeout: remaining)
          break if data.nil?  # 哨兵

          # 清理 ANSI 转义序列用于显示（保留换行）
          clean = data.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")
                       .gsub(/\e\][^\x07]*\x07/, "")
                       .gsub(/\r/, "")
          print clean
        end
      rescue ThreadError
        # Queue#pop timeout 返回 nil 在某些 Ruby 版本中会抛 ThreadError
      end

      def cleanup
        puts "\n[CLEANUP] 正在清理..."
        @terminal&.stop_logging
        @session&.close_terminal
        @session&.disconnect
        @client&.stop
        puts "[CLEANUP] 已断开连接，引擎已停止。"

        # 写入完整原始输出
        unless @raw_output.empty?
          raw_path = @log_file.sub(/\.log$/, "_raw.log")
          File.binwrite(raw_path, @raw_output)
          puts "[CLEANUP] 原始终端输出已记录到: #{raw_path}"

          # 自动清洗 ANSI 转义序列，生成可读纯文本
          clean_path = @log_file.sub(/\.log$/, ".clean.txt")
          clean = strip_ansi(@raw_output)
          File.write(clean_path, clean)
          puts "[CLEANUP] 可读纯文本日志: #{clean_path}"
        end
      rescue => e
        warn "[CLEANUP] 清理时出错: #{e.message}"
      end

      # 剥离 ANSI 转义序列，返回干净文本
      def strip_ansi(data)
        require "strscan"
        scanner = StringScanner.new(data)
        result = +""

        until scanner.eos?
          if scanner.scan(/\e\[[0-9;?]*[a-zA-Z]/)
            nil
          elsif scanner.scan(/\e\][^\x07\e]*(?:\x07|\e\\)/)
            nil
          elsif scanner.scan(/\e./)
            nil
          else
            result << scanner.getch
          end
        end

        result.gsub!(/\r\n/, "\n")
        result.gsub!(/\r/, "")
        result.gsub!(/\n{3,}/, "\n\n")
        result.strip + "\n"
      end
    end
  end
end

# ─── 主入口 ───────────────────────────────────────────────────

timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
log_dir = File.join(PROJECT_ROOT, ".temp")
FileUtils.mkdir_p(log_dir) unless Dir.exist?(log_dir)
log_file = File.join(log_dir, "ssh_session_#{timestamp}.log")

# ── 目标 SSH 服务器（替换为你自己的测试环境）──
HOST     = "192.168.1.100"          # 替换为目标 IP
PORT     = 22
USER     = "your_username"          # 替换为目标用户名
PASSWORD = "your_password"          # 替换为目标密码

puts "目标:  #{USER}@#{HOST}:#{PORT}"
puts "日志:  #{log_file}"
puts

client = NetworkInfraUtility::SSH::DemoClient.new(
  host: HOST,
  port: PORT,
  user: USER,
  password: PASSWORD,
  log_file: log_file
)
client.run
