# coding: utf-8
# frozen_string_literal: true

# IPv4 地址与掩码工具。
#
# 用法：
#   ip, mask = IP.v4('10.37.214.42/17')
#   net = ip.network_with(mask)
#   p ip.to_d, mask.to_d, net.to_d
#   p ip.mask?, mask.mask?, net.network_with?(mask)
#   start_ip, end_ip = ip.range_with(mask)
#   p start_ip.to_d, end_ip.to_d
#
#   a = IP.v4('10.37.214.21/8')[0]
#   b = IP.v4('145.217.33.14/16')[0]
#   c = IP.v4('221.25.43.72/24')[0]
#   d = IP.v4('238.13.189.51')
#   e = IP.v4('246.211.74.63')
#   p a.class_a?, b.class_b?, c.class_c?, d.class_d?, e.class_e?
#   p a.private?, b.private?

require 'ipaddr'

# IPv4 地址。
#
# 持有四个 8 位段 @numbers 和 32 位整数 @number。
# 支持 CIDR 解析（通过 IP.v4）、掩码运算、范围展开、地址分类判断。
class IPv4
  attr_reader :numbers, :number

  # 解析地址串。支持十进制、0x 十六进制、0b 二进制三种前缀进制，
  # 前缀作用于整串所有段。形如 '10.0.0.1' / '0x0a.0.0.1' / '0b00001010.0.0.1111'。
  # 非法格式发 warn 并返回 self，使 IP.v4 仍拿到一个可判空的对象。
  def generate(string)
    unless /^(0[bdx])?([0-9a-fA-F]+\.){3}[0-9a-fA-F]+$/.match?(string)
      warn "Abnormal format string #{string}!"
      return self
    end
    @content, @mode = mode(string)
    fours = format_parts(@content, @mode)
    if valid?(fours)
      @numbers = fours
      @number = to_i
    else
      warn "Abnormal decimal string #{string}!"
    end
    self
  end

  def initialize(string)
    generate(string)
  end

  # ---- 进制解析 ----

  # 拆出前缀与本体。'0b'/'0x'/'0d' 前缀原样保留为 mode，否则按十进制。
  def mode(string)
    if ['0b', '0x', '0d'].include?(string[0..1])
      [string[2..], string[0..1]]
    else
      [string, '0d']
    end
  end

  # 按 mode 把点分四段各自 eval 成整数。mode 前缀会被拼到每段前。
  def format_parts(string, mode)
    string.split('.').map { |part| eval("#{mode}#{part}") }
  end

  # 判断四段是否全落在 0..255 且共 4 段。
  def valid?(nums)
    nums.size == 4 && nums.all? { |n| (0..255).include?(n) }
  end

  # ---- 输出格式 ----

  def to_a
    @numbers
  end

  def to_d
    @numbers.map { |n| n.to_s(10) }.join('.')
  end

  def to_h
    @numbers.map { |n| '%02x' % n }.join('.')
  end

  def to_b
    @numbers.map { |n| '%08b' % n }.join('.')
  end

  # 兼容原接口：to_s 即十进制点分。
  def to_s
    to_d
  end

  private

  # 32 位整数表示，内部缓存计算结果。
  def to_i
    @numbers.map { |n| '%08b' % n }.join.to_i(2)
  end

  # 从 32 位整数值构造新地址。
  def rebuild_from_number(n)
    bin = '%032b' % (n & 0xFFFFFFFF)
    dotted = bin.unpack('a8a8a8a8').join('.')
    IPv4.new('0b' + dotted)
  end

  public

  # ---- 算术运算（非破坏性，返回新对象）----

  # 加 num 个地址，返回新 IPv4。num 可为 Integer 或 IPv4（取其 number）。num 为负则等价于减法。
  def +(num)
    delta = num.is_a?(IPv4) ? num.number : num
    new_number = (@number + delta) & 0xFFFFFFFF
    rebuild_from_number(new_number)
  end

  # 减 num 个地址，返回新 IPv4。
  def -(num)
    self.+(-num)
  end

  # 按位与。another 可为 IPv4（含 Mask 子类）或前缀长度 Integer。
  def &(another)
    target = case another
             when IPv4     then another
             when Integer  then IPv4Mask.number(another)
             else return self
             end
    new_addr = @numbers.each_with_index.map { |n, i| n & target.numbers[i] }
    IPv4.new(new_addr.join('.'))
  end

  # 子网划分。把当前网段按 sub_pref 前缀长度划分为若干子网，
  # 返回 [[subnet_ip, mask], ...]。base_pref/sub_pref 可为前缀长度或 IPv4/IPv4Mask。
  def delegation(base_pref, sub_pref)
    base_len = base_pref.is_a?(IPv4) ? base_pref.mask_counter : base_pref
    sub_len  = sub_pref.is_a?(IPv4)  ? sub_pref.mask_counter  : sub_pref
    return [] unless base_len && sub_len
    return [] unless base_len < sub_len
    return [] unless base_len <= 32 && sub_len <= 32

    base = self & base_len
    pref = IPv4Mask.number(sub_len)
    (0..(2**(sub_len - base_len) - 1)).map do |i|
      sub_ip = base + (i << (32 - sub_len))
      [sub_ip, pref]
    end
  end

  # ---- 地址分类 ----

  def class_a?
    (IPv4.new('10.0.0.0').number..IPv4.new('126.255.255.255').number).include?(@number)
  end

  def class_b?
    (IPv4.new('128.1.0.0').number..IPv4.new('191.255.255.255').number).include?(@number)
  end

  def class_c?
    (IPv4.new('192.0.1.0').number..IPv4.new('223.255.255.255').number).include?(@number)
  end

  def class_d?
    (IPv4.new('224.0.0.0').number..IPv4.new('239.255.255.255').number).include?(@number)
  end

  def class_e?
    (IPv4.new('240.0.0.0').number..IPv4.new('255.255.255.254').number).include?(@number)
  end

  def private?
    n = @number
    (IPv4.new('10.0.0.0').number..IPv4.new('10.255.255.255').number).include?(n) ||
      (IPv4.new('172.16.0.0').number..IPv4.new('172.31.255.255').number).include?(n) ||
      (IPv4.new('192.168.0.0').number..IPv4.new('192.168.255.255').number).include?(n)
  end

  def loopback?
    (IPv4.new('127.0.0.0').number..IPv4.new('127.255.255.255').number).include?(@number)
  end

  # 特殊地址：环回、全 1 广播、全 0。
  def special?
    [IPv4.new('127.0.0.1').number, IPv4.new('255.255.255.255').number,
     IPv4.new('0.0.0.0').number].include?(@number)
  end

  # 保留 is_another? 作为 special? 的兼容别名。
  alias is_another? special?

  # ---- 掩码判定 ----

  # 是否为合法网络掩码（前 1 后 0，无 01 交错）。
  def mask?
    !to_b.gsub('.', '').include?('01')
  end

  # 是否为反掩码（前 0 后 1，无 10 交错）。
  def anti_mask?
    !to_b.gsub('.', '').include?('10')
  end

  # 网络掩码的前缀长度。非掩码返回 nil。
  def mask_counter
    return nil unless mask?
    counter, msk = 0, to_b.gsub('.', '')
    while msk[-1] == '0'
      counter += 1
      msk = msk[0..-2]
    end
    32 - counter
  end

  # 反掩码的尾部 1 个数。非反掩码返回 nil。
  def anti_mask_counter
    return nil unless anti_mask?
    counter, msk = 0, to_b.gsub('.', '')
    while msk[-1] == '1'
      counter += 1
      msk = msk[0..-2]
    end
    counter
  end

  # 掩码对应的反掩码。非掩码返回 nil。
  def anti_mask
    return nil unless (counter = mask_counter)
    IPv4Mask.anti_number(counter)
  end

  # 反掩码对应的掩码。非反掩码返回 nil。
  def mask
    return nil unless (counter = anti_mask_counter)
    IPv4Mask.number(32 - counter)
  end

  # ---- 保留 is_ 前缀别名，兼容旧接口 ----

  alias is_mask?       mask?
  alias is_anti_mask?  anti_mask?
  alias is_private?    private?
  alias is_class_a?    class_a?
  alias is_class_b?    class_b?
  alias is_class_c?    class_c?
  alias is_class_d?    class_d?
  alias is_class_e?    class_e?

  # ---- 网络/范围 ----

  # 与掩码相与得到网络地址。
  def network_with(mask)
    new_addr = mask.numbers.each_with_index.map { |n, i| n & @numbers[i] }
    IPv4.new(new_addr.join('.'))
  end

  # 该网段的完整地址区间，含网络地址与广播地址。
  # 前缀 /32 时返回 [self, self]。
  def range_with(mask)
    return [self, self] if mask.mask_counter.to_i == 32
    net = network_with(mask)
    prefix = mask.mask_counter.to_i
    offset = 2**(32 - prefix) - 1
    [net, net + offset]
  end

  # 判断自身是否可作 mask 所在网段的网络地址。
  def network_with?(mask)
    msk_counter, msk = 0, mask.to_b.gsub('.', '')
    while msk[-1] == '0'
      msk_counter += 1
      msk = msk[0..-2]
    end
    nt_counter, nt = 0, to_b.gsub('.', '')
    while nt[-1] == '0'
      nt_counter += 1
      nt = nt[0..-2]
    end
    nt_counter >= msk_counter
  end
  alias is_network_with? network_with?

  # 两个地址的最长公共前缀长度。
  def prefix_with(another_ip)
    ip1 = to_b.gsub('.', '')
    ip2 = another_ip.to_b.gsub('.', '')
    count = 0
    count += 1 while ip1[count] == ip2[count] && count < 32
    count
  end

  # ---- 排序比较 ----

  include Comparable
  def <=>(other)
    @number <=> other.number
  end
end

# IPv4 掩码工厂，按前缀长度或字符串构造 IPv4（带掩码语义）。
class IPv4Mask
  class << self
    # 前缀长度 → 网络掩码。num 范围 0..32。
    def number(num)
      raise ArgumentError, "Invalid prefix length #{num}" unless (0..32).include?(num)
      str = '0b' + ('1' * num + '0' * (32 - num)).unpack('a8a8a8a8').join('.')
      IPv4.new(str)
    end

    # 字符串 → 网络掩码，校验其为合法掩码。
    def string(str)
      temp = IPv4.new(str)
      raise "Invalid net mask #{str}!" unless temp.mask?
      temp
    end

    # 反掩码前缀长度 (尾部 1 的个数) → 反掩码。
    def anti_number(num)
      str = '0b' + ('0' * num + '1' * (32 - num)).unpack('a8a8a8a8').join('.')
      IPv4.new(str)
    end

    # 字符串 → 反掩码，校验其为合法反掩码。
    def anti_string(str)
      temp = IPv4.new(str)
      raise "Invalid anti mask #{str}!" unless temp.anti_mask?
      temp
    end
  end
end
