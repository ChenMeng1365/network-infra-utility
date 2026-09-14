# coding: utf-8
# frozen_string_literal: true

# 路径矢量路由协议（简化 BGP）。
#
# 实现原理：UPDATE 报文抽象（NLRI + attributes）；AS_PATH 防环；
# LOCAL_PREF / MED 优选顺序；简单的 import/export policy；
# iBGP/eBGP 角色区分。
#
# 设计要点：
# - 纯内存，不感知仿真环境
# - 通过 tick(now) 被动推进
# - 路由出口唯一：通过 rib 参数安装路由
#
# 用法：
#   bgp = BGP.new(as: 65001, router_id: "1.1.1.1", rib: rib)
#   bgp.add_peer("2.2.2.2", remote_as: 65002, port: "Gi0/0")
#   bgp.receive_update(from: "2.2.2.2", nlri: ["10.0.0.0/8"], attributes: {...})
#   bgp.decide  # => 优选路由

require 'set'
require_relative 'rib'

# BGP UPDATE 报文。
BGPUpdate = Data.define(:from, :nlri, :withdrawn, :attributes) do
  def to_s
    "BGP-UPDATE[from=#{from} nlri=#{nlri.size} withdrawn=#{withdrawn.size}]"
  end
end

# BGP 路由条目。
BGPRoute = Data.define(:prefix, :next_hop, :as_path, :local_pref, :med, :origin, :communities, :from_peer) do
  def as_path_length
    as_path&.size || 0
  end

  def as_path_includes?(as_num)
    as_path&.include?(as_num) || false
  end
end

