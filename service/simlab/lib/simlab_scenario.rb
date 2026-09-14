# coding: utf-8
# frozen_string_literal: true

# 场景加载器：YAML DSL 描述拓扑 + 协议启用 + 流量计划，输出可执行场景对象。
#
# YAML 格式示例：
#   ---
#   topology:
#     routers:
#       R1:
#         interfaces:
#           Gi0/0: 10.0.0.1/24
#           Gi0/1: 10.0.1.1/24
#         ospf:
#           router_id: 1.1.1.1
#       R2:
#         interfaces:
#           Gi0/0: 10.0.0.2/24
#           Gi0/1: 10.0.2.1/24
#         ospf:
#           router_id: 2.2.2.2
#     switches:
#       S1:
#         ports: [Gi0/1, Gi0/2, Gi0/3]
#     links:
#       - [R1:Gi0/0, R2:Gi0/0, {bandwidth: 100000, delay: 10}]
#       - [R1:Gi0/1, S1:Gi0/1]
#     hosts:
#       H1:
#         ip: 10.0.2.2/24
#         gateway: 10.0.2.1
#   traffic:
#     - type: ping
#       from: R1
#       to: 10.0.0.2
#       at: 10
#     - type: link_down
#       device: R1
#       port: Gi0/0
#       at: 50
#   expect:
#     - rib_converged: [R1, R2]
#     - no_loss: true

require 'yaml'

module NetworkInfraUtility
  module SimLab
    class Scenario
      attr_reader :config

      def initialize(config = {})
        @config = config
      end

      # 从 YAML 文件加载。
      def self.load(file_path)
        content = File.read(file_path)
        config = YAML.safe_load(content, permitted_classes: [Symbol])
        new(config)
      end

      # 从 Hash 构建。
      def self.from_hash(config)
        new(config)
      end

      # 将场景应用到仿真对象。
      def apply_to(simulation)
        build_topology(simulation)
        build_traffic(simulation)
        build_expectations(simulation)
      end

      private

      def build_topology(simulation)
        topo = simulation.topology

        # 路由器
        config.dig('topology', 'routers')&.each do |name, props|
          router = topo.add_router(name, interfaces: props['interfaces'] || {})

          if props['ospf']
            router.enable_ospf(router_id: props['ospf']['router_id'])
          end

          if props['rip']
            router.enable_rip
          end

          if props['bgp']
            router.enable_bgp(as: props['bgp']['as'], router_id: props['bgp']['router_id'])
          end

          # 静态路由
          props['static_routes']&.each do |sr|
            router.install_static_route(sr['prefix'], sr['next_hop'])
          end
        end

        # 交换机
        config.dig('topology', 'switches')&.each do |name, props|
          sw = topo.add_switch(name, ports: props['ports'] || [])

          if props['access_ports']
            props['access_ports'].each do |port, pvid|
              sw.add_access_port(port, pvid: pvid)
            end
          end

          if props['trunk_ports']
            props['trunk_ports'].each do |port, cfg|
              sw.add_trunk_port(port, allowed: cfg['allowed'], native: cfg['native'])
            end
          end

          if props['stp']
            sw.enable_stp(bridge_id: props['stp']['bridge_id'])
          end
        end

        # 主机
        config.dig('topology', 'hosts')&.each do |name, props|
          topo.add_host(name, ip: props['ip'], gateway: props['gateway'])
        end

        # 链路
        config.dig('topology', 'links')&.each do |link|
          ep_a, ep_b, opts = link
          opts ||= {}
          topo.add_link(ep_a, ep_b,
            bandwidth: opts['bandwidth'] || 1_000_000,
            delay: opts['delay'] || 0,
            cost: opts['cost'] || 10
          )
        end

        # 协议邻居配置
        config.dig('protocols')&.each do |proto_name, proto_cfg|
          case proto_name
          when 'ospf'
            proto_cfg['neighbors']&.each do |nb|
              router = topo.devices[nb['router']]
              next unless router && router.capable?(:ospf)
              router.add_ospf_neighbor(nb['neighbor_rid'], port: nb['port'], cost: nb['cost'] || 10)
            end
          when 'rip'
            proto_cfg['neighbors']&.each do |nb|
              router = topo.devices[nb['router']]
              next unless router && router.capable?(:rip)
              router.add_rip_neighbor(nb['neighbor'], port: nb['port'])
            end
          when 'bgp'
            proto_cfg['peers']&.each do |peer|
              router = topo.devices[peer['router']]
              next unless router && router.capable?(:bgp)
              router.add_bgp_peer(peer['addr'], remote_as: peer['remote_as'], port: peer['port'])
            end
          end
        end
      end

      def build_traffic(simulation)
        traffic = Traffic.new

        config['traffic']&.each do |event|
          case event['type']
          when 'ping'
            traffic.ping(simulation.engine, simulation.topology,
              from: event['from'], to: event['to'],
              at: event['at'], count: event['count'] || 1)
          when 'link_down'
            traffic.link_down(simulation.engine, simulation.topology,
              event['device'], event['port'], at: event['at'])
          when 'link_up'
            traffic.link_up(simulation.engine, simulation.topology,
              event['device'], event['port'], at: event['at'])
          when 'node_down'
            traffic.node_down(simulation.engine, simulation.topology,
              event['device'], at: event['at'])
          end
        end

        # 周期性协议交换
        interval = config.dig('simulation', 'protocol_interval') || 10
        until_time = config.dig('simulation', 'until') || 100
        traffic.periodic_exchange(simulation.engine, simulation.topology,
          interval: interval, until_time: until_time)
      end

      def build_expectations(simulation)
        # 预期断言（简化：记录到 simulation）
        @expectations = config['expect'] || []
      end

      attr_reader :expectations
    end
  end
end
