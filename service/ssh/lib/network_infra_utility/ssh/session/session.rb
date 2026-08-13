# frozen_string_literal: true

require "securerandom"
require_relative "../terminal/emulator"

module NetworkInfraUtility
  module SSH
    module Session
      # 单个 SSH 会话：封装终端、文件、端口转发等子能力。
      class Session
        attr_reader :session_id, :conn_id, :spec, :name, :host, :port, :user
        attr_reader :fingerprint, :terminal, :file_manager, :port_forwards
        attr_accessor :tags, :group, :status

        STATUSES = %i[connecting authenticating connected disconnected error].freeze

        def initialize(client, conn_id, spec, fingerprint = nil)
          @client = client
          @conn_id = conn_id
          @session_id = "sess_#{SecureRandom.uuid.delete('-')}"
          @spec = spec
          @fingerprint = fingerprint
          @name = spec[:name] || "#{spec[:user]}@#{spec[:host]}"
          @host = spec[:host]
          @port = spec[:port] || 22
          @user = spec[:user]
          @tags = spec[:tags] || []
          @group = spec[:group]
          @status = :connected
          @terminal = nil
          @file_manager = nil
          @port_forwards = []
          @coalesce = client.coalesce
        end

        # 打开终端通道
        # @param term_type [String] 终端类型如 "xterm-256color"
        # @param cols [Integer] 列数
        # @param rows [Integer] 行数
        def open_terminal(term_type: "xterm-256color", cols: 80, rows: 24)
          raise "Terminal already open" if @terminal

          resp = @client.ipc.call("channel.open", {
            conn_id: @conn_id,
            type: "shell",
            term: term_type,
            cols: cols,
            rows: rows
          })
          ch_id = resp[:channel_id]
          @terminal = Terminal::Emulator.new(@client, @conn_id, ch_id, cols, rows,
                                              theme: @spec[:terminal]&.dig(:theme))
          @coalesce&.register_channel(@conn_id, ch_id, @terminal)
          @terminal
        end

        # 关闭终端
        def close_terminal
          return unless @terminal

          @client.ipc.call("channel.close", { id: @terminal.channel_id })
          @coalesce&.unregister_channel(@conn_id, @terminal.channel_id)
          @terminal = nil
        end

        # 添加端口转发规则（FR-NET-001）
        def add_port_forward(type, local_port, remote_host, remote_port)
          resp = @client.ipc.call("portfwd.add", {
            conn_id: @conn_id,
            type: type.to_s,
            local_port: local_port,
            remote_host: remote_host,
            remote_port: remote_port
          })
          rule_id = resp[:rule_id]
          @port_forwards << {
            id: rule_id, type: type, local_port: local_port,
            remote_host: remote_host, remote_port: remote_port
          }
          rule_id
        end

        # 移除端口转发规则
        def remove_port_forward(rule_id)
          @client.ipc.call("portfwd.remove", { conn_id: @conn_id, rule_id: rule_id })
          @port_forwards.reject! { |r| r[:id] == rule_id }
        end

        # 断开连接
        def disconnect
          close_terminal
          @client.ipc.call("conn.disconnect", { id: @conn_id })
          @status = :disconnected
        end

        def connected?
          @status == :connected
        end

        # 连接被远端关闭时的回调
        def on_closed(reason = nil)
          @status = :disconnected
          @terminal = nil
          @file_manager = nil
        end
      end
    end
  end
end
