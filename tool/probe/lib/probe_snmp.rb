# frozen_string_literal: true

require_relative "probe_base"

module NetworkInfraUtility
  module Probe
    # 极简 BER (Basic Encoding Rules) 编码器，仅用于构造 SNMP GET 请求。
    # 不依赖第三方 gem，纯标准库实现。
    module BER
      module_function

      # 构造 SNMP GET 请求报文。
      # version: "1" (SNMPv1) 或 "2c" (SNMPv2c)，默认 "2c"
      # community: 团体名，默认 "public"
      # oid: OID 整数数组，默认 [1,3,6,1,2,1,1,1,0] (sysDescr.0)
      def encode_get_request(version: "2c", community: "public", oid: [1, 3, 6, 1, 2, 1, 1, 1, 0], request_id: 1)
        version_int = version.to_s == "1" ? 0 : 1 # SNMPv1=0, v2c=1
        varbind = encode_tlv(0x30, encode_oid(oid) + encode_null)
        varbind_list = encode_tlv(0x30, varbind)
        pdu_body = encode_integer(request_id) + encode_integer(0) + encode_integer(0) + varbind_list
        pdu = encode_tlv(0xA0, pdu_body) # GET-PDU
        msg_body = encode_integer(version_int) + encode_octet_string(community) + pdu
        encode_tlv(0x30, msg_body)
      end

      # TLV：tag + 长度 + 内容
      def encode_tlv(tag, content)
        [tag].pack("C") + encode_length(content.bytesize) + content
      end

      # 长度编码（短/长两种形式）
      def encode_length(len)
        if len < 0x80
          [len].pack("C")
        else
          bytes = []
          while len > 0
            bytes.unshift(len & 0xFF)
            len >>= 8
          end
          [0x80 | bytes.size].pack("C") + bytes.pack("C*")
        end
      end

      # 非负整数
      def encode_integer(n)
        bytes = []
        loop do
          bytes.unshift(n & 0xFF)
          n >>= 8
          break if n == 0
        end
        encode_tlv(0x02, bytes.pack("C*"))
      end

      def encode_octet_string(str)
        encode_tlv(0x04, str.b)
      end

      def encode_null
        encode_tlv(0x05, "".b)
      end

      # OID 编码：前两弧合并为 40*a+b，其后每弧按 base-128。
      def encode_oid(oid)
        first = oid[0] * 40 + oid[1]
        subs = [first] + oid[2..]
        bytes = []
        subs.each do |sub|
          chunks = [sub & 0x7F]
          sub >>= 7
          while sub > 0
            chunks.unshift((sub & 0x7F) | 0x80)
            sub >>= 7
          end
          bytes.concat(chunks)
        end
        encode_tlv(0x06, bytes.pack("C*"))
      end
    end

    # SNMP 服务探测（UDP 161）。
    # 发送 SNMP GET (sysDescr.0)，收到响应即判定可达。
    class SnmpProbe < Base
      def self.default_port
        161
      end

      def call
        community = @options.fetch(:community, "public")
        version = @options.fetch(:version, "2c")
        oid = @options.fetch(:oid, [1, 3, 6, 1, 2, 1, 1, 1, 0])
        packet = BER.encode_get_request(
          version: version, community: community, oid: oid,
          request_id: rand(1..2_147_483_647)
        )
        reply, latency = timing { udp_exchange(packet) }
        if reply == :refused
          result(:refused, message: "UDP 端口拒绝/无监听")
        elsif reply && !reply.empty?
          result(:ok, latency: latency, message: "SNMP 响应正常", detail: "version=#{version} community=#{community}")
        else
          result(:timeout, latency: latency, message: "无 SNMP 响应（community/版本不匹配或防火墙丢弃）")
        end
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        result(:refused, message: "UDP 端口拒绝/无监听")
      rescue SocketError => e
        result(:fail, message: "地址解析失败: #{e.message}")
      rescue StandardError => e
        result(:unknown, message: e.message)
      end
    end
  end
end
