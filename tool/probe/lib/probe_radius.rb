# frozen_string_literal: true

require_relative "probe_base"

module NetworkInfraUtility
  module Probe
    # RADIUS 服务探测（UDP 1812 认证端口）。
    # 发送 Access-Request，收到任意响应码即判定可达。
    #
    # 注意：RADIUS 服务器会丢弃无法通过共享密钥校验的请求，
    # 因此「无响应」不能等同于「服务不可达」，结果需结合其它信息判断。
    class RadiusProbe < Base
      def self.default_port
        1812
      end

      def call
        packet = build_access_request(@options.fetch(:username, "probe"))
        reply, latency = timing { udp_exchange(packet) }
        if reply == :refused
          result(:refused, message: "UDP 端口拒绝/无监听")
        elsif reply && !reply.empty?
          code = reply.getbyte(0)
          result(:ok, latency: latency, message: "RADIUS 服务可达", detail: "响应码 #{code} (#{code_name(code)})")
        else
          result(:timeout, latency: latency, message: "无响应（RADIUS 可能丢弃无有效共享密钥的请求）")
        end
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        result(:refused, message: "UDP 端口拒绝/无监听")
      rescue SocketError => e
        result(:fail, message: "地址解析失败: #{e.message}")
      rescue StandardError => e
        result(:unknown, message: e.message)
      end

      private

      # 构造 Access-Request：Code=1, Id, Length, Request Authenticator(16B), User-Name 属性。
      # Authenticator 用随机字节占位（无共享密钥时无法计算合法值，仅用于探测）。
      def build_access_request(username)
        code = 1
        id = rand(256)
        authenticator = Random.bytes(16)
        attr = [1, username.bytesize + 2].pack("CC") + username
        length = 20 + attr.bytesize
        [code, id, length].pack("CCn") + authenticator + attr
      end

      def code_name(code)
        {
          2 => "Access-Accept",
          3 => "Access-Reject",
          11 => "Access-Challenge"
        }.fetch(code, "未知")
      end
    end
  end
end
