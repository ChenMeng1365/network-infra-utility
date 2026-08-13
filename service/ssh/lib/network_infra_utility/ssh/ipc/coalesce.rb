# frozen_string_literal: true

require "base64"
require "thread"
require_relative "router"

module NetworkInfraUtility
  module SSH
    module IPC
      # 推送消费端：批量消费 channel.data.batch，按 channel 路由到对应 Terminal。
      # 修正 E9（背压）和 E8（订阅泄漏）。
      class Coalesce
        attr_reader :batch_enabled

        def initialize(router)
          @router = router
          @terminals = {}              # [conn_id, ch_id] => Terminal::Emulator
          @terminals_mutex = Mutex.new
          @batch_enabled = router.server_capabilities&.include?("coalesce") || false
          @sids = {}                   # [conn_id, ch_id] => subscription_id
          setup_subscriptions
        end

        # 注册一个通道到终端的映射
        def register_channel(conn_id, ch_id, terminal)
          key = [conn_id, ch_id]
          @terminals_mutex.synchronize { @terminals[key] = terminal }

          # 降级模式：逐条 channel.data
          unless @batch_enabled
            sid = @router.subscribe("channel.data") do |p|
              next unless p[:id] == ch_id

              data = Base64.decode64(p[:data])
              terminal.feed(data)
            end
            @sids[key] = sid
          end
        end

        # 注销通道映射，清理订阅
        def unregister_channel(conn_id, ch_id)
          key = [conn_id, ch_id]
          @terminals_mutex.synchronize { @terminals.delete(key) }

          sid = @sids.delete(key)
          @router.unsubscribe("channel.data", sid) if sid
        end

        # 查找终端（供 batch 分发用）
        def find_terminal(conn_id, ch_id)
          @terminals_mutex.synchronize { @terminals[[conn_id, ch_id]] }
        end

        private

        def setup_subscriptions
          return unless @batch_enabled

          @router.subscribe("channel.data.batch") do |p|
            items = p[:items] || []
            items.each do |item|
              # batch 中 item[:id] 是 channel_id，需与已注册的 channel 匹配
              dispatch_batch_item(item[:id], item[:data])
            end
          end
        end

        def dispatch_batch_item(ch_id, b64_data)
          data = Base64.decode64(b64_data)
          @terminals_mutex.synchronize do
            @terminals.each do |_key, terminal|
              next unless terminal.channel_id == ch_id

              terminal.feed(data)
              break
            end
          end
        end
      end
    end
  end
end
