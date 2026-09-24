# frozen_string_literal: true

# NetworkInfraUtility::NetStream::PredefinedTemplates — 逆向推断的 NetStream v9 预定义模板
#
# 当抓包文件中不包含模板 FlowSet（FlowSet ID=0）时，使用这些预定义模板解析数据流。
# 若抓包中包含真正的模板 FlowSet，解析器会自动覆盖预定义版本。
#
# 字段格式: [type, length]，type 参考 RFC 3954，未知字段 type=0
# length 为字段字节数，同一 type 在不同设备/配置下长度可能不同。
#
# ── 推断依据 ──
#
# 模板 1315/1316/1505/1501 均由 test.pcap（2.2GB, linktype=1, UDP dst_port=9015, 全部 v9）
# 前 50000 包做 4B/2B/1B 三级粒度统计分析逆向推断，20/20 校验通过。
# 设备: 华为 NE5000E-20 (VRP V8)
#
# ── RFC 3954 常用字段类型速查 ──
#
#  Type  名称                常见长度  说明
#  ──── ────────────────── ──────── ───────────────────────────
#   1   in_bytes             4       流字节数
#   2   in_pkts              4       流包数
#   4   protocol             1       IP 协议号 (6=TCP, 17=UDP)
#   5   src_tos              1       源 TOS / DSCP
#   6   tcp_flags            1       TCP 标志位
#   7   l4_src_port           2       传输层源端口
#   8   ipv4_src_addr         4       源 IPv4 地址
#   9   src_mask              1       源子网掩码长度
#  10   input_snmp           2/4     入接口 SNMP 索引
#  11   l4_dst_port           2       传输层目的端口
#  12   ipv4_dst_addr         4       目的 IPv4 地址
#  13   dst_mask              1       目的子网掩码长度
#  14   output_snmp          2/4     出接口 SNMP 索引
#  15   ipv4_next_hop         4       IPv4 下一跳
#  16   src_as               2/4     源 AS 号
#  17   dst_as               2/4     目的 AS 号
#  18   bgp_ipv4_next_hop     4       BGP IPv4 下一跳
#  21   last_switched         4       流结束时间 (相对 sys_uptime 毫秒)
#  22   first_switched        4       流起始时间 (相对 sys_uptime 毫秒)
#  27   ipv6_src_addr        16       源 IPv6 地址
#  28   ipv6_dst_addr        16       目的 IPv6 地址
#  29   ipv6_src_mask          1       源 IPv6 掩码长度
#  30   ipv6_dst_mask          1       目的 IPv6 掩码长度
#  54   dst_tos               1       目的 TOS / DSCP
#  60   direction              1       方向 (0=入, 1=出)
#  61   ipv6_next_hop        16       IPv6 下一跳
#  62   bgp_ipv6_next_hop    16       BGP IPv6 下一跳

