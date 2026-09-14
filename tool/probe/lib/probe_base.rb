# frozen_string_literal: true

require "socket"
require "rbconfig"
require_relative "probe_result"

module NetworkInfraUtility
  module Probe
    # 探测基类。所有协议探针继承本类，只需：
    #   1. 实现 call（返回 Result）
    #   2. 可选覆盖 default_port（类方法）
    #
    # protocol 名自动从类名派生：SshProbe → :ssh，DnsProbe → :dns。
    class Base
      attr_reader :host, :port, :timeout, :options

      def initialize(host, port: nil, timeout: 3, **options)
        @host = host
        @port = port || self.class.default_port
        @timeout = timeout.to_f
        @options = options
      end

      # 协议名（符号），由类名派生。
      def self.protocol
        name.split("::").last.sub(/Probe\z/, "").downcase.to_sym
      end

      # 默认端口，子类覆盖。
      def self.default_port
        nil
      end

      # 便捷入口：ProbeClass.run(host, ...) → Result
      def self.run(host, **opts)
        new(host, **opts).call
      end

      # 子类必须实现。
      def call
        raise NotImplementedError, "#{self.class} 未实现 call"
      end

      private

      # 构造统一 Result。
      def result(status, latency: nil, message: nil, detail: nil)
        Result.new(
          protocol: self.class.protocol,
          host: @host,
          port: @port,
          status: status,
          latency: latency,
          message: message,
          detail: detail
        )
      end

      # 计时并返回 [yield 返回值, 耗时秒数]。
      def timing
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        value = yield
        [value, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(4)]
      end

      # UDP 请求/响应交换：发送 payload。
      # 返回：
      #   String  → 收到响应（原始字节）
      #   nil     → 超时无响应
      #   :refused → 端口拒绝/无监听（ICMP 不可达，ECONNREFUSED/ECONNRESET）
      def udp_exchange(payload)
        sock = UDPSocket.new
        begin
          sock.connect(@host, @port)
          sock.send(payload, 0)
          return nil unless IO.select([sock], nil, nil, @timeout)
          sock.recvfrom_nonblock(4096).first
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET
          :refused
        ensure
          sock.close if sock
        end
      end

      # 从已连接 socket 读取至多 max 字节，带超时。
      def read_with_timeout(sock, max = 1024, timeout: @timeout)
        return nil unless IO.select([sock], nil, nil, timeout)
        sock.recv_nonblock(max)
      rescue IO::WaitReadable, EOFError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EINVAL
        nil
      end

      def windows?
        RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin|windows/
      end
    end
  end
end
