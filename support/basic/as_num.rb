# coding: utf-8
# frozen_string_literal: true

=begin
<< 16位AS号（2字节，传统）>>

| 类型        | 范围                | 说明                          |
| --------- | ----------------- | --------------------------- |
| **公有AS号** | **1 – 64511**     | 全球互联网可路由，需向RIR（区域互联网注册机构）申请 |
| **私有AS号** | **64512 – 65534** | 仅用于内部网络，不可通告到公网             |
| **保留**    | 0, 23456, 65535   | AS 0 保留、AS_TRANS、文档保留       |

<< 32位AS号（4字节，RFC 4893/6793）>>

| 类型        | 范围                                | 说明            |
| --------- | --------------------------------- | ------------- |
| **公有AS号** | **65536 – 4,199,999,999**         | 全球可路由（约42亿个）  |
| **私有AS号** | **4,200,000,000 – 4,294,967,294** | 内部使用（约9500万个） |
| **保留**    | 4,294,967,295                     | 保留（相当于32位全1）  |

<< 两种记法 >>

| 记法        | 示例           | 说明                         |
| --------- | ------------ | -------------------------- |
| **asplain** | `4259840001` | 纯十进制整数，32 位 AS 常用此记法       |
| **asdot**   | `1.10`       | 高16位.低16位，两段各 0 – 65535    |

转换关系：plain = high * 65536 + low；asdot = "high.low"
例：1.10 → 65546；65546 → "1.10"
=end

# AS 号工具。
#
# 用法：
#   as = ASNum.new("1.10")        # asdot 记法
#   ASNum.new("65546")            # asplain 记法
#   ASNum.new(65546)              # Integer 记法
#
#   as.to_i         # → 65546
#   as.to_plain     # → "65546"
#   as.to_dot       # → "1.10"
#   as.to_s         # → "1.10"（asdot 优先）或 "65546"（16位时纯数字）
#
#   as.public?      # → true / false
#   as.private?     # → true / false
#   as.reserved?    # → true / false
#   as.type         # → :public / :private / :reserved
#
#   as.as2?         # → 是否落在 16 位传统范围 (0 – 65535)
#   as.as4?         # → 是否为 32 位扩展号 (≥ 65536)
#
#   ASNum === ASNum # → Comparable 排序

class ASNum
  include Comparable

  attr_reader :number, :high, :low

  # AS 号范围常量
  AS2_MAX       = 65535
  AS4_MAX       = 4_294_967_295
  # 16 位
  PUB_16_MIN    = 1
  PUB_16_MAX    = 64_511
  PRIV_16_MIN   = 64_512
  PRIV_16_MAX   = 65_534
  # 32 位
  PUB_32_MIN    = 65_536
  PUB_32_MAX    = 4_199_999_999
  PRIV_32_MIN   = 4_200_000_000
  PRIV_32_MAX   = 4_294_967_294
  # 特殊保留
  RESERVED_16   = [0, 23_456, 65_535].freeze
  RESERVED_32   = 4_294_967_295

  # 从 String（asplain 或 asdot）或 Integer 构造。
  #
  # asplain 示例："65546" / 65546
  # asdot   示例："1.10"（高16位.低16位）
  def initialize(arg)
    @number = parse(arg)
    @high   = @number >> 16
    @low    = @number & 0xFFFF
    raise ArgumentError, "AS number out of range: #{arg}" unless valid_range?
  end

  # ---- 格式输出 ----

  # 十进制整数。
  def to_i
    @number
  end

  # asplain 字符串（纯十进制）。
  def to_plain
    @number.to_s
  end

  # asdot 字符串（高16位.低16位）。16 位范围内无点。
  def to_dot
    @number <= AS2_MAX ? @number.to_s : "#{@high}.#{@low}"
  end

  # 默认字符串：asdot 优先（16 位时回退为纯数字）。
  def to_s
    to_dot
  end

  alias inspect to_dot

  # ---- 类型判定 ----

  # 公有 AS 号。先排除保留号，再查范围，避免 AS_TRANS(23456) 同时命中。
  def public?
    !reserved? &&
      ((PUB_16_MIN..PUB_16_MAX).include?(@number) ||
       (PUB_32_MIN..PUB_32_MAX).include?(@number))
  end

  def private?
    !reserved? &&
      ((PRIV_16_MIN..PRIV_16_MAX).include?(@number) ||
       (PRIV_32_MIN..PRIV_32_MAX).include?(@number))
  end

  def reserved?
    RESERVED_16.include?(@number) || @number == RESERVED_32
  end

  # 一次性返回类型符号。
  def type
    return :public   if public?
    return :private  if private?
    return :reserved if reserved?
    :unknown
  end

  # ---- 位宽判定 ----

  # 是否为 16 位传统 AS 号（0 – 65535）。
  def as2?
    @number <= AS2_MAX
  end

  # 是否为 32 位扩展 AS 号（≥ 65536）。
  def as4?
    @number > AS2_MAX
  end

  # ---- 保留别名，兼容原接口 ----

  alias is_public_as?   public?
  alias is_private_as?  private?
  alias is_reserved_as? reserved?

  # ---- Comparable ----

  def <=>(other)
    @number <=> other.number
  end

  # hash 与 eql? 使 ASNum 可作 Hash key
  def hash
    @number.hash
  end

  def eql?(other)
    other.is_a?(ASNum) && @number == other.number
  end

  private

  # 解析输入为 32 位整数。
  def parse(arg)
    case arg
    when Integer
      arg
    when String
      parse_string(arg)
    else
      raise ArgumentError, "Cannot parse AS number from #{arg.class}"
    end
  end

  # 解析字符串：支持 asplain 和 asdot 两种记法。
  def parse_string(str)
    str = str.strip
    if str.include?(".")
      parse_asdot(str)
    else
      parse_asplain(str)
    end
  end

  # asplain：纯十进制整数串
  def parse_asplain(str)
    unless str.match?(/\A\d+\z/)
      raise ArgumentError, "Invalid AS number: #{str}"
    end
    str.to_i
  end

  # asdot：高16位.低16位，两段各 0 – 65535
  def parse_asdot(str)
    unless str.match?(/\A\d+\.\d+\z/)
      raise ArgumentError, "Invalid AS number: #{str}"
    end
    high, low = str.split(".")
    high_int = high.to_i
    low_int  = low.to_i
    unless (0..AS2_MAX).include?(high_int) && (0..AS2_MAX).include?(low_int)
      raise ArgumentError, "AS dot segment out of range (0-65535): #{str}"
    end
    high_int * 65536 + low_int
  end

  # 校验数值在 0 – 2^32-1 内
  def valid_range?
    (0..AS4_MAX).include?(@number)
  end
end
