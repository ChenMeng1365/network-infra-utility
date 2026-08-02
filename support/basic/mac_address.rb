# coding: utf-8
# frozen_string_literal: true

=begin # MD
<< MAC 地址格式 >>

| 分隔符 | 分组数 | 示例                     | 说明            |
| ----- | ----- | ----------------------- | --------------- |
| -     | 6     | 00-1A-2B-3C-4D-5E       | Windows 常用    |
| :     | 6     | 00:1A:2B:3C:4D:5E       | Linux/Cisco 常用 |
| .     | 3     | 001A.2B3C.4D5E          | Cisco 点分格式  |
| -     | 3     | 001A-2B3C-4D5E          | 部分设备 3 段横杠 |
| 无    | -     | 001A2B3C4D5E            | 无分隔符        |

<< 特殊位 >>

| 位            | 位置              | 说明                          |
| ------------- | ----------------- | ----------------------------- |
| I/G 位        | 首字节 bit0       | 0=单播/个体, 1=组播           |
| U/L 位        | 首字节 bit1       | 0=全球分配(OUI), 1=本地分配    |

<< EUI-64 >>

MAC 地址 → EUI-64：在 OUI（前3字节）和 NIC（后3字节）之间插入 FF:FE
例：00-1A-2B-3C-4D-5E → 00:1A:2B:FF:FE:3C:4D:5E
IPv6 SLAAC 接口标识符需翻转 U/L 位
=end

# MAC 地址工具。
#
# 用法：
#   mac = MACAddress.new("00:1A:2B:3C:4D:5E")
#   mac = MAC.address("001A.2B3C.4D5E")
#   mac = MAC.address("001A-2B3C-4D5E")
#   mac = MAC.address(0x001A2B3C4D5E)
#   mac = MAC.address([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
#
#   mac.to_s        # → "00-1a-2b-3c-4d-5e"
#   mac.to_hex(":", 6)  # → "00:1a:2b:3c:4d:5e"
#   mac.to_hex(".", 3)  # → "001a.2b3c.4d5e"
#   mac.oui         # → "00-1a-2b"
#   mac.multicast?  # → false
#   mac.locally_administered?  # → false
#   mac.to_eui64_s  # → "00:1a:2b:ff:fe:3c:4d:5e"

