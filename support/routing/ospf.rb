# coding: utf-8
# frozen_string_literal: true

# 链路状态路由协议（简化 OSPF）。
#
# 实现原理：邻接与 LSA 抽象（简化：不实现真实 DR/BDR 选举，但保留接口）；
# LSA 泛洪（收到新 LSA 转发给除来源外邻居）；Dijkstra SPF 计算最短路径树并生成路由；
# LSA 序列号防旧。
#
# 设计要点：
# - 纯内存，不感知仿真环境
# - 通过 tick(now) 被动推进
# - 路由出口唯一：通过 rib 参数安装路由
#
# 用法：
#   ospf = OSPF.new(router_id: "1.1.1.1", rib: rib)
#   ospf.add_neighbor("2.2.2.2", port: "Gi0/0", cost: 10)
#   ospf.receive_lsa(port: "Gi0/0", lsa: lsa)
#   ospf.spf  # => 计算最短路径并安装到 RIB

require 'set'
require_relative 'rib'

# 链路状态通告（LSA）。
LSA = Data.define(:router_id, :seq, :links, :age, :area) do
  def to_s
    "LSA[router=#{router_id} seq=#{seq} links=#{links.size} age=#{age}]"
  end

  alias inspect to_s
end

# 链路描述：router_id => cost
# links: [{router_id:, cost:, prefix:, prefix_cost:}]

class OSPF
  LSA_MAX_AGE = 3600
  SPF_DELAY    = 5    # SPF 延迟（秒）
  LSA_REFRESH  = 1800 # LSA 刷新间隔

  attr_reader :router_id, :neighbors, :lsdb, :area

  def initialize(router_id:, rib:, area: "0.0.0.0")
    @router_id = router_id
    @rib       = rib
    @area      = area
    @neighbors = {}  # router_id => {port:, cost:, state:}
    @lsdb      = {}  # router_id => LSA
    @seq_num   = 0
    @last_spf  = 0
    @current_time = 0
    @spf_pending  = false
  end

  # 添加邻居。
  def add_neighbor(router_id, port:, cost: 10)
    @neighbors[router_id] = { port: port, cost: cost, state: :full }
    # 自身的 LSA 也会变化
    originate_lsa
  end

  # 删除邻居（链路 down）。
  def remove_neighbor(router_id)
    @neighbors.delete(router_id)
    originate_lsa
  end

  # 接收 LSA。
  # port: 接收端口
  # lsa: LSA 对象
  # 返回需要泛洪给其他邻居的 LSA（如果 LSA 是新的或更新的）
  def receive_lsa(port:, lsa:)
    existing = @lsdb[lsa.router_id]

    # 序列号防旧：只接受更新的 LSA
    if existing && lsa.seq <= existing.seq
      return nil
    end

    @lsdb[lsa.router_id] = lsa
    @spf_pending = true

    # 标记需要泛洪给除来源外的邻居
    lsa
  end

  # 泛洪 LSA 给除来源端口外的所有邻居。
  # 返回 { neighbor_router_id => port } 表示需要发送的邻居列表。
  def flood_targets(except_port:)
    neighbors.each_with_object({}) do |(rid, info), hash|
      next if info[:port] == except_port
      hash[rid] = info[:port]
    end
  end

  # 生成自身的 LSA。
  def originate_lsa
    @seq_num += 1
    links = neighbors.map do |rid, info|
      { router_id: rid, cost: info[:cost] }
    end
    # 加入直连前缀
    @connected_prefixes&.each do |prefix, port_info|
      links << { prefix: prefix, prefix_cost: port_info[:cost] || 1 }
    end

    lsa = LSA.new(
      router_id: @router_id,
      seq: @seq_num,
      links: links,
      age: 0,
      area: @area
    )
    @lsdb[@router_id] = lsa
    lsa
  end

  # Dijkstra SPF 计算。
  # 返回 { destination_router_id => {cost:, next_hop:} }
  def dijkstra
    return {} unless @lsdb[@router_id]

    dist = {}       # router_id => cost
    prev = {}       # router_id => prev_router_id
    visited = Set.new

    dist[@router_id] = 0
    # 下一跳映射
    first_hop = {}  # router_id => first_hop_router_id

    queue = [[0, @router_id]]

    until queue.empty?
      queue.sort_by! { |c, _| c }
      cost, node = queue.shift
      next if visited.include?(node)

      visited.add(node)

      lsa = @lsdb[node]
      next unless lsa

      lsa.links.each do |link|
        next unless link[:router_id]  # 只处理路由器间链路
        next if visited.include?(link[:router_id])

        new_cost = cost + link[:cost]
        if dist[link[:router_id]].nil? || new_cost < dist[link[:router_id]]
          dist[link[:router_id]] = new_cost
          prev[link[:router_id]] = node
          # 记录第一跳
          if node == @router_id
            first_hop[link[:router_id]] = link[:router_id]
          else
            first_hop[link[:router_id]] = first_hop[node]
          end
          queue << [new_cost, link[:router_id]]
        end
      end
    end

    { distances: dist, previous: prev, first_hops: first_hop }
  end

  # 执行 SPF 并安装路由到 RIB。
  # 返回安装的路由列表。
  def spf
    result = dijkstra
    installed = []

    result[:distances].each do |dest_rid, cost|
      next if dest_rid == @router_id
      next unless @lsdb[dest_rid]

      # 从目的路由器的 LSA 中提取前缀
      @lsdb[dest_rid].links.each do |link|
        next unless link[:prefix]

        next_hop_rid = result[:first_hops][dest_rid]
        next unless next_hop_rid
        next unless neighbors[next_hop_rid]

        installed_prefix = link[:prefix]
        @rib.add(
          prefix: installed_prefix,
          next_hop: neighbors[next_hop_rid][:port],  # 实际应是对端 IP，这里用端口标识
          ifindex: neighbors[next_hop_rid][:port],
          protocol: :ospf,
          metric: cost + (link[:prefix_cost] || 1)
        )
        installed << installed_prefix
      end
    end

    installed
  end

  # 由 engine 驱动的时钟推进。
  def tick(now:)
    @current_time = now

    # LSA 老化
    @lsdb.each_value do |lsa|
      # 在真实 OSPF 中 LSA age 会增长，这里简化
    end

    # SPF 延迟执行
    if @spf_pending && (now - @last_spf) >= SPF_DELAY
      @last_spf = now
      @spf_pending = false
      spf
      true
    else
      false
    end
  end

  # 添加直连前缀。
  def add_connected(prefix, port, cost: 1)
    @connected_prefixes ||= {}
    @connected_prefixes[prefix] = { port: port, cost: cost }
    @rib.add(
      prefix: prefix,
      next_hop: '0.0.0.0',
      ifindex: port,
      protocol: :connected,
      metric: 0
    )
    originate_lsa
  end

  # LSDB 快照。
  def lsdb_dump
    @lsdb.transform_values do |lsa|
      { seq: lsa.seq, links: lsa.links, age: lsa.age }
    end
  end

  # 获取自身最新 LSA。
  def my_lsa
    @lsdb[@router_id]
  end
end
