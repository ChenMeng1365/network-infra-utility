# frozen_string_literal: true

require "json"
require "securerandom"
require "thread"
require_relative "errors"
require_relative "transport"

module NetworkInfraUtility
  module SSH
    module IPC
      # JSON-RPC 2.0 路由器：请求-响应配对、推送分发、订阅注册/注销。
      # 取代 HLD 的 IPC::Client，修正 E8（订阅泄漏）。
      class Router
        PROTOCOL_VER = "1.0"

        attr_reader :transport, :server_capabilities

        def initialize(transport)
          @transport = transport
          @id_mutex = Mutex.new
          @next_id = 0
          @pending = {}              # id => [Queue, deadline]
          @pending_mutex = Mutex.new
          @subscriptions = {}        # method => { sid => Proc }
          @subscriptions_mutex = Mutex.new
          @reverse_handlers = {}     # method => Proc (Erlang→Ruby 带 id 的反向 RPC)
          @reverse_mutex = Mutex.new
          @closed = false
          @disconnect_callbacks = []
          @disconnect_mutex = Mutex.new
          @reader_thread = nil
          @server_capabilities = []
        end

        # 连接到引擎并完成 hello 握手
        def connect(endpoint, auth_token:, client_id:)
          @transport.connect(endpoint)
          start_reader_thread
          resp = call("hello", {
            auth_token: auth_token,
            ver: PROTOCOL_VER,
            client_id: client_id
          }, timeout_ms: 10_000)
          @server_capabilities = resp[:capabilities] || []
          resp
        end

        # 注册连接断开回调
        # 回调签名: ->(reason) { }
        def on_disconnect(&block)
          @disconnect_mutex.synchronize do
            @disconnect_callbacks << block
          end
        end

        # 同步 RPC 调用
        def call(method, params = {}, timeout_ms: 30_000)
          ensure_open
          id = next_id
          q = Queue.new
          register_pending(id, q, timeout_ms)
          @transport.send(jsonrpc: "2.0", id: id, method: method, params: params)
          msg = q.pop(timeout: timeout_ms / 1000.0)
          raise RPCTimeout, method unless msg
          raise RPCError.new(msg[:error]) if msg[:error]

          msg[:result]
        ensure
          unregister_pending(id) if id
        end

        # 订阅推送，返回 subscription_id 用于注销（修正 E8）
        def subscribe(method, &block)
          sid = SecureRandom.hex(8)
          @subscriptions_mutex.synchronize do
            (@subscriptions[method] ||= {})[sid] = block
          end
          sid
        end

        # 注销订阅
        def unsubscribe(method, sid)
          @subscriptions_mutex.synchronize do
            @subscriptions[method]&.delete(sid)
          end
        end

        # 注册反向 RPC 处理器（Erlang→Ruby 带 id 的请求，如 hostkey.resolve）
        def on_reverse_rpc(method, &block)
          @reverse_mutex.synchronize do
            @reverse_handlers[method] = block
          end
        end

        # 回复反向 RPC（给 Erlang 发 result）
        def reply_reverse(id, result)
          @transport.send(jsonrpc: "2.0", id: id, result: result)
        end

        def close
          @closed = true
          @reader_thread&.kill
          @transport.close
        end

        def closed?
          @closed
        end

        private

        def ensure_open
          raise ConnectionLost, "Router closed" if @closed
        end

        def start_reader_thread
          @reader_thread = Thread.new do
            @transport.each_frame do |frame|
              msg = JSON.parse(frame, symbolize_names: true)
              on_message(msg)
            end
            # EOF reached — 正常关闭
            handle_disconnect("connection closed (EOF)")
          rescue StandardError => e
            handle_disconnect("reader thread error: #{e.message}")
          end
        end

        # 引擎断连时调用：通知所有回调并清空 pending 队列，
        # 避免调用方阻塞至 30s 超时（修正 reader thread 异常不通知 @pending 的缺陷）
        def handle_disconnect(reason)
          @closed = true

          # 1. 通知所有断连回调
          callbacks = @disconnect_mutex.synchronize do
            @disconnect_callbacks.dup
          end
          callbacks.each { |cb| cb.call(reason) }

          # 2. 清空 @pending，给每个等待的 Queue 推入 nil（触发 RPCTimeout）
          pending = @pending_mutex.synchronize do
            old = @pending
            @pending = {}
            old
          end
          pending.each_value { |queue, _deadline| queue << nil }
        end

        # 由 reader thread 调用
        def on_message(msg)
          if msg[:id]
            if msg[:method]
              # Erlang→Ruby 的反向 RPC（带 id 和 method）
              handle_reverse_rpc(msg)
            else
              # 对我方请求的响应
              dispatch_response(msg)
            end
          elsif msg[:method]
            # 推送 notification
            dispatch_push(msg[:method], msg[:params])
          end
        end

        def dispatch_response(msg)
          entry = @pending_mutex.synchronize { @pending.delete(msg[:id]) }
          return unless entry

          queue, _deadline = entry
          queue << msg
        end

        def dispatch_push(method, params)
          callbacks = @subscriptions_mutex.synchronize do
            @subscriptions[method]&.values&.dup
          end
          callbacks&.each { |cb| cb.call(params) }
        end

        def handle_reverse_rpc(msg)
          handler = @reverse_mutex.synchronize { @reverse_handlers[msg[:method]] }
          if handler
            begin
              result = handler.call(msg[:params])
              reply_reverse(msg[:id], result)
            rescue StandardError => e
              @transport.send(jsonrpc: "2.0", id: msg[:id],
                              error: { code: -32603, message: e.message })
            end
          else
            @transport.send(jsonrpc: "2.0", id: msg[:id],
                            error: { code: -32601, message: "No handler for #{msg[:method]}" })
          end
        end

        def next_id
          @id_mutex.synchronize { @next_id += 1 }
        end

        def register_pending(id, queue, timeout_ms)
          deadline = Time.now + timeout_ms / 1000.0
          @pending_mutex.synchronize { @pending[id] = [queue, deadline] }
        end

        def unregister_pending(id)
          @pending_mutex.synchronize { @pending.delete(id) }
        end
      end
    end
  end
end
