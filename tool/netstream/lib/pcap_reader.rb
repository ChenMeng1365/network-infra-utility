# frozen_string_literal: true

require_relative "field_types"

# NetworkInfraUtility::NetStream::PcapReader — 流式 pcap 文件读取器
#
# 支持 pcap little/big endian（magic 0xa1b2c3d4 / 0xd4c3b2a1），
# 链路类型 SLL(113) / EN10MB(1)，逐包流式读取，内存恒定。
module NetworkInfraUtility
  module NetStream
    class PcapReader
      include FieldTypes

      attr_reader :endian, :linktype

      # 常用链路类型
      LINKTYPE_ETHERNET = 1
      LINKTYPE_SLL      = 113

      def initialize(path)
        @file = File.open(path, "rb")
        begin
          ghdr = @file.read(24)
          raise "pcap 文件过短" if ghdr.nil? || ghdr.size < 24

          magic = ghdr[0, 4].unpack1("H*")
          @endian =
            case magic
            when "d4c3b2a1" then :little
            when "a1b2c3d4" then :big
            else raise "unknown pcap magic #{magic}"
            end
          @u32f = @endian == :little ? "V" : "N"
          @linktype = ghdr[20, 4].unpack1(@u32f)
        rescue StandardError
          @file.close
          raise
        end
      end

      # 逐包迭代，yield [ts_sec, ts_usec, frame_data]。
      # 流式读取，不一次性加载到内存。
      def each_packet
        return enum_for(:each_packet) unless block_given?

        loop do
          phdr = @file.read(16)
          break if phdr.nil? || phdr.size < 16

          ts_sec = phdr[0, 4].unpack1(@u32f)
          ts_usec = phdr[4, 4].unpack1(@u32f)
          incl   = phdr[8, 4].unpack1(@u32f)
          break if incl.zero?

          data = @file.read(incl)
          break if data.nil? || data.size < incl

          yield ts_sec, ts_usec, data
        end
      ensure
        @file.close
      end

      # 读取全部包到内存（小文件场景）。
      def read_all
        packets = []
        each_packet { |ts_sec, ts_usec, data| packets << { ts_sec: ts_sec, ts_usec: ts_usec, data: data } }
        packets
      end

      # 从链路帧中提取 UDP 载荷（SLL / Ethernet + IPv4 + UDP）。
      # 返回 nil 表示非 IPv4 UDP 包。
      def self.extract_udp_payload(frame, linktype)
        o = 0
        if linktype == LINKTYPE_SLL        # Linux SLL: 16B 头，协议类型在 offset 14
          proto = FieldTypes.u16(frame, 14)
          o = 16
        elsif linktype == LINKTYPE_ETHERNET # Ethernet: 14B 头，EtherType 在 offset 12
          proto = FieldTypes.u16(frame, 12)
          o = 14
        else
          return nil
        end
        return nil unless proto == 0x0800  # 仅 IPv4

        ihl = (frame.getbyte(o) & 0x0f) * 4
        return nil if ihl < 20

        return nil unless frame.getbyte(o + 9) == 17  # UDP

        src_ip = FieldTypes.ipv4_str(frame.byteslice(o + 12, 4))
        dst_ip = FieldTypes.ipv4_str(frame.byteslice(o + 16, 4))
        u = o + ihl
        return nil if u + 8 > frame.bytesize

        sport  = FieldTypes.u16(frame, u)
        dport  = FieldTypes.u16(frame, u + 2)
        ulen   = FieldTypes.u16(frame, u + 4)
        payload = frame.byteslice(u + 8, [ulen - 8, frame.bytesize - u - 8].min)
        { src_ip: src_ip, dst_ip: dst_ip, src_port: sport, dst_port: dport, payload: payload }
      rescue StandardError
        nil
      end
    end
  end
end
