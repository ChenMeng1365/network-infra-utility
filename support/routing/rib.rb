# coding: utf-8
# frozen_string_literal: true

# 路由信息库 RIB（Routing Information Base）。
#
# 增删改查路由条目，字段含 prefix/next_hop/ifindex/protocol/metric/tag。
# 支持多协议共存与优选排序，路由迭代时防环（区分 RIB/FIB 概念）。
#
# 设计要点：
# - 纯内存数据结构，不感知仿真环境
# - 所有协议通过 RIB#add 安装路由，唯一出口
# - 优选排序按 administrative distance + metric
#
# 用法：
#   rib = RIB.new
#   rib.add(prefix: "10.0.0.0/8", next_hop: "192.168.1.1", protocol: :ospf, metric: 10)
#   rib.lookup(IPv4.new("10.0.1.1"))  # => 最佳匹配的路由条目
#   rib.best("10.0.0.0/8")             # => 该前缀的优选路由

require_relative 'prefix'
require_relative 'lpm_trie'

# 路由条目：RIB 中的基本单位。
Route = Data.define(:prefix, :next_hop, :ifindex, :protocol, :metric, :tag) do
  def to_s
    "#{prefix} via #{next_hop} (#{protocol} metric=#{metric})"
  end

  alias inspect to_s
end

class RIB
  # 协议管理距离（优先级），值越小越优。
  ADMIN_DISTANCE = {
    connected:  0,
    static:     1,
    rip:       120,
    ospf:      110,
    isis:      115,
    bgp:        20,
    bgp_external: 20,
    bgp_internal: 200
  }.freeze

  attr_reader :routes_by_prefix

  def initialize
    # prefix_str => [Route, ...]  同前缀多协议共存
    @routes_by_prefix = Hash.new { |h, k| h[k] = [] }
    @fib = LpmTrie.new  # 最长前缀匹配 FIB 快照
    @dirty = false
  end

  # 添加路由条目。
  # prefix: CIDR 字符串或 Prefix 对象
  # next_hop: 下一跳 IP 字符串或 IPv4/IPv6
  # ifindex: 出接口标识（Symbol 或 String）
  # protocol: :connected/:static/:rip/:ospf/:isis/:bgp
  # metric: 路由度量值
  # tag: 可选标签
  def add(prefix:, next_hop:, ifindex: nil, protocol:, metric: 0, tag: nil)
    prefix_str = prefix.is_a?(Prefix) ? prefix.to_s : prefix
    route = Route.new(
      prefix: prefix_str,
      next_hop: next_hop.to_s,
      ifindex: ifindex,
      protocol: protocol,
      metric: metric,
      tag: tag
    )

    # 防止完全重复的路由
    existing = @routes_by_prefix[prefix_str]
    unless existing.any? { |r| same_route?(r, route) }
      existing << route
      @dirty = true
    end
    route
  end

  # 删除指定前缀和协议的路由。
  def delete(prefix, protocol: nil)
    prefix_str = prefix.is_a?(Prefix) ? prefix.to_s : prefix
    if protocol
      @routes_by_prefix[prefix_str].reject! { |r| r.protocol == protocol }
    else
      @routes_by_prefix.delete(prefix_str)
    end
    @routes_by_prefix.delete(prefix_str) if @routes_by_prefix[prefix_str] && @routes_by_prefix[prefix_str].empty?
    @dirty = true
  end

  # 查找某 IP 的最佳匹配路由（最长前缀匹配 + 优选）。
  def lookup(ip)
    rebuild_fib if @dirty
    @fib.match(ip)
  end

  # 获取指定前缀的优选路由。
  def best(prefix)
    prefix_str = prefix.is_a?(Prefix) ? prefix.to_s : prefix
    routes = @routes_by_prefix[prefix_str]
    return nil if routes.nil? || routes.empty?

    routes.min_by { |r| [admin_distance(r.protocol), r.metric] }
  end

  # 遍历所有前缀及其优选路由。
  def each(&blk)
    return to_enum(:each) unless block_given?

    @routes_by_prefix.each do |prefix_str, routes|
      b = routes.min_by { |r| [admin_distance(r.protocol), r.metric] }
      yield [prefix_str, b] if b
    end
  end

  # 所有路由条目（含非优选）。
  def all_routes
    @routes_by_prefix.values.flatten
  end

  # 优选路由数量。
  def size
    @routes_by_prefix.count { |_, routes| !routes.empty? }
  end

  # 清空所有路由。
  def clear
    @routes_by_prefix.clear
    @fib = LpmTrie.new
    @dirty = false
  end

  # 生成 FIB 快照（最长前缀匹配表）。
  def fib_snapshot
    rebuild_fib if @dirty
    @fib
  end

  # 快照为 Hash（便于观测/导出）。
  def to_h
    @routes_by_prefix.transform_values do |routes|
      routes.map { |r| { next_hop: r.next_hop, protocol: r.protocol, metric: r.metric, ifindex: r.ifindex } }
    end
  end

  private

  def rebuild_fib
    @fib = LpmTrie.new
    @routes_by_prefix.each do |prefix_str, routes|
      best_route = routes.min_by { |r| [admin_distance(r.protocol), r.metric] }
      @fib.insert(prefix_str, best_route) if best_route
    end
    @dirty = false
  end

  def admin_distance(protocol)
    ADMIN_DISTANCE.fetch(protocol, 255)
  end

  def same_route?(a, b)
    a.next_hop == b.next_hop && a.protocol == b.protocol &&
      a.metric == b.metric && a.ifindex == b.ifindex
  end
end
