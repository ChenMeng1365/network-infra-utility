#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 配置驱动 SSH 登录脚本 — 从 YAML 配置文件读取连接信息和认证凭据，
# 自动连接设备。有预设命令时先自动执行，然后进入交互模式；
# 无预设命令时直接进入交互模式。
#
# 用法（在项目根目录执行）：
#   ruby example/ssh/config_login_example.rb --config example/ssh/login_config.yml
#   ruby example/ssh/config_login_example.rb -c example/ssh/login_config.yml
#   ruby example/ssh/config_login_example.rb                # 默认读取 example/ssh/login_config.yml
#
# 依赖：Ruby >= 3.0，项目库（service/ssh/lib），Rust 引擎已编译
# 日志：会话输出记录到 .temp/config_login_<timestamp>.log

PROJECT_ROOT = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(PROJECT_ROOT, "service", "ssh", "lib"))
require "network_infra_utility/ssh"
require "base64"
require "time"
require "stringio"
require "fileutils"
require "yaml"
require "optparse"
require "io/console"
require "io/wait"

module NetworkInfraUtility
  module SSH
    # 配置驱动的 SSH 登录客户端
    class ConfigLoginClient
      def initialize(config_path:, log_file:)
        @config_path = config_path
        @log_file = log_file
        @config = nil
        @client = nil
        @session = nil
        @terminal = nil
        @output_queue = Queue.new
        @raw_output = +""
        @running = false
        @old_winch = nil
      end

      def run
        # 0. 加载配置文件
        puts "[0/6] 加载配置文件: #{@config_path}"
        load_config

        puts "      目标:  #{@config['user']}@#{@config['host']}:#{@config['port'] || 22}"
        puts "      认证:  #{@config['auth']['type']}"
        puts "      命令:  #{(@config['commands'] || []).length} 条"
        puts

        # 1. 启动引擎
        puts "[1/6] 启动 Rust 引擎..."
        demo_config_dir = File.join(Dir.tmpdir, "ssh_login_config_#{Process.pid}")
        FileUtils.mkdir_p(demo_config_dir) unless Dir.exist?(demo_config_dir)
        File.write(File.join(demo_config_dir, "settings.yml"),
                   { "master_password" => "config_login_master_pwd" }.to_yaml)

        @client = Client.new(backend: :rust, config_dir: demo_config_dir)
        @client.start_engine
        puts "      引擎已启动 (backend: #{@client.backend})"

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

        # 3. 连接目标设备
        puts "[3/6] 正在连接 #{@config['user']}@#{@config['host']}:#{@config['port'] || 22} ..."
        @session = @client.connect(build_connect_spec)
        puts "      SSH 连接成功 (conn_id: #{@session.conn_id})"

        # 4. 打开终端通道
        puts "[4/6] 打开终端通道..."
        cols, rows = detect_terminal_size
        @terminal = @session.open_terminal(cols: cols, rows: rows)
        puts "      终端通道已打开 (channel_id: #{@terminal.channel_id}, #{cols}x#{rows})"

        # 订阅通道数据推送
        subscribe_channel_data

        # 启动会话日志
        @terminal.start_logging(@log_file)
        puts "      会话日志: #{@log_file}"

        # 5. 等待远程 shell 初始化
        wait_secs = @config["shell_wait"] || 2.0
        puts "[5/6] 等待远程 Shell 初始化 (#{wait_secs}s)..."
        drain_output(wait_secs)

        # 6. 执行预设命令（如果有）
        commands = @config["commands"] || []
        delay = @config["command_delay"] || 1.0

        if commands.any?
          puts "[6/6] 执行预设命令 (共 #{commands.length} 条，间隔 #{delay}s)"
          puts "-" * 60

          commands.each_with_index do |cmd, i|
            puts "\n>>> [#{i + 1}/#{commands.length}] #{cmd}"
            @terminal.puts(cmd)
            drain_output(delay)
          end

          puts "\n" + "-" * 60
          puts "预设命令执行完毕，进入交互模式。"
        else
          puts "[6/6] 无预设命令，直接进入交互模式。"
        end

        # 设置窗口大小变更转发
        setup_winch_handler

        # 进入交互模式
        interactive_mode

        cleanup

      rescue => e
        warn "\n[ERROR] #{e.class}: #{e.message}"
        warn e.backtrace.first(10).join("\n")
        cleanup
      end

      private

      # ── 交互模式：raw 模式下逐字节转发，实时回显远端输出 ──
      def interactive_mode
        puts
        puts "=" * 60
        puts "  交互模式已就绪"
        if $stdin.tty?
          puts "  终端 raw 模式 — 逐字节转发，远端回显"
          puts "  按 Ctrl-] 断开连接（类似 ssh -e）"
        else
          puts "  行模式（非 TTY 环境）— 跳行发送"
          puts "  输入 exit/quit 断开连接"
        end
        puts "  会话日志: #{@log_file}"
        puts "=" * 60
        puts

        @running = true

        # 输出线程：持续监听远端返回的数据并实时显示
        output_thread = Thread.new do
          while @running
            begin
              data = @output_queue.pop(timeout: 0.2)
              break if data.nil?

              $stdout.write(data)
              $stdout.flush
            rescue ThreadError
              # timeout, loop back and re-check @running
            end
          end
        end

        if $stdin.tty?
          raw_mode_loop
        else
          line_mode_loop
        end

        @running = false
        output_thread.join(3)
      end

      # ── raw 模式循环：逐字节读取 → 透传到远端 ──
      def raw_mode_loop
        # 转义字符 Ctrl-] (0x1D)，类似 ssh -e 的默认转义符
        escape_char = "\x1D"

        $stdin.raw do
          while @running
            # 用 IO.select 带超时轮询，避免 readpartial 无限阻塞
            # 当远端断开时 @running 变 false，能在 0.1s 内退出
            ready = IO.select([$stdin], nil, nil, 0.1)
            break unless @running
            next unless ready

            begin
              chunk = $stdin.readpartial(4096)
            rescue EOFError
              break
            end

            break if chunk.nil? || chunk.empty?

            # 检测转义字符 Ctrl-]（断开连接）
            if chunk == escape_char
              break
            end

            # 透传原始字节到远端（不追加 \r，由远端 shell 处理）
            @terminal.send(chunk)
          end
        end
      rescue => e
        warn "\n[WARN] raw 模式异常: #{e.message}"
      ensure
        # $stdin.raw 的 block 形式会自动恢复 cooked 模式
      end

      # ── 行模式循环（非 TTY 环境）：逐行读取 → 发送 ──
      def line_mode_loop
        while @running
          input = $stdin.gets
          break if input.nil?

          cmd = input.chomp
          break if cmd == "exit" || cmd == "quit"

          @terminal.puts(cmd)
          # 轻微等待让远端响应有机会到达
          sleep 0.1
        end
      end

      # ── 检测本地终端尺寸 ──
      def detect_terminal_size
        if $stdout.tty?
          begin
            size = IO.console.winsize
            return [size[1], size[0]] if size && size[0] > 0 && size[1] > 0
          rescue
            # fallback
          end
        end
        [@config["terminal_cols"] || 100, @config["terminal_rows"] || 30]
      end

      # ── SIGWINCH: 本地终端尺寸变更 → 通知远端 ──
      def setup_winch_handler
        return unless $stdout.tty?

        @old_winch = Signal.trap(:WINCH) do
          begin
            cols, rows = detect_terminal_size
            @terminal&.resize(cols, rows)
          rescue
            # ignore resize errors
          end
        end
      rescue ArgumentError
        # 非支持平台（如 Windows），忽略
      end

      # ── 恢复信号处理 ──
      def restore_winch_handler
        Signal.trap(:WINCH, @old_winch) if @old_winch
      rescue
        # ignore
      end

      # ── 加载 YAML 配置 ──
      def load_config
        unless File.exist?(@config_path)
          raise "配置文件不存在: #{@config_path}"
        end

        @config = YAML.safe_load(File.read(@config_path))

        # 必填字段校验
        %w[host user auth].each do |field|
          raise "配置缺少必填字段: #{field}" unless @config[field]
        end

        raise "配置 auth 缺少 type 字段" unless @config["auth"]["type"]

        # 默认值
        @config["port"] ||= 22
        @config["terminal_cols"] ||= 100
        @config["terminal_rows"] ||= 30
        @config["command_delay"] ||= 1.0
        @config["shell_wait"] ||= 2.0
        @config["commands"] ||= []
      end

      # ── 根据 auth.type 构建连接 spec ──
      def build_connect_spec
        auth = @config["auth"]
        spec = {
          host: @config["host"],
          port: @config["port"],
          user: @config["user"]
        }

        # 密钥搜索目录（可选）
        spec[:key_dir] = @config["key_dir"] if @config["key_dir"]

        case auth["type"]
        when "password"
          spec[:auth] = {
            type: "password",
            password: auth["password"]
          }
        when "publickey"
          spec[:auth] = { type: "publickey" }
          spec[:auth][:key_path] = auth["key_path"] if auth["key_path"]
          spec[:auth][:passphrase] = auth["passphrase"] if auth["passphrase"] && !auth["passphrase"].empty?
        when "keyboard_interactive"
          spec[:auth] = { type: "keyboard_interactive" }
          if auth["responses"]
            spec[:auth][:responses] = auth["responses"]
          elsif auth["password"]
            spec[:auth][:password] = auth["password"]
          else
            raise "keyboard_interactive 认证需要 responses 或 password 字段"
          end
        else
          raise "不支持的认证类型: #{auth['type']}"
        end

        spec
      end

      # ── 订阅终端通道数据 ──
      def subscribe_channel_data
        @client.ipc.subscribe("channel.data") do |params|
          next unless params[:id] == @terminal.channel_id

          data = Base64.decode64(params[:data])
          @raw_output << data
          @output_queue << data
        end

        @client.ipc.subscribe("channel.data.batch") do |params|
          (params[:items] || []).each do |item|
            next unless item[:id] == @terminal.channel_id

            data = Base64.decode64(item[:data])
            @raw_output << data
            @output_queue << data
          end
        end

        @client.ipc.subscribe("conn.closed") do |params|
          warn "\n[WARN] 连接被远端关闭: #{params.inspect}"
          @running = false
          @output_queue << nil
        end

        @client.ipc.subscribe("conn.failed") do |params|
          warn "\n[ERROR] 连接失败: #{params.inspect}"
          @running = false
          @output_queue << nil
        end
      end

      # ── 在指定时间内收集并显示输出 ──
      def drain_output(timeout)
        deadline = Time.now + timeout
        loop do
          remaining = deadline - Time.now
          break if remaining <= 0

          data = @output_queue.pop(timeout: remaining)
          break if data.nil?

          clean = data.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")
                      .gsub(/\e\][^\x07]*\x07/, "")
                      .gsub(/\r/, "")
          print clean
        end
      rescue ThreadError
        # Queue#pop 超时
      end

      # ── 清理资源 ──
      def cleanup
        puts "\n[INFO] 正在清理..."
        restore_winch_handler
        @terminal&.stop_logging
        @session&.close_terminal
        @session&.disconnect
        @client&.stop
        puts "[INFO] 已断开连接，引擎已停止。"

        unless @raw_output.empty?
          raw_path = @log_file.sub(/\.log$/, "_raw.log")
          File.binwrite(raw_path, @raw_output)
          puts "[INFO] 原始终端输出: #{raw_path}"

          clean_path = @log_file.sub(/\.log$/, ".clean.txt")
          clean = strip_ansi(@raw_output)
          File.write(clean_path, clean)
          puts "[INFO] 可读纯文本日志: #{clean_path}"
        end
      rescue => e
        warn "[WARN] 清理时出错: #{e.message}"
      end

      # ── 剥离 ANSI 转义序列 ──
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

# 解析命令行参数
config_path = File.join(__dir__, "login_config.yml")
OptionParser.new do |opts|
  opts.banner = "用法: ruby example/ssh/config_login_example.rb [options]"
  opts.on("-c", "--config PATH", "配置文件路径 (默认: example/ssh/login_config.yml)") do |v|
    config_path = v
  end
end.parse!

timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
log_dir = File.join(PROJECT_ROOT, ".temp")
FileUtils.mkdir_p(log_dir) unless Dir.exist?(log_dir)
log_file = File.join(log_dir, "config_login_#{timestamp}.log")

puts "=" * 60
puts "  配置驱动 SSH 登录客户端"
puts "  Ruby (IPC) ↔ Rust Engine ↔ 设备 SSH"
puts "=" * 60
puts

client = NetworkInfraUtility::SSH::ConfigLoginClient.new(
  config_path: config_path,
  log_file: log_file
)
client.run