class MacAddress
  include Comparable

  attr_reader :numbers, :number

  MAC_MAX = 0xFFFFFFFFFFFF

  # 从 String（带分隔符或无分隔符）、Array 或 Integer 构造。
  #
  # 字符串示例：
  #   "00-1A-2B-3C-4D-5E"  6 组（- / : 分隔）
  #   "001A.2B3C.4D5E"     3 组（. 分隔，Cisco 点分格式）
  #   "001A-2B3C-4D5E"     3 组（- 分隔，部分设备写法）
  #   "001A2B3C4D5E"       无分隔符
  #
  # 数组示例：
  #   ["00", "1A", "2B", "3C", "4D", "5E"]  6 段字符串
  #   ["001A", "2B3C", "4D5E"]              3 段字符串
  #   [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]  6 段整数
  #
  # 整数示例：
  #   0x001A2B3C4D5E
  def initialize(arg)
    case arg
    when String
      sequence = detect_and_split(arg)
      build_from_sequence(sequence)
    when Array
      build_from_sequence(arg)
    when Integer
      raise ArgumentError, "MAC out of range: #{arg}" unless (0..MAC_MAX).include?(arg)
      @number = arg
      @numbers = (0..5).map { |i| (arg >> ((5 - i) * 8)) & 0xFF }
    else
      raise ArgumentError, "Cannot parse MAC from #{arg.class}"
    end
  end

  # ---- 输出格式 ----

  def to_a
    @numbers
  end

  # 带分隔符的十六进制串。groups 控制分组（6/3/2/1），separator 控制分隔符。
  #   to_hex("-", 6) → "00-1a-2b-3c-4d-5e"
  #   to_hex(":", 6) → "00:1a:2b:3c:4d:5e"
  #   to_hex(".", 3) → "001a.2b3c.4d5e"
  #   to_hex("", 1)  → "001a2b3c4d5e"
  def to_hex(separator = "-", groups = 6)
    unless [1, 2, 3, 6].include?(groups)
      raise ArgumentError, "Invalid groups: #{groups} (must be 1, 2, 3, or 6)"
    end
    slice_size = 6 / groups
    @numbers.each_slice(slice_size).map do |slice|
      slice.map { |n| "%02x" % n }.join
    end.join(separator)
  end

  def to_s
    to_hex("-", 6)
  end

  alias inspect to_s

  def to_upcase(separator = "-", groups = 6)
    to_hex(separator, groups).upcase
  end

  def to_downcase(separator = "-", groups = 6)
    to_hex(separator, groups).downcase
  end

  # ---- 属性判定 ----

  # I/G 位：首字节 bit0。0=单播，1=组播。
  def multicast?
    @numbers[0] & 0x01 != 0
  end

  alias group? multicast?

  # U/L 位：首字节 bit1。1=本地分配，0=全球分配（OUI）。
  def locally_administered?
    @numbers[0] & 0x02 != 0
  end

  def universally_administered?
    !locally_administered?
  end

  # 全 1 广播地址。
  def broadcast?
    @number == MAC_MAX
  end

  # 全 0 空地址。
  def zero?
    @number == 0
  end

  # OUI：前 3 字节组织唯一标识符。
  def oui
    @numbers[0..2].map { |n| "%02x" % n }.join("-")
  end

  # NIC：后 3 字节网卡标识。
  def nic
    @numbers[3..5].map { |n| "%02x" % n }.join("-")
  end

  # ---- EUI-64 / IPv6 SLAAC ----

  # 转为 EUI-64 标识符（OUI 和 NIC 之间插入 FF:FE），返回 8 字节整数数组。
  #   MacAddress.new("00-1A-2B-3C-4D-5E").to_eui64
  #   → [0x00, 0x1A, 0x2B, 0xFF, 0xFE, 0x3C, 0x4D, 0x5E]
  def to_eui64
    @numbers[0..2] + [0xFF, 0xFE] + @numbers[3..5]
  end

  # EUI-64 格式字符串（默认冒号分隔）。
  def to_eui64_s(separator = ":")
    to_eui64.map { |n| "%02x" % n }.join(separator)
  end

  # 转为 IPv6 SLAAC 接口标识符（EUI-64 且 U/L 位翻转），返回 8 字节整数数组。
  def to_interface_id
    eui64 = to_eui64
    eui64[0] ^= 0x02
    eui64
  end

  def to_interface_id_s(separator = ":")
    to_interface_id.map { |n| "%02x" % n }.join(separator)
  end

  # ---- Comparable ----

  def <=>(other)
    @number <=> other.number
  end

  def hash
    @number.hash
  end

  def eql?(other)
    other.is_a?(MacAddress) && @number == other.number
  end

  # ---- 兼容原接口 ----

  # 原版 writing 方法：groups 控制分组数，splitter 控制分隔符。
  def writing(groups = 3, splitter = "-")
    groups = 6 if groups >= 6
    to_hex(splitter, groups)
  end

  # ---- 类方法 ----

  # 有效性检查，不抛异常。
  def self.valid?(arg)
    new(arg)
    true
  rescue ArgumentError
    false
  end

  private

  # 从字符串自动检测分隔符并拆分为段数组。
  def detect_and_split(str)
    str = str.strip
    if str.match?(/[:.\-]/)
      str.split(/[:.\-]/)
    elsif str.match?(/\A[0-9a-fA-F]{12}\z/)
      str.scan(/../)
    else
      raise ArgumentError, "Invalid MAC format: #{str}"
    end
  end

  # 从段数组构建 @numbers（固定 6 字节整数）和 @number。
  # 支持 3 段（每段 2 字节）和 6 段（每段 1 字节）。
  def build_from_sequence(seq)
    case seq.size
    when 3
      @numbers = seq.flat_map { |seg| split_two_byte_segment(seg) }
    when 6
      @numbers = seq.map { |seg| parse_segment(seg, 1) }
    else
      raise ArgumentError, "MAC segment count error: #{seq.size} (expected 3 or 6)"
    end
    compute_number
  end

  # 解析单段为指定字节数的整数，含范围校验。
  def parse_segment(seg, bytes)
    val = if seg.is_a?(String)
            raise ArgumentError, "Invalid hex segment: #{seg}" unless seg.match?(/\A[0-9a-fA-F]+\z/)
            seg.to_i(16)
          else
            seg.to_i
          end
    max = (1 << (bytes * 8)) - 1
    unless (0..max).include?(val)
      raise ArgumentError, "MAC segment out of range (0-#{max}): #{seg}"
    end
    val
  end

  # 解析 2 字节段，拆为高/低两个单字节。
  def split_two_byte_segment(seg)
    val = parse_segment(seg, 2)
    [(val >> 8) & 0xFF, val & 0xFF]
  end

  def compute_number
    @number = @numbers.map.with_index { |n, i| n << ((5 - i) * 8) }.sum
  end
end

# MAC 统一入口模块。
#
# 用法：
#   MAC.address("00:1A:2B:3C:4D:5E")
#   MAC.address("001A.2B3C.4D5E")
#   MAC.address(0x001A2B3C4D5E)
#   MAC.address([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
module MAC
  module_function

  def address(arg, _ = "-")
    MacAddress.new(arg)
  end
end
