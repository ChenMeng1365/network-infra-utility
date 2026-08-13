# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "timeout"

require_relative "ipc/transport"
require_relative "ipc/router"
require_relative "ipc/coalesce"
require_relative "ipc/errors"
require_relative "session/manager"
require_relative "security/vault"
require_relative "security/host_key"
require_relative "config/settings"
require_relative "config/schema"
require_relative "config/store"

module NetworkInfraUtility
  module SSH
    # SSH 客户端主入口：管理引擎生命周期与模块协调。
    #
    # 用法：
    #   client = SSH::Client.new
    #   client.start_engine
    #   session = client.connect(host: "10.0.0.1", user: "admin")
    #   terminal = session.open_terminal
    #   terminal.puts("show version")
    class Client
      PROTOCOL_VER = "1.0"
      ENGINE_STARTUP_TIMEOUT = 10 # 秒
      # 默认引擎后端：:rust 或 :erlang
      DEFAULT_BACKEND = :rust
      # 引擎进程退出检测轮询间隔（秒）
      ENGINE_WATCH_INTERVAL = 2

      attr_reader :ipc, :sessions, :vault, :settings, :coalesce, :host_key, :backend

      def initialize(config_dir: nil, backend: nil)
        @settings = Config::Settings.new(config_dir)
        @vault = Security::Vault.new(@settings.master_password)
        @host_key = Security::HostKey.new(@settings.known_hosts_path)
        @ipc = IPC::Router.new(IPC::Transport.new)
        @sessions = Session::Manager.new(self)
        @coalesce = nil
        @engine_pid = nil
        @engine_mutex = Mutex.new
        @started = false
        @backend = backend || DEFAULT_BACKEND
        @engine_watcher = nil
        @exit_callback = nil
      end

      # 设置引擎异常退出回调
      # 回调签名: ->(reason) { }
      # reason 为 :crashed（非零退出）或 :disconnected（IPC 连接断开）
      def on_engine_exit(&block)
        @exit_callback = block
      end

      # 启动 SSH 核心引擎，建立 IPC 连接。
      def start_engine
        @engine_mutex.synchronize do
          raise "Engine already started" if @started

          @engine_pid = spawn_engine
          # 分离子进程但仍可 wait——Process.detach 返回一个线程，
          # 如果子进程异常退出，线程能捕获退出码
          @engine_watcher = Process.detach(@engine_pid)
          endpoint, token = wait_for_endpoint
          @ipc.connect(endpoint, auth_token: token, client_id: "ruby-#{Process.pid}")

          # 注册 IPC 断连回调
          @ipc.on_disconnect do |reason|
            handle_engine_disconnect(reason)
          end

          # 注册反向 RPC：hostkey.resolve
          register_reverse_handlers

          # 初始化 coalesce（需在 hello 之后，获取服务端 capabilities）
          @coalesce = IPC::Coalesce.new(@ipc)
          @started = true

          # 启动引擎退出监控线程
          start_engine_monitor
        end
        self
      end

      # 发起 SSH 连接
      # @param spec [Hash] 连接参数 {host, port, user, auth, jumps, ...}
      # @return [Session::Session] 会话对象
      def connect(spec)
        ensure_started
        # Vault 解析凭据引用，返回新 hash（不改入参）
        resolved_spec = @vault.resolve_credentials(spec)
        conn_resp = @ipc.call("conn.connect", resolved_spec, timeout_ms: 60_000)
        @sessions.create(conn_resp[:conn_id], spec, conn_resp[:fingerprint])
      rescue IPC::RPCError => e
        raise ConnectionError, e.message
      end

      # 停止引擎，清理资源
      def stop
        @engine_mutex.synchronize do
          return unless @started

          @engine_monitor&.kill
          @engine_monitor = nil
          @sessions.disconnect_all
          @ipc.call("bye", {}, timeout_ms: 5_000) rescue nil
          @ipc.close
          if @engine_pid
            begin
              Process.kill("TERM", @engine_pid)
              # 等待最多 3 秒让引擎优雅退出
              Timeout.timeout(3) { @engine_watcher&.join } if @engine_watcher
            rescue => e
              # 引擎可能已退出，忽略
            rescue Timeout::Error
              # 强制杀死
              Process.kill("KILL", @engine_pid) rescue nil
            end
          end
          @engine_pid = nil
          @engine_watcher = nil
          @started = false
        end
      end

      # 引擎是否已启动
      def started?
        @started
      end

      private

      def ensure_started
        start_engine unless @started
      end

      # 引擎是否存活
      def engine_alive?
        return false unless @engine_pid
        # Process.detach 返回的线程，如果已结束说明子进程已退出
        return false if @engine_watcher&.join(0)
        true
      end

      # 启动引擎退出监控线程
      def start_engine_monitor
        @engine_monitor = Thread.new do
          loop do
            sleep ENGINE_WATCH_INTERVAL
            # 检查子进程是否已退出
            if @engine_watcher&.join(0)
              exit_status = @engine_watcher.value rescue nil
              reason = if exit_status && exit_status != 0
                         :crashed
                       else
                         :exited
                       end
              handle_engine_exit(reason)
              break
            end
          end
        rescue => e
          # 监控线程异常，不中断主流程
        end
      end

      # 引擎异常退出时的处理
      def handle_engine_exit(reason)
        @started = false
        @sessions.disconnect_all
        @exit_callback&.call(reason)
      end

      # IPC 连接断开时的处理
      def handle_engine_disconnect(reason)
        @started = false
        @sessions.mark_all_disconnected
        @exit_callback&.call(:disconnected)
      end

      # ----------------------------------------------------------------
      # 以下为 private 方法（增强版修复后保留，旧版重复定义已移除）
      # ----------------------------------------------------------------

      private

      def ensure_started
        start_engine unless @started
      end

      # 拉起 Erlang 引擎子进程
      def spawn_engine
        binary = engine_binary_path
        raise "Engine binary not found: #{binary}" unless File.exist?(binary)

        log_dir = @settings.log_dir
        FileUtils.mkdir_p(log_dir)
        if Gem.win_platform?
          # Windows: .cmd files must be invoked via cmd.exe
          Process.spawn(
            "cmd", "/c", binary,
            { out: File.join(log_dir, "engine.log"),
              err: File.join(log_dir, "engine.err") }
          )
        else
          Process.spawn(
            binary,
            { out: File.join(log_dir, "engine.log"),
              err: File.join(log_dir, "engine.err") }
          )
        end
      end

      # 等待 Erlang 引擎写入端点文件
      def wait_for_endpoint
        endpoint_file = @settings.engine_endpoint_file
        deadline = Time.now + ENGINE_STARTUP_TIMEOUT
        loop do
          if File.exist?(endpoint_file)
            content = File.read(endpoint_file).strip.split("\n")
            return content[0], content[1]
          end
          raise "Erlang engine startup timeout" if Time.now > deadline

          sleep 0.1
        end
      end

      # 注册反向 RPC 处理器
      def register_reverse_handlers
        @ipc.on_reverse_rpc("hostkey.resolve") do |params|
          @host_key.resolve(params[:host], params[:port], params[:fingerprint])
        end
      end

      def engine_binary_path
        ext_dir = File.expand_path("../../../ext", __dir__)
        base = case @backend
               when :rust
                 File.join(ext_dir, "ssh_core_rs", "bin", "ssh_core_rs")
               else
                 File.join(ext_dir, "ssh_core", "bin", "ssh_core")
               end
        Gem.win_platform? ? base + ".cmd" : base
      end
    end

    class ConnectionError < StandardError; end
    class AlreadyStarted < StandardError; end
  end
end
