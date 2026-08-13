# frozen_string_literal: true

require "json"
require "socket"
require "uri"
require_relative "errors"

module NetworkInfraUtility
  module SSH
    module IPC
      # socket 读写与分帧。重连为 V2.0 功能。
      # 纯 I/O 层，不做业务路由。
      class Transport
        attr_reader :endpoint, :connected

        def initialize(endpoint = nil)
          @endpoint = endpoint
          @socket = nil
          @write_mutex = Mutex.new
          @connected = false
        end

        # 连接到端点（unix:path 或 tcp://host:port）
        def connect(endpoint = @endpoint)
          raise ArgumentError, "No endpoint" unless endpoint

          @endpoint = endpoint
          @socket = open_socket(endpoint)
          @connected = true
          self
        end

        # 在 reader thread 中循环调用，按 \n 分帧
        def each_frame
          raise ConnectionLost, "Not connected" unless @connected

          buffer = +""
          loop do
            chunk = @socket.readpartial(65536)
            buffer << chunk
            while (idx = buffer.index("\n"))
              yield buffer[0...idx]
              buffer = buffer[(idx + 1)..]
            end
          end
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
          @connected = false
          nil
        end

        # 发送一条 JSON 消息（自动追加 \n）
        def send(hash)
          raise ConnectionLost, "Not connected" unless @connected

          data = JSON.generate(hash) + "\n"
          @write_mutex.synchronize { @socket.write(data) }
        end
        alias << send

        def close
          @connected = false
          @socket&.close
          @socket = nil
        end

        private

        def open_socket(endpoint)
          case endpoint
          when /\Aunix:(.+)/
            UNIXSocket.new(Regexp.last_match(1))
          when /\Atcp:\/\/(.+):(\d+)/
            TCPSocket.new(Regexp.last_match(1), Regexp.last_match(2).to_i)
          else
            raise ArgumentError, "Unknown endpoint format: #{endpoint}"
          end
        end
      end
    end
  end
end
