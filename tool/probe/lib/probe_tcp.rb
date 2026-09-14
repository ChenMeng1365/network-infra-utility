# frozen_string_literal: true

require_relative "probe_base"

module NetworkInfraUtility
  module Probe
    # 通用 TCP 端口连通性探针。
    # 仅验证 TCP 三次握手能否建立。
    class TcpProbe < Base
      def self.default_port
        nil
      end

      def call
        sock, latency = timing { Socket.tcp(@host, @port, connect_timeout: @timeout) }
        sock.close
        result(:ok, latency: latency, message: "TCP #{@port} 端口可达")
      rescue Errno::ETIMEDOUT
        result(:timeout, message: "连接超时")
      rescue Errno::ECONNREFUSED
        result(:refused, message: "连接被拒绝")
      rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH
        result(:unreachable, message: "主机/网络不可达")
      rescue SocketError => e
        result(:fail, message: "地址解析失败: #{e.message}")
      rescue StandardError => e
        result(:unknown, message: e.message)
      end
    end

    # Telnet 探测（TCP 23）。
    class TelnetProbe < TcpProbe
      def self.default_port
        23
      end
    end

    # SSH 探测（TCP 22）：建立连接后额外读取横幅确认是 SSH 协议。
    class SshProbe < TcpProbe
      def self.default_port
        22
      end

      def call
        sock, latency = timing { Socket.tcp(@host, @port, connect_timeout: @timeout) }
        banner = read_with_timeout(sock)
        sock.close
        if banner && banner.start_with?("SSH-")
          result(:ok, latency: latency, message: "SSH 服务可达", detail: banner.strip)
        else
          result(:ok, latency: latency, message: "端口开放但非 SSH 横幅", detail: banner.to_s.strip)
        end
      rescue Errno::ETIMEDOUT
        result(:timeout, message: "连接超时")
      rescue Errno::ECONNREFUSED
        result(:refused, message: "连接被拒绝")
      rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH
        result(:unreachable, message: "主机/网络不可达")
      rescue SocketError => e
        result(:fail, message: "地址解析失败: #{e.message}")
      rescue StandardError => e
        result(:unknown, message: e.message)
      end
    end

    # NETCONF 探测（默认 TCP 830，netconf-over-ssh）。
    # 实际设备多为 SSH 承载，复用 SSH 横幅校验。
    class NetconfProbe < SshProbe
      def self.default_port
        830
      end
    end

    # TWAMP 控制会话探测（TCP 862，RFC 5357 Control-Client）。
    # 仅验证控制端口可达；完整 TWAMP 需控制会话协商（Server Greeting / Set-Up-Response）。
    class TwampProbe < TcpProbe
      def self.default_port
        862
      end
    end
  end
end
