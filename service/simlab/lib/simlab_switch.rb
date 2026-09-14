# coding: utf-8
# frozen_string_literal: true

# 虚拟交换机：组合 MACTable + Forward + VLAN + STP。
#
# 数据平面逐帧处理流水线：
# 入端口 → VLAN 处理 → MAC 学习 → STP 状态检查 → 转发决策
#
# 与 router 的区别：router 跑控制平面协议，switch 默认只转发。
#
# 用法：
#   sw = Switch.new(name: "S1", ports: ["Gi0/1", "Gi0/2", "Gi0/3"])
#   sw.add_access_port("Gi0/1", pvid: 10)
#   sw.add_trunk_port("Gi0/24", allowed: [10, 20], native: 1)
#   sw.receive_frame(port: "Gi0/1", frame: frame)

require_relative '../../../support/switching/mac_table'
require_relative '../../../support/switching/frame_forward'
require_relative '../../../support/switching/vlan'
require_relative '../../../support/switching/stp'
require_relative '../../../support/basic/packet'

module NetworkInfraUtility
  module SimLab
    module Device
      class Switch
        attr_reader :name, :ports, :mac_table, :vlan, :stp, :forward

        def initialize(name:, ports: [], **opts)
          @name      = name
          @ports     = {}  # port_name => {status:}
          @mac_table = MACTable.new(aging_time: opts[:aging_time] || 300)
          @forward   = Forward.new
          @vlan      = VLAN.new
          @stp       = nil
          @current_time = 0

          ports.each { |p| add_port(p) }
        end

        # 添加端口。
        def add_port(port)
          @ports[port] = { status: :up }
        end

        # 端口 down。
        def port_down(port)
          return unless @ports[port]
          @ports[port][:status] = :down
          @mac_table.remove_by_port(port)
          @stp&.remove_port(port) if @stp
        end

        # 端口 up。
        def port_up(port)
          return unless @ports[port]
          @ports[port][:status] = :up
          @stp&.add_port(port) if @stp
        end

        # 添加 access 端口。
        def add_access_port(port, pvid:)
          add_port(port) unless @ports[port]
          @vlan.add_access_port(port, pvid: pvid)
        end

        # 添加 trunk 端口。
        def add_trunk_port(port, allowed:, native: nil)
          add_port(port) unless @ports[port]
          @vlan.add_trunk_port(port, allowed: allowed, native: native)
        end

        # 启用 STP。
        def enable_stp(bridge_id:, bridge_priority: STP::DEFAULT_PRIORITY)
          @stp = STP.new(bridge_id: bridge_id, bridge_priority: bridge_priority)
          @ports.each_key { |p| @stp.add_port(p, cost: 20000) }
          @stp
        end

        # 添加 STP 端口。
        def add_stp_port(port, cost: 20000)
          @stp&.add_port(port, cost: cost)
        end

        # 接收帧。
        # port: 入端口
        # frame: EthernetFrame
        # 返回 [{port:, frame:}] 列表（需要从哪些端口发出什么帧）
        def receive_frame(port:, frame:)
          return [] unless @ports[port] && @ports[port][:status] == :up

          # STP 状态检查
          if @stp
            port_state = @stp.states[port]
            # Blocking 状态不处理数据帧
            return [] if port_state == :blocking
          end

          # VLAN 入口处理
          tagged_frame = @vlan.ingress(frame, port: port)
          return [] unless tagged_frame  # VLAN 检查失败，丢弃

          # MAC 学习
          @mac_table.learn(frame.src_mac, port: port, now: @current_time)

          # 获取同 VLAN 端口列表
          vlan_id = tagged_frame.vlan_id
          vlan_ports = @vlan.ports_for_vlan(vlan_id)

          # 转发决策
          decision = @forward.decide(
            tagged_frame,
            in_port: port,
            mac_table: @mac_table,
            vlan_ports: vlan_ports
          )

          case decision.action
          when :forward, :flood
            decision.ports.map do |out_port|
              next unless @ports[out_port] && @ports[out_port][:status] == :up
              # STP 检查：非指定端口/根端口不转发（简化：只检查 forwarding 状态）
              if @stp && @stp.states[out_port] != :forwarding
                next
              end

              # VLAN 出口处理
              out_frame = @vlan.egress(tagged_frame, port: out_port)
              next unless out_frame

              { port: out_port, frame: out_frame }
            end.compact
          when :drop
            []
          end
        end

        # 由 engine 驱动的时钟推进。
        def tick(now:)
          @current_time = now

          # MAC 表老化
          @mac_table.age_out(now: now)

          # STP 状态机推进
          @stp&.tick(now: now)
        end

        # MAC 表快照。
        def mac_dump
          @mac_table.to_h
        end

        # VLAN 配置快照。
        def vlan_dump
          @vlan.to_h
        end

        # STP 快照。
        def stp_dump
          @stp&.to_h
        end

        # 设备信息。
        def to_h
          {
            name: @name,
            type: :switch,
            ports: @ports.keys,
            mac_entries: @mac_table.size,
            stp_enabled: !@stp.nil?
          }
        end

        # 构建。
        def build
          @stp&.recompute_roles
        end
      end
    end
  end
end