class BGP
  attr_reader :as, :router_id, :peers, :routes

  def initialize(as:, router_id:, rib:)
    @as        = as
    @router_id = router_id
    @rib       = rib
    @peers     = {}   # peer_addr => {remote_as:, port:, type: :ebgp/:ibgp}
    @routes    = {}   # prefix_str => [BGPRoute, ...]
    @import_policies = []
    @export_policies = []
  end

  # 添加 BGP 邻居。
  # remote_as: 对端 AS 号
  # port: 连接端口标识
  def add_peer(addr, remote_as:, port: nil)
    peer_type = remote_as == @as ? :ibgp : :ebgp
    @peers[addr] = {
      remote_as: remote_as,
      port: port,
      type: peer_type,
      state: :established
    }
  end

  # 删除邻居。
  def remove_peer(addr)
    @peers.delete(addr)
    # 撤回该邻居发来的所有路由
    @routes.each_value do |route_list|
      route_list.reject! { |r| r.from_peer == addr }
    end
    @routes.delete_if { |_, list| list.empty? }
    reinstall_all
  end

  # 接收 UPDATE 报文。
  # from: peer 地址
  # nlri: 可达前缀列表 ["10.0.0.0/8", ...]
  # withdrawn: 撤回前缀列表
  # attributes: {next_hop:, as_path:, local_pref:, med:, origin:, communities:}
  def receive_update(from:, nlri: [], withdrawn: [], attributes: {})
    peer = peers[from]
    return unless peer

    # AS_PATH 防环
    if peer[:type] == :ebgp && attributes[:as_path]&.include?(@as)
      # 收到包含自身 AS 的路由，丢弃
      nlri = []
    end

    # 处理撤回
    withdrawn.each do |prefix|
      @routes[prefix]&.reject! { |r| r.from_peer == from }
      @routes.delete(prefix) if @routes[prefix]&.empty?
    end

    # 处理新路由
    nlri.each do |prefix|
      # 应用 import policy
      next unless apply_import_policy(prefix, attributes, peer)

      route = BGPRoute.new(
        prefix: prefix,
        next_hop: attributes[:next_hop],
        as_path: attributes[:as_path] || [],
        local_pref: attributes[:local_pref] || 100,
        med: attributes[:med] || 0,
        origin: attributes[:origin] || :igp,
        communities: attributes[:communities] || [],
        from_peer: from
      )

      @routes[prefix] ||= []
      # 移除同来源旧路由
      @routes[prefix].reject! { |r| r.from_peer == from }
      @routes[prefix] << route
    end

    reinstall_all
  end

  # 生成发送给指定邻居的 UPDATE。
  # 返回 {nlri:, attributes:}
  def advertise(peer_addr)
    peer = peers[peer_addr]
    return nil unless peer

    nlri = []
    @routes.each do |prefix, route_list|
      best = decide_for_prefix(prefix)
      next unless best

      # iBGP 不转发从 iBGP 学到的路由（简化规则）
      if peer[:type] == :ibgp
        source_peer = peers[best.from_peer]
        next if source_peer && source_peer[:type] == :ibgp
      end

      # 应用 export policy
      next unless apply_export_policy(prefix, best, peer)

      nlri << prefix
    end

    return nil if nlri.empty?

    # 构造属性
    {
      nlri: nlri,
      attributes: {
        next_hop: '0.0.0.0',  # 简化：用自身
        as_path: [@as],       # 简化
        local_pref: 100,
        med: 0,
        origin: :igp
      }
    }
  end

  # BGP 路由优选决策。
  # 顺序：LOCAL_PREF > AS_PATH 长度 > ORIGIN > MED > eBGP > 下一跳
  def decide
    result = {}
    @routes.each do |prefix, route_list|
      best = decide_for_prefix(prefix)
      result[prefix] = best if best
    end
    result
  end

  # 单个前缀的优选。
  def decide_for_prefix(prefix)
    routes = @routes[prefix]
    return nil if routes.nil? || routes.empty?

    routes.min do |a, b|
      # 1. LOCAL_PREF（大优）
      cmp = b.local_pref <=> a.local_pref
      next cmp if cmp != 0
      # 2. AS_PATH 长度（短优）
      cmp = a.as_path_length <=> b.as_path_length
      next cmp if cmp != 0
      # 3. ORIGIN（IGP < EGP < INCOMPLETE）
      origin_order = { igp: 0, egp: 1, incomplete: 2 }
      cmp = origin_order[a.origin] <=> origin_order[b.origin]
      next cmp if cmp != 0
      # 4. MED（小优）
      cmp = a.med <=> b.med
      next cmp if cmp != 0
      # 5. eBGP 优先于 iBGP
      a_type = peers.dig(a.from_peer, :type) || :ibgp
      b_type = peers.dig(b.from_peer, :type) || :ibgp
      type_order = { ebgp: 0, ibgp: 1 }
      cmp = type_order[a_type] <=> type_order[b_type]
      next cmp if cmp != 0
      # 6. 下一跳（更小的 IP 优先，简化用字符串比较）
      a.next_hop <=> b.next_hop
    end
  end

  # 由 engine 驱动的时钟推进。
  def tick(now:)
    # BGP 主要是事件驱动，tick 用于 keepalive 等
    # 简化：不做实际操作
    false
  end

  # 添加 import policy 钩子。
  def add_import_policy(&blk)
    @import_policies << blk
  end

  # 添加 export policy 钩子。
  def add_export_policy(&blk)
    @export_policies << blk
  end

  # 注入本地路由到 BGP（network 命令）。
  def announce_network(prefix, next_hop: '0.0.0.0')
    @routes[prefix] ||= []
    @routes[prefix].reject! { |r| r.from_peer == :local }
    @routes[prefix] << BGPRoute.new(
      prefix: prefix,
      next_hop: next_hop,
      as_path: [],
      local_pref: 100,
      med: 0,
      origin: :igp,
      communities: [],
      from_peer: :local
    )
    reinstall_all
  end

  # BGP 表快照。
  def to_h
    @routes.transform_values do |list|
      list.map { |r| { next_hop: r.next_hop, as_path: r.as_path, from: r.from_peer, local_pref: r.local_pref } }
    end
  end

  private

  def apply_import_policy(prefix, attributes, peer)
    @import_policies.each do |policy|
      result = policy.call(prefix, attributes, peer)
      return false if result == :reject
    end
    true
  end

  def apply_export_policy(prefix, route, peer)
    @export_policies.each do |policy|
      result = policy.call(prefix, route, peer)
      return false if result == :reject
    end
    true
  end

  def reinstall_all
    # 先清除所有 BGP 路由
    rib_prefixes = @routes.keys
    rib_prefixes.each { |p| @rib.delete(p, protocol: :bgp) }

    # 重新安装优选路由
    decide.each do |prefix, best|
      @rib.add(
        prefix: prefix,
        next_hop: best.next_hop,
        ifindex: peers.dig(best.from_peer, :port),
        protocol: :bgp,
        metric: best.as_path_length
      )
    end
  end
end
