# frozen_string_literal: true

require "yaml"
require "base64"
require "openssl"
require "thread"
require "fileutils"
require "time"

module NetworkInfraUtility
  module SSH
    module Security
      # known_hosts 落盘 + 主机密钥裁决。
      # 对应需求 FR-SEC-002。
      #
      # LLD E7 勘误修正：
      #   Erlang 负责校验（OTP ssh 的 key_cb），
      #   持久化由 Ruby 经 IPC 提供，Erlang 不落盘 known_hosts。
      #
      # 三条裁决路径（LLD §7.8）：
      #   1. 未知主机 → prompt_user → accept 则存盘且返回 accept；reject 不存盘
      #   2. 已存在且指纹匹配 → 直接 accept（无交互）
      #   3. 已存在但指纹变更 → warn_host_key_changed + reject（无交互）
      #
      # IPC 双向变体：
      #   hostkey.resolve 是 Erlang→Ruby 的同步请求（带 id），
      #   Ruby 必须回一个同 id 的 result。
      #   Erlang 侧 30s 超时后自动 reject。
      class HostKey
        # known_hosts.yml 记录格式：
        #   <host>:<port>:
        #     fingerprint: <SHA-256 base64>
        #     added_at: <ISO8601>

        RESOLVE_TIMEOUT = 30 # 秒，与 Erlang 侧一致

        attr_reader :store_path, :entries

        # @param store_path [String] known_hosts.yml 路径
        def initialize(store_path)
          @store_path = store_path
          @entries = load
          @save_mutex = Mutex.new
          @prompt_callback = nil
        end

        # 设置用户交互回调（V1.0 默认 STDIN，V2.0 TUI 弹窗）
        # 回调签名: ->(host, port, fingerprint) { :accept | :reject | :once }
        # 注意：:once 仅由回调模式返回，CLI 默认模式（prompt_user）不支持 :once
        def on_prompt(&block)
          @prompt_callback = block
        end

        # 设置主机密钥变更告警回调
        # 回调签名: ->(host, port, old_fp, new_fp) { }
        def on_key_changed(&block)
          @changed_callback = block
        end

        # 由 IPC 推送 hostkey.resolve 触发（LLD §7.8）
        # @param host [String]
        # @param port [Integer]
        # @param fingerprint [String] SHA-256 base64 指纹
        # @return [Hash] { action: "accept" | "reject" | "once" }
        def resolve(host, port, fingerprint)
          key = entry_key(host, port)

          if @entries[key].nil?
            # 路径1：未知主机
            action = prompt_user(host, port, fingerprint)
            if action == :accept || action == :once
              @save_mutex.synchronize do
                @entries[key] = {
                  "fingerprint" => fingerprint,
                  "added_at" => Time.now.iso8601
                }
                save
              end
            end
            { action: action.to_s }
          elsif @entries[key]["fingerprint"] == fingerprint
            # 路径2：指纹匹配
            { action: "accept" }
          else
            # 路径3：指纹变更
            warn_host_key_changed(host, port, @entries[key]["fingerprint"], fingerprint)
            { action: "reject" }
          end
        end

        # 手动添加信任条目
        # @param host [String]
        # @param port [Integer]
        # @param fingerprint [String]
        def add(host, port, fingerprint)
          key = entry_key(host, port)
          @save_mutex.synchronize do
            @entries[key] = {
              "fingerprint" => fingerprint,
              "added_at" => Time.now.iso8601
            }
            save
          end
        end

        # 删除信任条目
        # @param host [String]
        # @param port [Integer]
        def remove(host, port)
          key = entry_key(host, port)
          @save_mutex.synchronize do
            @entries.delete(key)
            save
          end
        end

        # 查询条目
        # @param host [String]
        # @param port [Integer]
        # @return [Hash, nil]
        def get(host, port)
          @entries[entry_key(host, port)]
        end

        # 列出全部条目
        # @return [Array<Hash>]
        def list
          @entries.map do |key, val|
            host, port = parse_entry_key(key)
            { host: host, port: port, **val }
          end
        end

        private

        # 生成 known_hosts 条目 key
        def entry_key(host, port)
          "#{host}:#{port}"
        end

        def parse_entry_key(key)
          # 从右侧按第一个冒号分割（host:port）
          # IPv6 地址含多个冒号，但我们暂不支持 IPv6
          idx = key.rindex(":")
          if idx
            host = key[0...idx]
            port = key[(idx + 1)..].to_i
            port = 22 if port == 0
            [host, port]
          else
            [key, 22]
          end
        end

        # V1.0 CLI：通过 STDIN 询问用户；V2.0 TUI 弹窗，超时 30s 默认 reject
        def prompt_user(host, port, fingerprint)
          if @prompt_callback
            result = @prompt_callback.call(host, port, fingerprint)
            return result == :accept ? :accept : (result == :once ? :once : :reject)
          end

          # 默认 CLI 交互
          puts "首次连接 #{host}:#{port}，指纹 #{fingerprint}，是否信任？(y/N)"
          line = STDIN.gets&.chomp
          line =~ /^y/i ? :accept : :reject
        end

        def warn_host_key_changed(host, port, old_fp, new_fp)
          if @changed_callback
            @changed_callback.call(host, port, old_fp, new_fp)
          else
            warn "警告：主机 #{host}:#{port} 的密钥指纹已变更！"
            warn "  旧指纹: #{old_fp}"
            warn "  新指纹: #{new_fp}"
            warn "  连接已被拒绝。如确认安全，请手动删除 known_hosts 条目后重连。"
          end
        end

        def load
          return {} unless File.exist?(@store_path)

          # 使用字符串 key 而非 Symbol：safe_load 不允许 Symbol，
          # 消除 permitted_classes: [Symbol] 带来的反序列化攻击面。
          # 写入端 save 也已改为字符串 key。
          YAML.safe_load(File.read(@store_path)) || {}
        end

        def save
          FileUtils.mkdir_p(File.dirname(@store_path))
          tmp = "#{@store_path}.tmp"
          File.write(tmp, YAML.dump(@entries))
          File.rename(tmp, @store_path)
          set_file_permissions
        end

        def set_file_permissions
          if Gem.win_platform?
            user = ENV["USERNAME"] || ENV["USER"] || ""
            # 白名单校验用户名，防止 icacls 命令注入
            unless user.match(/\A[A-Za-z0-9._-]+\z/)
              raise SecurityError, "Invalid username for ACL: #{user.inspect}"
            end
            system("icacls", @store_path, "/inheritance:r", "/grant:r", "#{user}:F")
          else
            File.chmod(0o600, @store_path)
          end
        end
      end
    end
  end
end
