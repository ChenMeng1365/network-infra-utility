# coding: utf-8
# frozen_string_literal: true

# CIDR 前缀对象：解析、规范化、包含/相等比较、主机位清零。
#
# 复用 support/basic/ip 的 IPv4/IPv6 数值化能力，同时支持 v4/v6。
#
# 用法：
#   p = Prefix.new("192.168.0.0/16")
#   p.include?(IPv4.new("192.168.1.1"))   # => true
#   p.superset_of?(Prefix.new("192.168.0.0/24"))  # => true
#   p.network_address.to_s  # => "192.168.0.0"
#   p.prefix_len             # => 16

require_relative '../basic/ip'

class Prefix
  include Comparable

  attr_reader :network, :prefix_len, :family

  # 从 CIDR 字符串构造。
  # "192.168.0.0/16" → IPv4, prefix_len=16
  # "fe80::/64"      → IPv6, prefix_len=64
  def initialize(cidr)
    if cidr.include?(':')
      @family = :ipv6
      addr_str, len_str = cidr.split('/')
      @network = IPv6.new(addr_str)
    else
      @family = :ipv4
      addr_str, len_str = cidr.split('/')
      @network = IPv4.new(addr_str)
    end
    @prefix_len = len_str.to_i
    normalize!
  end

  def to_s
    "#{network}/#{prefix_len}"
  end

  alias inspect to_s

  def to_cidr
    to_s
  end

  # 主机位清零后的网络地址。
  def network_address
    @network_address ||= begin
      mask = mask_for(prefix_len)
      network.network_with(mask)
    end
  end

  # 广播地址（IPv4 only）。
  def broadcast_address
    return nil unless family == :ipv4

    mask = mask_for(prefix_len)
    net = network.network_with(mask)
    _, bcast = net.range_with(mask)
    bcast
  end

  # 地址范围 [start, end]。
  def range
    mask = mask_for(prefix_len)
    net = network.network_with(mask)
    net.range_with(mask)
  end

  # 判断某 IP 是否在此前缀内。
  def include?(ip)
    ip = parse_ip(ip)
    mask = mask_for(prefix_len)
    masked_ip = ip.is_a?(IPv4) ? ip.network_with(mask) : ip_network_with(ip, mask)
    masked_self = network_address
    masked_ip == masked_self
  end

  # 判断自身是否是 other 的超集（包含关系）。
  def superset_of?(other)
    other.prefix_len >= prefix_len && include?(other.network)
  end

  # 判断自身是否是 other 的子集。
  def subset_of?(other)
    other.superset_of?(self)
  end

  # 两个前缀是否重叠（互相包含）。
  def overlaps?(other)
    superset_of?(other) || subset_of?(other)
  end

  # 前缀长度加 1，返回子网划分的两个子前缀。
  def subnets
    return [] if prefix_len >= max_len

    sub_len = prefix_len + 1
    base = network_address
    [
      self.class.new("#{base}/#{sub_len}"),
      self.class.new("#{(base + (1 << (max_len - sub_len)))}/#{sub_len}")
    ]
  end

  # Comparable：先按 family，再按网络地址，再按前缀长度。
  def <=>(other)
    return nil unless other.is_a?(Prefix)

    [family.to_s, network.number, prefix_len] <=>
      [other.family.to_s, other.network.number, other.prefix_len]
  end

  def hash
    [network.number, prefix_len, family].hash
  end

  def eql?(other)
    other.is_a?(Prefix) && network.number == other.network.number &&
      prefix_len == other.prefix_len && family == other.family
  end

  private

  def normalize!
    @network = network_address
  end

  def mask_for(len)
    if family == :ipv4
      IPv4Mask.number(len)
    else
      IPv6Mask.number(len)
    end
  end

  def max_len
    family == :ipv4 ? 32 : 128
  end

  def parse_ip(arg)
    return arg if arg.is_a?(IPv4) || arg.is_a?(IPv6)

    arg.include?(':') ? IPv6.new(arg) : IPv4.new(arg)
  end

  def ip_network_with(ip, mask)
    nums = ip.numbers.each_with_index.map { |n, i| n & mask.numbers[i] }
    IPv6.new(nums.map { |n| '%02x' % n }.join(':'))
  end
end