module NetworkInfraUtility
  module NetStream
    module PredefinedTemplates
      # 逆向推断的 v9 预定义模板（抓包中模板缺失时使用）。
      #
      # 更新模板时，按 RFC 3954 字段类型速查表查找对应 type 值，
      # 填入 [type, length] 即可。未知字段用 [0, n] 占位，
      # 输出时字段名显示 reserved_off{offset}，不影响数据完整性。
      TEMPLATES = {
        # ── 模板 1315: IPv4 原始流, 60 字节/条 ──
        1315 => {
          desc: "IPv4 original flow",
          fields: [
            [8, 4],    # [0]  ipv4_src_addr
            [12, 4],   # [4]  ipv4_dst_addr
            [15, 4],   # [8]  ipv4_next_hop
            [2, 4],    # [12] in_pkts
            [1, 4],    # [16] in_bytes
            [22, 4],   # [20] first_switched
            [21, 4],   # [24] last_switched
            [10, 2],   # [28] input_snmp
            [14, 2],   # [30] output_snmp
            [16, 2],   # [32] src_as
            [17, 2],   # [34] dst_as
            [7, 2],    # [36] l4_src_port
            [11, 2],   # [38] l4_dst_port
            [18, 4],   # [40] bgp_ipv4_next_hop (全零)
            [0, 4],    # [44] 保留 (0 或 80)
            [5, 1],    # [48] src_tos (全零)
            [0, 1],    # [49] 未知 (全零)
            [6, 1],    # [50] tcp_flags
            [4, 1],    # [51] protocol
            [54, 1],   # [52] dst_tos
            [9, 1],    # [53] src_mask
            [13, 1],   # [54] dst_mask
            [60, 1],   # [55] direction
            [0, 4]     # [56] 常量 0x42010000
          ]
        },
        # ── 模板 1316: IPv6 原始流, 112 字节/条 ──
        1316 => {
          desc: "IPv6 original flow",
          fields: [
            [27, 16],  # [0]   ipv6_src_addr (240e:...)
            [28, 16],  # [16]  ipv6_dst_addr (240e:/2409:/2408:...)
            [62, 16],  # [32]  bgp_ipv6_next_hop (fe80:: 或 240e:...)
            [2, 4],    # [48]  in_pkts
            [1, 4],    # [52]  in_bytes
            [22, 4],   # [56]  first_switched
            [21, 4],   # [60]  last_switched
            [61, 16],  # [64]  ipv6_next_hop (240e:...)
            [0, 4],    # [80]  未知计数器
            [0, 4],    # [84]  保留 (全零)
            [7, 2],    # [88]  l4_src_port
            [11, 2],   # [90]  l4_dst_port
            [0, 4],    # [92]  保留 (0 或 80)
            [5, 1],    # [96]  src_tos (全零)
            [0, 1],    # [97]  未知 (全零)
            [6, 1],    # [98]  tcp_flags
            [4, 1],    # [99]  protocol
            [54, 1],   # [100] dst_tos
            [29, 1],   # [101] ipv6_src_mask
            [30, 1],   # [102] ipv6_dst_mask
            [60, 1],   # [103] direction
            [0, 4],    # [104] 常量 0x40xxxxxx
            [0, 4]     # [108] 常量 0x01000000
          ]
        },
        # ── 模板 1505: IPv6/SR6-aware 原始流, 84 字节/条 ──
        # 内层 IPv4 头 + 外层 IPv6 封装信息
        1505 => {
          desc: "IPv6/SR6-aware original flow",
          fields: [
            [8, 4],    # [0]  ipv4_src_addr (inner header)
            [12, 4],   # [4]  ipv4_dst_addr (inner header)
            [62, 16],  # [8]  bgp_ipv6_next_hop (fe80::)
            [2, 4],    # [24] in_pkts
            [1, 4],    # [28] in_bytes
            [22, 4],   # [32] first_switched
            [21, 4],   # [36] last_switched
            [27, 16],  # [40] ipv6_src_addr (240e:0185:c108:...)
            [10, 2],   # [56] input_snmp
            [14, 2],   # [58] output_snmp
            [7, 2],    # [60] l4_src_port
            [11, 2],   # [62] l4_dst_port
            [0, 4],    # [64] 保留 (全零)
            [0, 4],    # [68] 保留 (全零)
            [5, 1],    # [72] src_tos (全零)
            [0, 1],    # [73] 未知 (全零)
            [6, 1],    # [74] tcp_flags
            [4, 1],    # [75] protocol
            [54, 1],   # [76] dst_tos (值分散, 0-55)
            [9, 1],    # [77] src_mask (值分散)
            [13, 1],   # [78] dst_mask (6144-7680 = 0x18xx, 高字节=24-30)
            [60, 1],   # [79] direction (全0=入)
            [0, 4]     # [80] 常量 0x42010000
          ]
        },
        # ── 模板 1501: 未知类型流, 72 字节/条 ──
        # 含 16B 全零占位 (可能为 IPv6 地址), 无 SNMP/AS 字段
        1501 => {
          desc: "unknown flow type",
          fields: [
            [8, 4],    # [0]  ipv4_src_addr
            [12, 4],   # [4]  ipv4_dst_addr
            [15, 4],   # [8]  ipv4_next_hop (全零)
            [2, 4],    # [12] in_pkts
            [1, 4],    # [16] in_bytes
            [22, 4],   # [20] first_switched
            [21, 4],   # [24] last_switched
            [0, 16],   # [28] 未知 (全零, 可能 IPv6 地址占位)
            [0, 4],    # [44] 未知计数器
            [7, 2],    # [48] l4_src_port
            [11, 2],   # [50] l4_dst_port
            [0, 4],    # [52] 保留 (全零)
            [0, 4],    # [56] 保留 (全零)
            [5, 1],    # [60] src_tos (全零)
            [0, 1],    # [61] 未知 (全零)
            [6, 1],    # [62] tcp_flags
            [4, 1],    # [63] protocol
            [54, 1],   # [64] dst_tos
            [9, 1],    # [65] src_mask
            [13, 1],   # [66] dst_mask
            [60, 1],   # [67] direction
            [0, 4]     # [68] 常量 0x42010000
          ]
        }
      }.freeze
    end
  end
end
