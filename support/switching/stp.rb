# coding: utf-8
# frozen_string_literal: true

# 生成树协议（简化 STP）。
#
# 实现原理：BPDU 抽象（根桥 ID、根路径开销、发送桥 ID、端口 ID）；
# 根桥选举；根端口/指定端口/阻塞端口角色计算；拓扑变更事件输出。
#
# 设计要点：
# - 纯内存，不感知仿真环境
# - 通过 receive_bpdu(port, bpdu) 接收 BPDU
# - 通过 tick(now) 推进状态机
#
# 用法：
#   stp = STP.new(bridge_id: 4096, bridge_priority: 32768)
#   stp.add_port("Gi0/1", cost: 20000)
#   stp.receive_bpdu(port: "Gi0/1", bpdu: bpdu)
#   stp.roles  # => {"Gi0/1" => :root, "Gi0/2" => :designated, ...}

require 'set'

# BPDU 报文。
BPDU = Data.define(:root_id, :root_path_cost, :bridge_id, :port_id, :message_age, :max_age, :hello_time, :forward_delay) do
  def to_s
    "BPDU[root=#{root_id} cost=#{root_path_cost} bridge=#{bridge_id} port=#{port_id}]"
  end
end

class STP
  DEFAULT_PRIORITY   = 32768
  DEFAULT_HELLO       = 2   # 秒
  DEFAULT_FORWARD_DELAY = 15 # 秒
  DEFAULT_MAX_AGE     = 20  # 秒

  # 端口状态。
  PORT_STATES = {
    disabled: 0,
    blocking: 1,
    listening: 2,
    learning: 3,
    forwarding: 4
  }.freeze

  attr_reader :bridge_id, :ports, :root_id, :root_path_cost

  def initialize(bridge_id:, bridge_priority: DEFAULT_PRIORITY)
    @bridge_id        = bridge_id
    @bridge_priority  = bridge_priority
    @full_bridge_id   = (bridge_priority << 16) | bridge_id
    @root_id          = @full_bridge_id
    @root_path_cost   = 0
    @ports            = {}  # port_name => {cost:, state:, role:, designated_root:, designated_cost:, designated_bridge:, designated_port:}
    @current_time     = 0
    @hello_time       = DEFAULT_HELLO
    @forward_delay    = DEFAULT_FORWARD_DELAY
    @max_age          = DEFAULT_MAX_AGE
    @topology_change  = false
  end

  # 添加端口。
  def add_port(port, cost: 20000)
    @ports[port] = {
      cost: cost,
      state: :blocking,
      role: :designated,
      designated_root: @full_bridge_id,
      designated_cost: 0,
      designated_bridge: @full_bridge_id,
      designated_port: port.object_id,
      last_bpdu_time: 0
    }
  end

  # 删除端口。
  def remove_port(port)
    @ports.delete(port)
    recompute_roles
  end

  # 接收 BPDU。
  def receive_bpdu(port:, bpdu:)
    port_info = @ports[port]
    return unless port_info

    port_info[:last_bpdu_time] = @current_time

    # 更新端口收到的 BPDU 信息
    port_info[:designated_root]  = bpdu.root_id
    port_info[:designated_cost]  = bpdu.root_path_cost
    port_info[:designated_bridge] = bpdu.bridge_id
    port_info[:designated_port]  = bpdu.port_id

    # 根桥选举
    if bpdu.root_id < @root_id
      @root_id = bpdu.root_id
      @root_path_cost = bpdu.root_path_cost + port_info[:cost]
      recompute_roles
    elsif bpdu.root_id == @root_id
      # 相同根桥，比较路径开销
      new_cost = bpdu.root_path_cost + port_info[:cost]
      if new_cost < @root_path_cost
        @root_path_cost = new_cost
        recompute_roles
      end
    end

    # 拓扑变更检测
    @topology_change = true if bpdu.root_id != @root_id
  end

  # 生成自身 BPDU（根桥发送）。
  def generate_bpdu(port)
    BPDU.new(
      root_id: @root_id,
      root_path_cost: @root_path_cost,
      bridge_id: @full_bridge_id,
      port_id: port.object_id,
      message_age: 0,
      max_age: @max_age,
      hello_time: @hello_time,
      forward_delay: @forward_delay
    )
  end

  # 重新计算端口角色。
  def recompute_roles
    if @root_id == @full_bridge_id
      # 自身是根桥：所有端口为指定端口
      @ports.each_value do |info|
        info[:role] = :designated
        info[:state] = :forwarding
      end
      @root_path_cost = 0
    else
      # 非根桥：选举根端口和指定端口
      best_root_port = nil
      best_cost = Float::INFINITY

      @ports.each do |port_name, info|
        # 计算通过此端口到根桥的开销
        port_cost = info[:designated_cost] + info[:cost]

        if info[:designated_bridge] != @full_bridge_id
          # 对端 BPDU 来自其他桥
          if port_cost < best_cost || (port_cost == best_cost && best_root_port.nil?)
            best_cost = port_cost
            best_root_port = port_name
          end
        end
      end

      @ports.each do |port_name, info|
        if port_name == best_root_port
          info[:role] = :root
          info[:state] = :forwarding
        elsif info[:designated_bridge] == @full_bridge_id
          # 自身是指定桥
          info[:role] = :designated
          info[:state] = :forwarding
        else
          # 比较桥 ID 确定指定端口
          port_cost = info[:designated_cost] + info[:cost]
          if port_cost < info[:designated_cost]
            info[:role] = :designated
            info[:state] = :forwarding
          else
            info[:role] = :blocked
            info[:state] = :blocking
          end
        end
      end
    end
  end

  # 由 engine 驱动的时钟推进。
  def tick(now:)
    @current_time = now

    # 端口状态超时检查（简化）
    @ports.each_value do |info|
      if (now - info[:last_bpdu_time]) > @max_age && info[:role] != :designated
        # 超时未收到 BPDU
        info[:role] = :designated
        info[:state] = :forwarding
        @topology_change = true
      end
    end

    recompute_roles if @topology_change
    @topology_change = false
  end

  # 端口角色映射。
  def roles
    @ports.transform_values { |info| info[:role] }
  end

  # 端口状态映射。
  def states
    @ports.transform_values { |info| info[:state] }
  end

  # 是否为根桥。
  def root_bridge?
    @root_id == @full_bridge_id
  end

  # 转发端口列表。
  def forwarding_ports
    @ports.select { |_, info| info[:state] == :forwarding }.keys
  end

  # 阻塞端口列表。
  def blocked_ports
    @ports.select { |_, info| info[:state] == :blocking }.keys
  end

  # 快照。
  def to_h
    {
      bridge_id: @full_bridge_id,
      root_id: @root_id,
      root_path_cost: @root_path_cost,
      root_bridge: root_bridge?,
      ports: @ports.transform_values do |info|
        { role: info[:role], state: info[:state], cost: info[:cost] }
      end
    }
  end
end
