# coding: utf-8
# frozen_string_literal: true

# IPv6 地址与掩码工具。
#
# 用法：
#   ip, mask = IP.v6('2001:db8::1/64')
#   net = ip.network_with(mask)
#   start_ip, end_ip = ip.range_with(mask)

require 'ipaddr'

# IPv6 地址。
#
# 持有八个 16 位段 @numbers 和 128 位整数 @number。
# 解析借助标准库 IPAddr 展开压缩形式，再统一为点分十六进制段。
class IPv6
  attr_reader :numbers, :number

  # 解析地址串。借助 IPAddr 还原 '::' 压缩为完整 8 段十六进制；
  # 非法地址抛异常（与 IPv4 的 warn 行为不同，沿用原作者设计）。
  def generate(string)
    @content = IPAddr.new(string).to_string
    @mode = '0x'
    eights = format_parts(@content, @mode)
    @numbers = eights
    @number = to_i
    self
  rescue IPAddr::InvalidAddressError => e
    raise "Abnormal format string #{string}! #{e.message}"
  end

  def initialize(string)
    generate(string)
  end

  # ---- 进制解析 ----

  def mode(string)
    [IPAddr.new(string).to_string, '0x']
  end

  def format_parts(string, mode = '0x')
    string.split(':').map { |part| eval("#{mode}#{part}") }
  end

  private

  def to_i
    @numbers.map { |n| '%016b' % n }.join.to_i(2)
  end

  def rebuild_from_hex(hex_str)
    IPv6.new(hex_str.unpack('a4a4a4a4a4a4a4a4').join(':'))
  end

  public

  # ---- 输出格式 ----

  def to_a
    @numbers
  end

  def to_d
    @numbers.map { |n| n.to_s(10) }.join(':')
  end

  def to_h
    @numbers.map { |n| '%04x' % n }.join(':')
  end

  def to_b
    @numbers.map { |n| '%016b' % n }.join(':')
  end

  # 压缩形式（ '::' 形态），借助 IPAddr 还原。
  def to_s
    IPAddr.new(@content).to_s
  end

  alias to_s_short to_s

  def to_s_full
    to_h
  end

  # ---- 算术运算（非破坏性）----

  def +(num)
    delta = num.is_a?(IPv6) ? num.number : num
    new_number = (@number + delta)
    new_number &= (1 << 128) - 1 if delta < 0 && new_number < 0
    rebuild_from_hex('%032x' % new_number)
  end

  def -(num)
    self.+(-num)
  end

  def &(another)
    target = case another
             when IPv6     then another
             when Integer  then IPv6Mask.number(another)
             else return self
             end
    new_addr = @numbers.each_with_index.map { |n, i| n & target.numbers[i] }
    IPv6.new(new_addr.map { |n| '%04x' % n }.join(':'))
  end

  def delegation(base_pref, sub_pref)
    base_len = base_pref.is_a?(IPv6) ? base_pref.mask_counter : base_pref
    sub_len  = sub_pref.is_a?(IPv6)  ? sub_pref.mask_counter  : sub_pref
    return [] unless base_len && sub_len
    return [] unless base_len < sub_len
    return [] unless base_len <= 128 && sub_len <= 128

    base = self & base_len
    pref = IPv6Mask.number(sub_len)
    (0..(2**(sub_len - base_len) - 1)).map do |i|
      sub_ip = base + (i << (128 - sub_len))
      [sub_ip, pref]
    end
  end

  # ---- 掩码判定 ----

  def mask?
    !to_b.gsub(':', '').include?('01')
  end

  def anti_mask?
    !to_b.gsub(':', '').include?('10')
  end

  def mask_counter
    return nil unless mask?
    counter, msk = 0, to_b.gsub(':', '')
    while msk[-1] == '0'
      counter += 1
      msk = msk[0..-2]
    end
    128 - counter
  end

  def anti_mask_counter
    return nil unless anti_mask?
    counter, msk = 0, to_b.gsub(':', '')
    while msk[-1] == '1'
      counter += 1
      msk = msk[0..-2]
    end
    counter
  end

  def anti_mask
    return nil unless (counter = mask_counter)
    IPv6Mask.anti_number(counter)
  end

  def mask
    return nil unless (counter = anti_mask_counter)
    IPv6Mask.number(128 - counter)
  end

  alias is_mask?      mask?
  alias is_anti_mask? anti_mask?

  # ---- 网络/范围 ----

  def network_with(mask)
    new_addr = mask.numbers.each_with_index.map { |n, i| n & @numbers[i] }
    IPv6.new(new_addr.map { |n| '%04x' % n }.join(':'))
  end

  # 完整地址区间，含网络地址与全 1 广播地址。
  def range_with(mask)
    return [self, self] if mask.mask_counter.to_i == 128
    net = network_with(mask)
    prefix = mask.mask_counter.to_i
    offset = 2**(128 - prefix) - 1
    [net, net + offset]
  end

  def network_with?(mask)
    msk_counter, msk = 0, mask.to_b.gsub(':', '')
    while msk[-1] == '0'
      msk_counter += 1
      msk = msk[0..-2]
    end
    nt_counter, nt = 0, to_b.gsub(':', '')
    while nt[-1] == '0'
      nt_counter += 1
      nt = nt[0..-2]
    end
    nt_counter >= msk_counter
  end
  alias is_network_with? network_with?

  def prefix_with(another_ip)
    ip1 = to_b.gsub(':', '')
    ip2 = another_ip.to_b.gsub(':', '')
    count = 0
    count += 1 while ip1[count] == ip2[count] && count < 128
    count
  end

  # ---- 排序比较 ----

  include Comparable
  def <=>(other)
    @number <=> other.number
  end
end

# IPv6 掩码工厂。
class IPv6Mask
  class << self
    def number(num)
      raise ArgumentError, "Invalid prefix length #{num}" unless (0..128).include?(num)
      hex = '%032x' % ('1' * num + '0' * (128 - num)).to_i(2)
      str = hex.unpack('a4a4a4a4a4a4a4a4').join(':')
      IPv6.new(str)
    end

    def string(str)
      temp = IPv6.new(str)
      raise "Invalid net mask #{str}!" unless temp.mask?
      temp
    end

    def anti_number(num)
      hex = '%032x' % ('0' * num + '1' * (128 - num)).to_i(2)
      str = hex.unpack('a4a4a4a4a4a4a4a4').join(':')
      IPv6.new(str)
    end

    def anti_string(str)
      temp = IPv6.new(str)
      raise "Invalid anti mask #{str}!" unless temp.anti_mask?
      temp
    end
  end
end
