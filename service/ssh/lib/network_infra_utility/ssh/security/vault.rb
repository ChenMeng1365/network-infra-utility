# frozen_string_literal: true

require "base64"
require "openssl"
require "yaml"
require "securerandom"
require "fileutils"

module NetworkInfraUtility
  module SSH
    module Security
      # 凭据加密存储，AES-256-GCM。
      # 对应需求 FR-SEC-001。
      #
      # 加密参数（HLD §5.2.7 / ADR-004）：
      #   算法        AES-256-GCM
      #   KDF         PBKDF2-HMAC-SHA256
      #   迭代次数    100,000
      #   Salt 长度   32 字节（每条凭据独立随机）
      #   Key 长度    32 字节
      #   Nonce 长度  12 字节（GCM nonce，每次加密随机）
      #   Auth Tag    GCM 生成，存于 tag 字段
      #
      # vault.yml 每条记录格式：
      #   <key>:
      #     salt:   <Base64>
      #     nonce:  <Base64>
      #     tag:    <Base64>
      #     data:   <Base64>
      #
      # LLD §7.7 修正：
      #   - @cache 不在多线程访问（V1.0 主线程唯一），但为 V2.0 batch 预留 @cache_mutex
        #   - resolve_credentials 不直接修改传入的 spec，返回新 hash
      class Vault
        PBKDF2_ITERATIONS = 100_000
        SALT_LENGTH       = 32
        KEY_LENGTH        = 32    # AES-256
        NONCE_LENGTH      = 12    # GCM nonce
        REF_PREFIX        = "~vault:"

        attr_reader :store_path

        # @param master_password [String] 主密码（不落盘，仅内存）
        # @param store_path [String] vault.yml 路径
        def initialize(master_password, store_path = nil)
          raise ArgumentError, "Master password cannot be empty" if master_password.nil? || master_password.empty?

          @master_password = master_password
          @store_path = store_path || default_store_path
          @cache = {}
          @cache_mutex = Mutex.new # V2.0 batch 预留
        end

        # 加密凭据并存储到 vault.yml。
        # @param key [String] 凭据标识，如 "sess_001_pass"
        # @param value [String] 明文凭据
        def store(key, value)
          salt = SecureRandom.random_bytes(SALT_LENGTH)
          derived_key = derive_key(@master_password, salt)
          nonce = SecureRandom.random_bytes(NONCE_LENGTH)

          cipher = OpenSSL::Cipher::AES.new(256, :GCM)
          cipher.encrypt
          cipher.key = derived_key
          cipher.iv = nonce
          encrypted = cipher.update(value) + cipher.final
          tag = cipher.auth_tag

          entry = {
            "salt"  => Base64.strict_encode64(salt),
            "nonce" => Base64.strict_encode64(nonce),
            "tag"   => Base64.strict_encode64(tag),
            "data"  => Base64.strict_encode64(encrypted)
          }
          write_to_store(key, entry)
          @cache_mutex.synchronize { @cache[key] = value }
        end

        # 读取并解密凭据。
        # @param key [String] 凭据标识
        # @return [String, nil] 明文凭据，不存在返回 nil
        def load(key)
          cached = @cache_mutex.synchronize { @cache[key] }
          return cached if cached

          entry = read_from_store(key)
          return nil unless entry

          plaintext = decrypt_entry(entry)
          @cache_mutex.synchronize { @cache[key] = plaintext }
          plaintext
        end

        # 删除凭据
        # @param key [String] 凭据标识
        def delete(key)
          store = load_store
          store.delete(key)
          write_store(store)
          @cache_mutex.synchronize { @cache.delete(key) }
        end

        # 列出全部凭据标识
        # @return [Array<String>]
        def keys
          load_store.keys.map(&:to_s)
        end

        # 在连接规格中解析凭据引用。
        # spec 中值为 "~vault:<key>" 的字段会被替换为解密后的明文。
        # LLD §7.7 修正：返回新 hash，不修改入参。
        # @param spec [Hash] 连接规格
        # @return [Hash] 新的连接规格，凭据引用已解析为明文
        def resolve_credentials(spec)
          spec.each_with_object({}) do |(k, v), result|
            result[k] = resolve_value(v)
          end
        end

        # 检查凭据标识是否是 vault 引用
        # @param str [String]
        # @return [Boolean]
        def vault_ref?(str)
          str.is_a?(String) && str.start_with?(REF_PREFIX)
        end

        private

        # 递归解析 spec 中的 vault 引用（处理嵌套 hash 和数组）
        def resolve_value(v)
          case v
          when String
            v.start_with?(REF_PREFIX) ? load(v.sub(REF_PREFIX, "")) : v
          when Hash
            v.transform_values { |val| resolve_value(val) }
          when Array
            v.map { |val| resolve_value(val) }
          else
            v
          end
        end

        def derive_key(password, salt)
          OpenSSL::PKCS5.pbkdf2_hmac(password, salt, PBKDF2_ITERATIONS, KEY_LENGTH, "sha256")
        end

        def decrypt_entry(entry)
          salt = Base64.strict_decode64(entry["salt"])
          nonce = Base64.strict_decode64(entry["nonce"])
          tag = Base64.strict_decode64(entry["tag"])
          encrypted = Base64.strict_decode64(entry["data"])

          derived_key = derive_key(@master_password, salt)

          cipher = OpenSSL::Cipher::AES.new(256, :GCM)
          cipher.decrypt
          cipher.key = derived_key
          cipher.iv = nonce
          cipher.auth_tag = tag

          cipher.update(encrypted) + cipher.final
        end

        def write_to_store(key, entry)
          store = load_store
          store[key] = entry
          write_store(store)
        end

        def read_from_store(key)
          load_store[key]
        end

        def load_store
          return {} unless File.exist?(@store_path)

          # 使用字符串 key 而非 Symbol：safe_load 不允许 Symbol，
          # 消除 permitted_classes: [Symbol] 带来的反序列化攻击面。
          # 写入端 write_store 也已改为字符串 key。
          YAML.safe_load(File.read(@store_path)) || {}
        end

        def write_store(store)
          FileUtils.mkdir_p(File.dirname(@store_path))
          File.write(@store_path, YAML.dump(store))
          set_file_permissions
        end

        def default_store_path
          File.join(Dir.home, ".network-infra-utility", "vault.yml")
        end

        def set_file_permissions
          path = @store_path
          if Gem.win_platform?
            # Windows: ACL 限制当前用户读写
            # 使用 ENV.fetch 避免注入：icacls 的用户名参数不转义特殊字符会导致命令注入
            user = ENV["USERNAME"] || ENV["USER"] || ""
            # 白名单校验用户名（Windows 用户名仅允许字母、数字、连字符、下划线和点）
            unless user.match(/\A[A-Za-z0-9._-]+\z/)
              raise SecurityError, "Invalid username for ACL: #{user.inspect}"
            end
            system("icacls", path, "/inheritance:r", "/grant:r", "#{user}:F")
          else
            File.chmod(0o600, path)
          end
        end
      end
    end
  end
end
