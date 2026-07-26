# coding: utf-8
# frozen_string_literal: true

# IP 统一入口模块。
#
# 提供 v4 / v6 / range / cross / xross 五个模块方法，
# 内部按地址串是否含 '.' ':' 自动分派到 IPv4 / IPv6。
require_relative 'ipv4_address'
require_relative 'ipv6_address'

module IP
  module_function

  # 解析 IPv4 地址或 CIDR。
  # string 不含 '/' → 返回 IPv4
  # string 含 '/'   → 返回 [IPv4, IPv4Mask]
  def v4(string)
    ip, msk = string.split('/')
    return IPv4.new(ip) unless msk

    mask = msk.include?('.') ? IPv4Mask.string(msk) : IPv4Mask.number(msk.to_i)
    [IPv4.new(ip), mask]
  end

  # 解析 IPv6 地址或 CIDR。
  # string 不含 '/' → 返回 IPv6
  # string 含 '/'   → 返回 [IPv6, IPv6Mask]
  def v6(string)
    ip, msk = string.split('/')
    return IPv6.new(ip) unless msk

    mask = msk.include?(':') ? IPv6Mask.string(msk) : IPv6Mask.number(msk.to_i)
    [IPv6.new(ip), mask]
  end

  # 展开一个地址区间，返回 [start, end]。
  # 支持三种输入：
  #   CIDR  '1.0.4.0/22'   → [网络地址, 广播地址]
  #   区间  '1.0.4.0-1.0.7.255' → [起始, 结束]
  #   单址  '1.0.4.0'      → [addr, addr]
  # 自动按 '.' ':' 区分 v4 / v6。
  def range(addr)
    return expand_dash_range(addr) if addr.include?('-')

    if addr.include?('.')
      gateway, netmask = v4(addr)
    elsif addr.include?(':')
      gateway, netmask = v6(addr)
    else
      raise ArgumentError, "Unrecognized address #{addr}"
    end

    if netmask
      network = gateway.network_with(netmask)
      network.range_with(netmask)
    else
      [gateway, gateway]
    end
  end

  # 两个闭区间是否相交。参数为 [start, end] 形式，元素需可比较。
  def cross(range1, range2)
    s1, e1 = range1
    s2, e2 = range2
    (s1 <= s2 && s2 <= e1) ||
      (s1 <= e2 && e2 <= e1) ||
      (s2 <= s1 && s1 <= e2) ||
      (s2 <= e1 && e1 <= e2)
  end

  # 求两个区间的合并并集端点。
  # 返回排序去重后的端点序列，转换为 IP 对象。
  # option: :v4 或 :v6，决定从 0 地址起算。
  def xross(range1, range2, option = :v4)
    s1, e1 = range1
    s2, e2 = range2
    base_addr = option == :v6 ? '::' : '0.0.0.0'
    [s1, e1, s2, e2].sort.uniq.map { |n| IP.send(option, base_addr) + n }
  end

  # 处理 'start-end' 形式的区间串。
  # 递归解析两端各自可能是 CIDR 或单址，最终 flatten 成 [start, end]。
  def expand_dash_range(addr)
    sddr, eddr = addr.split('-')
    [range(sddr).first, range(eddr).last]
  end
  module_function :expand_dash_range
end
