# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module IPC
      # IPC 层异常基类
      class Error < StandardError; end

      # RPC 超时
      class RPCTimeout < Error; end

      # 远程返回的 JSON-RPC error 对象
      class RPCError < Error
        attr_reader :code, :data

        def initialize(error_obj)
          @code = error_obj[:code]
          @data = error_obj[:data]
          super(error_obj[:message] || "RPC error code=#{@code}")
        end
      end

      # 连接尚未就绪时操作通道
      class NotReady < Error; end

      # 背压暂停时 send 被拒
      class FlowPaused < Error; end

      # IPC 连接断开
      class ConnectionLost < Error; end

      # 配置 Schema 版本不匹配
      class SchemaMismatch < Error; end
    end
  end
end
