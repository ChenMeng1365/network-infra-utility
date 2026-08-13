#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 交互式 SSH 客户端 — 连接 WSL 容器，实时显示终端输出，记录会话日志
#
# 用法（在项目根目录执行）：
#   ruby example/ssh/interactive_session_example.rb
#
# 依赖：Ruby >= 3.0，项目库（service/ssh/lib），Rust 引擎已编译
# 日志：会话输出记录到 .temp/ssh_session_<timestamp>.log

PROJECT_ROOT = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(PROJECT_ROOT, "service", "ssh", "lib"))
require "network_infra_utility/ssh"
require "io/console"
require "base64"
require "time"
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
    # 1. 唤醒 WSL（任意命令即可拉起虚拟机）
    `wsl -d #{WSL_DISTRO} -- echo ok 2>&1`
    print "done\n"

    # 2. 启动 sshd（sudo 免密已配置）
    print "[WARMUP] 启动 sshd... "
    `wsl -d #{WSL_DISTRO} -- sudo service ssh start 2>&1`
    print "done\n"

    # 3. 等待 TCP 端口就绪（最多 10 秒）
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
    class InteractiveClient
      def initialize(host:, port:, user:, password:, log_file:)
        @host = host
        @port = port
        @user = user
        @password = password
        @log_file = log_file
        @client = nil
        @session = nil
        @terminal = nil
        @running = false
        @raw_output = +""
      end

      def run
        puts "=" * 60
        puts "  交互式 SSH 客户端"
        puts "  Ruby (IPC) ↔ Rust Engine ↔ WSL SSH"
        puts "=" * 60
        puts

        # 0. 唤醒 WSL 并启动 sshd
        puts "[0/5] 预热 WSL..."
        unless WSLWarmup.warmup!
          raise "WSL 预热失败，无法连接"
        end

        # 1. 启动引擎（临时配置目录，避免污染用户配置）
        puts "[1/5] 启动 Rust 引擎..."
        demo_config_dir = File.join(Dir.tmpdir, "ssh_demo_config_#{Process.pid}")
        FileUtils.mkdir_p(demo_config_dir) unless Dir.exist?(demo_config_dir)
        File.write(File.join(demo_config_dir, "settings.yml"),
                   { "master_password" => "demo_master_pwd_2026" }.to_yaml)

        @client = Client.new(backend: :rust, config_dir: demo_config_dir)
        @client.start_engine
        puts "      引擎已启动 (backend: #{@client.backend})"

        # 引擎异常退出回调
        @client.on_engine_exit do |reason|
          warn "\n[ENGINE EXIT] reason=#{reason}"
          @running = false
        end

        # 2. 自动接受未知主机密钥
        puts "[2/5] 配置主机密钥..."
        @client.host_key.on_prompt do |host, port, fingerprint|
          puts "      [HOSTKEY] 首次连接 #{host}:#{port}"
          puts "      [HOSTKEY] 指纹: #{fingerprint}"
          puts "      [HOSTKEY] 自动接受"
          :accept
        end

        # 3. 连接 WSL
        puts "[3/5] 正在连接 #{@user}@#{@host}:#{@port} ..."
        @session = @client.connect(
          host: @host,
          port: @port,
          user: @user,
          auth: { type: "password", password: @password }
        )
        puts "      SSH 连接成功 (conn_id: #{@session.conn_id})"

        # 4. 打开终端通道
        puts "[4/5] 打开终端通道..."
        @terminal = @session.open_terminal(cols: 100, rows: 30)
        puts "      终端通道已打开 (channel_id: #{@terminal.channel_id})"

        # 订阅 channel.data 推送，实时显示输出
        @client.ipc.subscribe("channel.data") do |params|
          next unless params[:id] == @terminal.channel_id

          data = Base64.decode64(params[:data])
          @raw_output << data
          $stdout.write(data)
          $stdout.flush
        end

        # 也订阅 coalesce 批量推送
        @client.ipc.subscribe("channel.data.batch") do |params|
          (params[:items] || []).each do |item|
            next unless item[:id] == @terminal.channel_id

            data = Base64.decode64(item[:data])
            @raw_output << data
            $stdout.write(data)
            $stdout.flush
          end
        end

        # 订阅连接状态事件
        @client.ipc.subscribe("conn.closed") do |params|
          puts "\n[WARN] 连接被远端关闭: #{params.inspect}"
          @running = false
        end

        @client.ipc.subscribe("conn.failed") do |params|
          puts "\n[ERROR] 连接失败: #{params.inspect}"
          @running = false
        end

        # 启动会话日志记录
        @terminal.start_logging(@log_file)

        # 等待远程 shell 初始化输出
        sleep 1.5

        # 5. 交互循环
        puts "[5/5] 会话就绪"
        puts "-" * 60
        puts "连接已建立，输入命令与远程主机交互。"
        puts "exit/quit 由远程 shell 逐层退出，退到最外层再敲 exit 断开 SSH。"
        puts "会话日志: #{@log_file}"
        puts "-" * 60
        puts

        @running = true
        interactive_loop

      rescue => e
        warn "\n[ERROR] #{e.class}: #{e.message}"
        warn e.backtrace.first(5).join("\n")
      ensure
        cleanup
      end

      private

      def interactive_loop
        while @running
          input = $stdin.gets
          break if input.nil?

          cmd = input.chomp

          if cmd == "exit" || cmd == "quit"
            if @exit_pending
              # 连续第二次 exit，真正断开
              break
            else
              # 第一次 exit：发给远程 shell，等待响应后提示
              @terminal.puts(cmd)
              sleep 0.5
              print "\n[press exit to exit] "; $stdout.flush
              @exit_pending = true
              next
            end
          end

          @exit_pending = false if @exit_pending && cmd != ""
          @terminal.puts(cmd)
          sleep 0.3
        end
      end

      def cleanup
        puts "\n[INFO] 正在清理..."
        @terminal&.stop_logging
        @session&.close_terminal
        @session&.disconnect
        @client&.stop
        puts "[INFO] 已断开连接，引擎已停止。"

        # 写入完整原始输出
        unless @raw_output.empty?
          raw_path = @log_file.sub(/\.log$/, "_raw.log")
          File.binwrite(raw_path, @raw_output)
          puts "[INFO] 原始终端输出已记录到: #{raw_path}"

          # 自动清洗 ANSI 转义序列，生成可读纯文本
          clean_path = @log_file.sub(/\.log$/, ".clean.txt")
          clean = strip_ansi(@raw_output)
          File.write(clean_path, clean)
          puts "[INFO] 可读纯文本日志: #{clean_path}"
        end
      rescue => e
        warn "[WARN] 清理时出错: #{e.message}"
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

client = NetworkInfraUtility::SSH::InteractiveClient.new(
  host: HOST,
  port: PORT,
  user: USER,
  password: PASSWORD,
  log_file: log_file
)
client.run
