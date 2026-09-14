# coding: utf-8
# frozen_string_literal: true

# 距离矢量路由协议（简化 RIP）。
#
# 实现原理：Bellman-Ford 更新；RIPv2 风格报文（路由项=目标/下一跳/metric）；
# 水平分割、毒性反转、hold-down、最大跳数 16 为不可达；触发更新。
#
# 设计要点：
# - 纯内存，不感知仿真环境
# - 通过 tick(now) 被动推进，不自己计时
# - 路由出口唯一：通过 rib 参数安装路由
#
# 用法：
#   rip = RIP.new(router_id: "R1", rib: rib)
#   rip.add_neighbor(:R2, port: "Gi0/0")
#   rip.receive_update(from: :R2, port: "Gi0/0", routes: [
#     {prefix: "10.0.0.0/8", next_hop: "192.168.1.2", metric: 1}
#   ])
#   rip.tick(now: 30)  # 由 engine 驱动

require_relative 'rib'

# RIP 路由更新报文。
RIPUpdate = Data.define(:from, :routes) do
  def to_s
    "RIP-Update[from=#{from} routes=#{routes.size}]"
  end
end

# RIP 路由项。
RIPRoute = Data.define(:prefix, :next_hop, :metric)

class RIP
  MAX_METRIC = 16   # 不可达
  UPDATE_INTERVAL = 30  # 默认更新间隔（秒）
  INVALID_TIMEOUT = 180 # 路由超时
  HOLD_DOWN       = 180 # hold-down 时间
  FLUSH_TIME      = 240 # 清除时间

  attr_reader :router_id, :routes, :neighbors

  # rib: RIB 实例，协议通过它安装路由
  # split_horizon: 是否启用水平分割
  # poison_reverse: 是否启用毒性反转
  def initialize(router_id:, rib:, split_horizon: true, poison_reverse: false)
    @router_id    = router_id
    @rib          = rib
    @split_horizon = split_horizon
    @poison_reverse = poison_reverse
    @neighbors    = {}  # name => {port:, metric: 1}
    @routes       = {} # prefix_str => {next_hop:, metric:, ifindex:, updated_at:, state:}
    @last_update  = 0
  end

  # 添加邻居。
  def add_neighbor(name, port:, metric: 1)
    @neighbors[name] = { port: port, metric: metric }
  end

  # 删除邻居。
  def remove_neighbor(name)
    @neighbors.delete(name)
  end

  # 接收邻居的路由更新。
  # from: 邻居名
  # port: 接收端口
  # routes: [{prefix:, next_hop:, metric:}]
  def receive_update(from:, port:, routes:)
    neighbor_metric = neighbors.dig(from, :metric) || 1
    changed = false

    routes.each do |r|
      prefix = r[:prefix]
      new_metric = r[:metric] + neighbor_metric
      new_metric = MAX_METRIC if new_metric > MAX_METRIC

      current = @routes[prefix]

      if current.nil?
        # 新路由
        if new_metric < MAX_METRIC
          @routes[prefix] = {
            next_hop: r[:next_hop] || from.to_s,
            metric: new_metric,
            ifindex: port,
            updated_at: @current_time || 0,
            state: :active
          }
          install_route(prefix, @routes[prefix])
          changed = true
        end
      elsif r[:next_hop] == current[:next_hop] || from.to_s == current[:next_hop]
        # 来自同一下一跳的更新
        if new_metric != current[:metric]
          if new_metric >= MAX_METRIC
            # 路由变为不可达
            @routes[prefix][:metric] = MAX_METRIC
            @routes[prefix][:state] = :holddown
            @routes[prefix][:updated_at] = @current_time || 0
            uninstall_route(prefix)
          else
            @routes[prefix][:metric] = new_metric
            @routes[prefix][:updated_at] = @current_time || 0
            @routes[prefix][:state] = :active
            install_route(prefix, @routes[prefix])
          end
          changed = true
        end
      elsif new_metric < current[:metric]
        # 更优路由
        @routes[prefix] = {
          next_hop: r[:next_hop] || from.to_s,
          metric: new_metric,
          ifindex: port,
          updated_at: @current_time || 0,
          state: :active
        }
        install_route(prefix, @routes[prefix])
        changed = true
      end
    end

    changed
  end

  # 生成要发送给指定邻居的路由更新。
  # 返回 [{prefix:, next_hop:, metric:}]
  def advertise(neighbor_name)
    port = neighbors.dig(neighbor_name, :port)
    result = []

    @routes.each do |prefix, info|
      next if info[:state] != :active && info[:state] != :holddown

      metric = info[:metric]

      # 水平分割：不从学到的接口回传
      if @split_horizon && info[:ifindex] == port
        next unless @poison_reverse
        metric = MAX_METRIC  # 毒性反转
      end

      result << {
        prefix: prefix,
        next_hop: info[:next_hop],
        metric: metric
      }
    end

    result
  end

  # 生成广播给所有邻居的路由更新。
  # 返回 { neighbor_name => [{prefix:, next_hop:, metric:}] }
  def advertise_all
    neighbors.keys.each_with_object({}) do |name, hash|
      hash[name] = advertise(name)
    end
  end

  # 由 engine 驱动的时钟推进。
  # now: 当前虚拟时间（秒）
  def tick(now:)
    @current_time = now

    # 路由超时检测
    @routes.each do |prefix, info|
      if info[:state] == :active && (now - info[:updated_at]) > INVALID_TIMEOUT
        @routes[prefix][:state] = :holddown
        @routes[prefix][:metric] = MAX_METRIC
        @routes[prefix][:updated_at] = now
        uninstall_route(prefix)
      elsif info[:state] == :holddown && (now - info[:updated_at]) > FLUSH_TIME
        @routes.delete(prefix)
      end
    end

    # 周期性更新触发
    if (now - @last_update) >= UPDATE_INTERVAL
      @last_update = now
      true  # 表示需要发送更新
    else
      false
    end
  end

  # 添加直连路由。
  def add_connected(prefix, port)
    @routes[prefix] = {
      next_hop: '0.0.0.0',
      metric: 0,
      ifindex: port,
      updated_at: @current_time || 0,
      state: :connected
    }
    install_route(prefix, @routes[prefix])
  end

  # 路由表快照。
  def to_h
    @routes.transform_values do |info|
      { next_hop: info[:next_hop], metric: info[:metric], state: info[:state] }
    end
  end

  private

  def install_route(prefix, info)
    @rib.add(
      prefix: prefix,
      next_hop: info[:next_hop],
      ifindex: info[:ifindex],
      protocol: :rip,
      metric: info[:metric]
    )
  end

  def uninstall_route(prefix)
    @rib.delete(prefix, protocol: :rip)
  end
end
