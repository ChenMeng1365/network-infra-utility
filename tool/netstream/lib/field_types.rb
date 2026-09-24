# frozen_string_literal: true

require "ipaddr"

# NetworkInfraUtility::NetStream::FieldTypes — RFC 3954 字段类型映射与渲染工具
#
# 提供 NetStream v9 字段类型编号到人类可读名称的映射，
# 以及将原始字节按字段类型渲染为可读值的工具函数。
module NetworkInfraUtility
  module NetStream
    module FieldTypes
      # RFC 3954 字段类型 → 字段名映射（标准 + 常用扩展）
      FIELD_NAMES = {
        1   => "in_bytes",            2   => "in_pkts",             3   => "flows",
        4   => "protocol",            5   => "src_tos",             6   => "tcp_flags",
        7   => "l4_src_port",         8   => "ipv4_src_addr",       9   => "src_mask",
        10  => "input_snmp",          11  => "l4_dst_port",          12  => "ipv4_dst_addr",
        13  => "dst_mask",            14  => "output_snmp",          15  => "ipv4_next_hop",
        16  => "src_as",              17  => "dst_as",               18  => "bgp_ipv4_next_hop",
        19  => "mul_dst_pkts",        20  => "mul_dst_bytes",        21  => "last_switched",
        22  => "first_switched",      23  => "out_bytes",            24  => "out_pkts",
        25  => "min_pkt_length",      26  => "max_pkt_length",       27  => "ipv6_src_addr",
        28  => "ipv6_dst_addr",       29  => "ipv6_src_mask",        30  => "ipv6_dst_mask",
        31  => "ipv6_flow_label",     32  => "icmp_type",            33  => "mul_igmp_type",
        34  => "sampling_interval",   35  => "sampling_algorithm",   36  => "flow_active_timeout",
        37  => "flow_inactive_timeout", 38 => "engine_type",         39  => "engine_id",
        40  => "total_bytes_exp",     41  => "total_pkts_exp",       42  => "total_flows_exp",
        43  => "vlan_id",             44  => "ipv4_src_prefix",      45  => "ipv4_dst_prefix",
        46  => "mpls_top_label_type", 47  => "mpls_top_label_ip",    48  => "flow_sampler_id",
        49  => "flow_sampler_mode",   50  => "flow_sampler_interval", 51 => "min_ttl",
        52  => "max_ttl",             53  => "ipv4_ident",           54  => "dst_tos",
        55  => "in_src_mac",          56  => "out_dst_mac",          57  => "src_vlan",
        58  => "dst_vlan",            59  => "ip_protocol_version",  60  => "direction",
        61  => "ipv6_next_hop",       62  => "bgp_ipv6_next_hop",    63  => "ipv6_option_headers",
        64  => "class_id",            70  => "icmp_ipv4_type",       71  => "icmp_ipv4_code",
        72  => "icmp_ipv6_type",      73  => "icmp_ipv6_code",      80  => "forwarding_status",
        81  => "mpls_pal_rd",        82  => "mpls_prefix_len",       83  => "mpls_top_label_prefix",
        84  => "mpls_bottom_label_prefix", 85  => "mpls_bottom_label", 86  => "mpls_top_label_exp",
        87  => "mpls_bottom_label_exp", 88  => "mpls_ttl",             89  => "mpls_ip_ttl",
        90  => "mpls_labels",         91  => "mpls_control_word",    92  => "mpls_pointer",
        93  => "mpls_label_1",        94  => "mpls_label_2",         95  => "application_id",
        96  => "application_tag",     97  => "application_name",    128  => "bgp_next_hop_vpn",
        129  => "dst_as_vpn",         130  => "src_as_vpn",          131  => "src_vpn_id",
        132  => "dst_vpn_id",         133  => "src_vpn",             134  => "dst_vpn",
        135  => "ipv4_src_vpn",       136  => "ipv4_dst_vpn",        137  => "ipv6_src_vpn",
        138  => "ipv6_dst_vpn",       139  => "bytes_in_vpn",        140  => "bytes_out_vpn",
        141  => "pkts_in_vpn",        142  => "pkts_out_vpn",        143  => "ip_ttl",
        144  => "ipv4_icmp_type",     145  => "ipv4_icmp_code",      146  => "ipv6_icmp_type",
        147  => "ipv6_icmp_code",     148  => "flow_interval",       149  => "ipv4_vni",
        150  => "ipv6_vni",          151  => "nbar_application_name", 152  => "nbar_engine_id",
        153  => "nbar_engine_name",  154  => "nbar_version",         155  => "nbar_category",
        156  => "nbar_subcategory",  157  => "nbar_application_group", 158  => "nbar_application_tag",
        159  => "nbar_pdc",         160  => "nbar_pdl",             161  => "nbar_protocol_packets",
        162  => "nbar_protocol_bytes", 163  => "nbar_application_family", 164  => "nbar_protocol_port",
        165  => "nbar_protocol_session_time", 166  => "nbar_protocol_structure", 167  => "nbar_protocol_spec",
        168  => "nbar_protocol_avg_packets", 169  => "nbar_protocol_avg_bytes", 170  => "nbar_protocol_count",
        171  => "nat_ipv4_src_addr", 172  => "nat_ipv4_dst_addr",   173  => "nat_ipv6_src_addr",
        174  => "nat_ipv6_dst_addr", 175  => "nat_inside_vlan",      176  => "nat_outside_vlan",
        177  => "nat_port_blocks",   178  => "source_ipv4_address",  179  => "destination_ipv4_address",
        180  => "nat_source_port",   181  => "nat_destination_port", 182  => "nat_zone_id",
        183  => "nat_interface_id",  184  => "connection_id",        185  => "icmp_type",
        186  => "icmp_code",         187  => "sample_flow_id",       188  => "vlan_id",
        189  => "wevtid",            190  => "flow_collector",       191  => "p2p_technology",
        192  => "p2p_signature",     193  => "p2p_bittorrent",       194  => "p2p_edonkey",
        195  => "p2p_boot",          196  => "p2p_updated_signature", 197  => "p2p_payload",
        198  => "p2p_source",        199  => "p2p_destination",     200  => "p2p_application",
        201  => "p2p_tcp_protocol",  202  => "p2p_udp_protocol",    203  => "p2p_icmp_protocol",
        204  => "p2p_other_protocol", 205  => "p2p_millisecond",     206  => "p2p_application_category",
        207  => "p2p_signature_type", 208  => "p2p_signature_value", 209  => "p2p_identifier",
        210  => "p2p_client_count",  211  => "p2p_server_count",    212  => "p2p_peer_count",
        255 => "reserved"
      }.freeze

      # 按字段类型判定渲染方式的分类表
      IPV4_FIELD_TYPES = [8, 12, 15, 18, 44, 45, 47, 128, 135, 136, 171, 172, 178, 179].freeze
      IPV6_FIELD_TYPES = [27, 28, 61, 62, 137, 138, 173, 174].freeze
      MAC_FIELD_TYPES  = [55, 56].freeze

      # ── 字节序读取工具 ──

      def self.u16(b, o)  = b[o, 2].unpack1("n")
      def self.u32(b, o)  = b[o, 4].unpack1("N")
      def self.u16le(b, o) = b[o, 2].unpack1("v")
      def self.u32le(b, o) = b[o, 4].unpack1("V")

      # ── 地址/数据格式化 ──

      def self.ipv4_str(b)
        b.unpack("C*").join(".")
      end

      def self.ipv6_str(b)
        IPAddr.ntop(b)
      rescue StandardError
        b.unpack1("H*")
      end

      def self.mac_str(b)
        b.unpack("C*").map { |x| format("%02x", x) }.join(":")
      end

      def self.hexs(b)
        b.unpack1("H*")
      end

      # 按字段类型渲染为人类可读值。
      # type=0 的未知字段使用 reserved_off{offset} 命名，避免互相覆盖。
      def self.render_field(type, len, data, offset)
        name = if type.zero?
                 "reserved_off#{offset}"
               else
                 FIELD_NAMES[type] || "field_#{type}"
               end
        if IPV4_FIELD_TYPES.include?(type) && len == 4
          { name => ipv4_str(data) }
        elsif IPV6_FIELD_TYPES.include?(type) && len == 16
          { name => ipv6_str(data) }
        elsif MAC_FIELD_TYPES.include?(type) && len == 6
          { name => mac_str(data) }
        elsif len == 1
          { name => data.getbyte(0) }
        elsif len == 2
          { name => u16(data, 0) }
        elsif len == 4
          { name => u32(data, 0) }
        else
          { name => (len > 8 ? "0x" + hexs(data) : data.bytes.reduce(0) { |acc, x| (acc << 8) | x }) }
        end
      end

      # 将 [type, length] 字段定义数组转为可读 Hash。
      def self.field_info(type, length)
        { type: type, length: length, name: FIELD_NAMES[type] || "field_#{type}" }
      end
    end
  end
end
