# coding: utf-8
# frozen_string_literal: true

# 虚拟路由器：组合 RIB + LpmTrie + StaticRoute + RIP/OSPF/BGP 实例 + 接口表。
#
# 每个协议实例是 support 组件的薄封装，只加邻居关系和报文收发口。
# 对外暴露 receive_packet、announce、install_route。
# 协议实例按接口绑定邻居。
#
# 用法：
#   router = Router.new(name: "R1", interfaces: {"Gi0/0" => "10.0.0.1/24"})
#   router.enable_ospf(router_id: "1.1.1.1")
#   router.enable_rip
#   router.receive_packet(port: "Gi0/0", frame: frame)
#   router.rib_dump

require_relative '../../../support/routing/rib'
require_relative '../../../support/routing/lpm_trie'
require_relative '../../../support/routing/static_route'
require_relative '../../../support/routing/rip'
require_relative '../../../support/routing/ospf'
require_relative '../../../support/routing/bgp'
require_relative '../../../support/basic/packet'

module NetworkInfraUtility
  module SimLab
    module Device
      class Router
        attr_reader :name, :interfaces, :rib, :static_route
        attr_reader :rip, :ospf, :bgp, :capabilities

        def initialize(name:, interfaces: {}, **opts)
          @name          = name
          @interfaces    = {}  # port => {ip:, prefix_len:, status:}
          @rib           = RIB.new
          @static_route  = StaticRoute.new
          @capabilities  = Set.new
          @protocols     = {}
          @current_time  = 0

          # 初始化接口
          interfaces.each do |port, cidr|
            add_interface(port, cidr)
          end
        end

        # 添加接口。
        def add_interface(port, cidr)
          ip_str, mask_str = cidr.split('/')
          prefix_len = mask_str.to_i
          @interfaces[port] = {
            ip: ip_str,
            prefix_len: prefix_len,
            cidr: cidr,
            status: :up
          }

          # 安装直连路由
          network = compute_network(cidr)
          @rib.add(
            prefix: network,
            next_hop: '0.0.0.0',
            ifindex: port,
            protocol: :connected,
            metric: 0
          )
        end

        # 接口 down。
        def interface_down(port)
          return unless @interfaces[port]
          @interfaces[port][:status] = :down

          # 移除直连路由
          network = compute_network(@interfaces[port][:cidr])
          @rib.delete(network, protocol: :connected)

          # 通知协议
          @protocols.each_value { |p| p.respond_to?(:remove_neighbor_by_port) && p.remove_neighbor_by_port(port) }
        end

        # 接口 up。
        def interface_up(port)
          return unless @interfaces[port]
          @interfaces[port][:status] = :up

          # 恢复直连路由
          network = compute_network(@interfaces[port][:cidr])
          @rib.add(
            prefix: network,
            next_hop: '0.0.0.0',
            ifindex: port,
            protocol: :connected,
            metric: 0
          )
        end

        # 启用 OSPF。
        def enable_ospf(router_id:, area: "0.0.0.0")
          @ospf = OSPF.new(router_id: router_id, rib: @rib, area: area)
          @protocols[:ospf] = @ospf
          @capabilities.add(:ospf)

          # 注册直连网络
          @interfaces.each do |port, info|
            next if info[:status] == :down
            network = compute_network(info[:cidr])
            @ospf.add_connected(network, port)
          end

          @ospf
        end

        # 添加 OSPF 邻居。
        def add_ospf_neighbor(neighbor_rid, port:, cost: 10)
          @ospf&.add_neighbor(neighbor_rid, port: port, cost: cost)
        end

        # 启用 RIP。
        def enable_rip(split_horizon: true, poison_reverse: false)
          @rip = RIP.new(
            router_id: @name,
            rib: @rib,
            split_horizon: split_horizon,
            poison_reverse: poison_reverse
          )
          @protocols[:rip] = @rip
          @capabilities.add(:rip)

          # 注册直连网络
          @interfaces.each do |port, info|
            next if info[:status] == :down
            network = compute_network(info[:cidr])
            @rip.add_connected(network, port)
          end

          @rip
        end

        # 添加 RIP 邻居。
        def add_rip_neighbor(neighbor_name, port:, metric: 1)
          @rip&.add_neighbor(neighbor_name, port: port, metric: metric)
        end

        # 启用 BGP。
        def enable_bgp(as:, router_id: nil)
          @bgp = BGP.new(as: as, router_id: router_id || @interfaces.values.first&.dig(:ip), rib: @rib)
          @protocols[:bgp] = @bgp
          @capabilities.add(:bgp)
          @bgp
        end

        # 添加 BGP 邻居。
        def add_bgp_peer(addr, remote_as:, port: nil)
          @bgp&.add_peer(addr, remote_as: remote_as, port: port)
        end

        # BGP 宣告网络。
        def announce_network(prefix, **opts)
          @bgp&.announce_network(prefix, **opts)
        end

        # 安装静态路由。
        def install_static_route(prefix, next_hop, **opts)
          @static_route.install(prefix, next_hop, **opts)
          @rib.add(
            prefix: prefix,
            next_hop: next_hop,
            ifindex: opts[:ifindex],
            protocol: :static,
            metric: opts[:distance] || 1
          )
        end

        # 接收报文。
        # port: 入接口
        # payload: EthernetFrame 或协议消息
        def receive_packet(port:, payload:)
          return unless @interfaces[port] && @interfaces[port][:status] == :up

          case payload
          when EthernetFrame
            handle_frame(port, payload)
          when IPPacket
            handle_ip_packet(port, payload)
          when RIPUpdate
            @rip&.receive_update(from: payload.from, port: port, routes: payload.routes)
          when LSA
            @ospf&.receive_lsa(port: port, lsa: payload)
          when BGPUpdate
            @bgp&.receive_update(from: payload.from, **{ nlri: payload.nlri, withdrawn: payload.withdrawn, attributes: payload.attributes })
          end
        end

        # 生成要发送的协议消息。
        # 返回 [{port:, payload:}] 列表
        def announce
          messages = []

          if @rip
            @rip.advertise_all.each do |neighbor, routes|
              next if routes.empty?
              port = @rip.neighbors.dig(neighbor, :port)
              messages << { port: port, payload: RIPUpdate.new(from: @name, routes: routes) } if port
            end
          end

          if @ospf && @ospf.my_lsa
            @ospf.neighbors.each do |rid, info|
              messages << { port: info[:port], payload: @ospf.my_lsa }
            end
          end

          if @bgp
            @bgp.peers.each do |addr, info|
              next if info[:state] != :established
              adv = @bgp.advertise(addr)
              next unless adv
              messages << {
                port: info[:port],
                payload: BGPUpdate.new(
                  from: addr,
                  nlri: adv[:nlri],
                  withdrawn: [],
                  attributes: adv[:attributes]
                )
              }
            end
          end

          messages
        end

        # 由 engine 驱动的时钟推进。
        def tick(now:)
          @current_time = now
          @protocols.each_value { |p| p.tick(now: now) if p.respond_to?(:tick) }
        end

        # 转发 IP 报文。
        # 返回 [{port:, payload:}] 或 nil（丢弃）。
        def forward_ip(ip_packet)
          return nil if ip_packet.expired?

          route = @rib.lookup(ip_packet.dst)
          return nil unless route  # 无路由，丢弃

          ip_packet.decrement_ttl
          return nil if ip_packet.expired?

          [{ port: route.ifindex, payload: ip_packet }]
        end

        # RIB 快照。
        def rib_dump
          @rib.to_h
        end

        # 协议表快照。
        def protocol_dump
          result = {}
          result[:rip]  = @rip&.to_h
          result[:ospf] = @ospf&.lsdb_dump
          result[:bgp]  = @bgp&.to_h
          result
        end

        # 能力列表。
        def capable?(cap)
          @capabilities.include?(cap)
        end

        # 设备信息。
        def to_h
          {
            name: @name,
            type: :router,
            interfaces: @interfaces,
            capabilities: @capabilities.to_a,
            rib_size: @rib.size
          }
        end

        # 构建（初始化后调用）。
        def build
          # 触发初始 LSA/路由通告
          @protocols.each_value do |p|
            p.originate_lsa if p.is_a?(OSPF)
          end
        end

        private

        def handle_frame(port, frame)
          # 如果是 IP 报文，执行路由转发
          if frame.ip?
            handle_ip_packet(port, frame.payload)
          elsif frame.arp?
            # 简化：不处理 ARP
          end
        end

        def handle_ip_packet(port, packet)
          # 检查是否是给本设备的
          if is_local_address?(packet.dst)
            # 本地接收，不转发
            return
          end

          # 转发
          forward_ip(packet)
        end

        def is_local_address?(ip)
          @interfaces.each_value do |info|
            return true if info[:ip] == ip.to_s
          end
          false
        end

        def compute_network(cidr)
          ip_str, mask_str = cidr.split('/')
          ip = IPv4.new(ip_str)
          mask = IPv4Mask.number(mask_str.to_i)
          ip.network_with(mask).to_s + "/#{mask_str}"
        end
      end
    end
  end
end
