# frozen_string_literal: true

require "yaml"
require "pathname"
require "tmpdir"

module NetworkInfraUtility
  module SSH
    module Config
      # 全局设置加载。
      class Settings
        DEFAULT_CONFIG_DIR = File.expand_path("~/.network-infra-utility")
        DEFAULT_SETTINGS = {
          master_password: nil,
          log_dir: nil,
          config_dir: DEFAULT_CONFIG_DIR,
          default_terminal: "xterm-256color",
          default_scrollback: 10_000,
          default_keepalive_interval: 30,
          default_theme: "dark"
        }.freeze

        attr_reader :config_dir, :data

        def initialize(config_dir = nil)
          @config_dir = config_dir || DEFAULT_CONFIG_DIR
          @data = load_settings
        end

        def master_password
          @data[:master_password]
        end

        def master_password=(pwd)
          @data[:master_password] = pwd
        end

        def log_dir
          @data[:log_dir] || File.join(@config_dir, "logs")
        end

        def sessions_path
          File.join(@config_dir, "sessions.yml")
        end

        def vault_path
          File.join(@config_dir, "vault.yml")
        end

        def known_hosts_path
          File.join(@config_dir, "known_hosts.yml")
        end

        def settings_path
          File.join(@config_dir, "settings.yml")
        end

        def engine_endpoint_file
          uid = if Gem.win_platform?
                   ENV["USERNAME"] || "default"
                 else
                   Process.uid.to_s
                 end
          File.join(Dir.tmpdir, "ssh_core_#{uid}.endpoint")
        end

        def default_terminal
          @data[:default_terminal]
        end

        def default_scrollback
          @data[:default_scrollback]
        end

        def default_keepalive_interval
          @data[:default_keepalive_interval]
        end

        def default_theme
          @data[:default_theme]
        end

        private

        def windows?
          RUBY_PLATFORM =~ /mswin|mingw|cygwin/
        end

        def load_settings
          path = settings_path
          defaults = DEFAULT_SETTINGS.merge(config_dir: @config_dir)

          if File.exist?(path)
            loaded = YAML.safe_load(File.read(path), symbolize_names: true) || {}
            defaults.merge(loaded)
          else
            defaults
          end
        end
      end
    end
  end
end
