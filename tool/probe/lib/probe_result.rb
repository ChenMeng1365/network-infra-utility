# frozen_string_literal: true

module NetworkInfraUtility
  module Probe
    # 单次探测的统一结果对象。
    #
    # status 取值：
    #   :ok          服务连通/正常响应
    #   :timeout     超时未响应
    #   :refused     连接被拒绝
    #   :unreachable 主机/网络不可达
    #   :fail        其它失败
    #   :unknown     未知错误或无法判定
    class Result
      STATUSES = %i[ok fail timeout refused unreachable unknown].freeze

      attr_reader :protocol, :host, :port, :status, :latency, :message, :detail

      def initialize(protocol:, host:, port: nil, status:, latency: nil, message: nil, detail: nil)
        @protocol = protocol.to_sym
        @host = host
        @port = port
        @status = status.to_sym
        @latency = latency
        @message = message
        @detail = detail
      end

      def ok?
        @status == :ok
      end

      def fail?
        @status == :fail
      end

      def timeout?
        @status == :timeout
      end

      def refused?
        @status == :refused
      end

      def unreachable?
        @status == :unreachable
      end

      def success?
        ok?
      end

      # 序列化为 Hash，便于 JSON 输出。
      def to_h
        {
          protocol: @protocol,
          host: @host,
          port: @port,
          status: @status,
          latency: @latency,
          message: @message,
          detail: @detail
        }
      end

      def to_s
        mark = ok? ? "OK" : @status.to_s.upcase
        line = "#{@protocol.to_s.upcase} #{@host}#{@port ? ":#{@port}" : ''} -> #{mark}"
        line += " (#{format('%.3f', @latency)}s)" if @latency
        line += " #{@message}" if @message
        line
      end
    end
  end
end
