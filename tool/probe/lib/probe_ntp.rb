# frozen_string_literal: true

require_relative "probe_base"

module NetworkInfraUtility
  module Probe
    # NTP 服务探测（UDP 123）。
    # 发送标准 48 字节 NTP 客户端报文，收到响应即判定可达。
    class NtpProbe < Base
      NTP_EPOCH_OFFSET = 2_208_988_800 # 1900-01-01 与 1970-01-01 的秒差

      def self.default_port
        123
      end

      def call
        packet = build_packet(@options.fetch(:version, 4))
        reply, latency = timing { udp_exchange(packet) }
        if reply == :refused
          result(:refused, message: "UDP 端口拒绝/无监听")
        elsif reply && reply.bytesize >= 48
          result(:ok, latency: latency, message: "NTP 响应正常", detail: ntp_summary(reply))
        else
          result(:timeout, latency: latency, message: "无 NTP 响应")
        end
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        result(:refused, message: "UDP 端口拒绝/无监听")
      rescue SocketError => e
        result(:fail, message: "地址解析失败: #{e.message}")
      rescue StandardError => e
        result(:unknown, message: e.message)
      end

      private

      # 构造 NTP 客户端报文：首字节 = LI(0) + VN(version) + Mode(3)。
      def build_packet(version = 4)
        flags = ((version & 0x07) << 3) | 0x03
        t = Time.now.to_f + NTP_EPOCH_OFFSET
        sec = t.to_i
        frac = ((t - sec) * (1 << 32)).to_i & 0xFFFFFFFF
        [flags].pack("C") + ("\x00" * 39) + [sec, frac].pack("N2")
      end

      def ntp_summary(reply)
        stratum = reply.getbyte(1)
        "stratum=#{stratum}"
      end
    end
  end
end
