# coding: utf-8
# frozen_string_literal: true

# 流量与事件注入：host ping、持续数据流、链路 up/down 故障、节点启动/关闭。
#
# 把注入事件翻译成 engine 事件。
#
# 用法：
#   traffic = Traffic.new
#   traffic.ping(engine, topology, from: "H1", to: "10.0.0.2", at: 10)
#   traffic.flap_link(engine, topology, "R1", "Gi0/1", at: 50)
#   traffic.node_down(engine, topology, "R2", at: 100)

require_relative '../../../support/basic/packet'

module NetworkInfraUtility
  module SimLab
    class Traffic
      # 注入 ping 事件。
      # 从 from 设备向 to IP 发送 ICMP Echo。
      def ping(engine, topology, from:, to:, at:, count: 1, interval: 1)
        count.times do |i|
          engine.schedule(at: at + i * interval) do
            device = topology.devices[from]
            next unless device

            packet = IPPacket.new(
              src: device.interfaces.values.first&.dig(:ip),
              dst: to,
              ttl: 64,
              protocol: :icmp,
              payload: ICMPPacket.new(type: :echo_request, seq: i)
            )

            # 发送到默认网关
            route = device.forward_ip(packet)
            # route 将被 engine 投递到下一跳
            yield route if route && block_given?
          end
        end
      end

      # 注入链路 down 事件。
      def link_down(engine, topology, device_name, port, at:)
        engine.schedule(at: at) do
          device = topology.devices[device_name]
          next unless device

          if device.is_a?(Device::Router)
            device.interface_down(port)
          elsif device.is_a?(Device::Switch)
            device.port_down(port)
          end

          # 标记拓扑链路为 down
          link = topology.link_between(device_name, topology.peer_of(device_name, port)&.dig(:peer_device))
          link&.deactivate
        end
      end

      # 注入链路 up 事件。
      def link_up(engine, topology, device_name, port, at:)
        engine.schedule(at: at) do
          device = topology.devices[device_name]
          next unless device

          if device.is_a?(Device::Router)
            device.interface_up(port)
          elsif device.is_a?(Device::Switch)
            device.port_up(port)
          end

          # 标记拓扑链路为 up
          link = topology.link_between(device_name, topology.peer_of(device_name, port)&.dig(:peer_device))
          link&.activate
        end
      end

      # 链路 flapping。
      def flap_link(engine, topology, device_name, port, at:, times: 3, interval: 10)
        times.times do |i|
          if i.even?
            link_down(engine, topology, device_name, port, at: at + i * interval)
          else
            link_up(engine, topology, device_name, port, at: at + i * interval)
          end
        end
      end

      # 节点 down。
      def node_down(engine, topology, device_name, at:)
        engine.schedule(at: at) do
          device = topology.devices[device_name]
          next unless device

          if device.is_a?(Device::Router)
            device.interfaces.each_key { |port| device.interface_down(port) }
          elsif device.is_a?(Device::Switch)
            device.ports.each_key { |port| device.port_down(port) }
          end
        end
      end

      # 节点 up。
      def node_up(engine, topology, device_name, at:)
        engine.schedule(at: at) do
          device = topology.devices[device_name]
          next unless device

          if device.is_a?(Device::Router)
            device.interfaces.each_key { |port| device.interface_up(port) }
          elsif device.is_a?(Device::Switch)
            device.ports.each_key { |port| device.port_up(port) }
          end
        end
      end

      # 通用事件注入。
      def inject(engine, event)
        case event[:type]
        when :ping
          ping(engine, event[:topology], **event[:params])
        when :link_down
          link_down(engine, event[:topology], **event[:params])
        when :link_up
          link_up(engine, event[:topology], **event[:params])
        when :node_down
          node_down(engine, event[:topology], **event[:params])
        when :node_up
          node_up(engine, event[:topology], **event[:params])
        else
          engine.schedule(at: event[:at] || 0, &event[:block]) if event[:block]
        end
      end

      # 协议更新注入：触发路由协议消息交换。
      def protocol_exchange(engine, topology, at:)
        engine.schedule(at: at) do
          topology.routers.each_value do |router|
            messages = router.announce
            messages.each do |msg|
              # 找到对端设备
              adj = topology.peer_of(router.name, msg[:port])
              next unless adj

              peer = topology.devices[adj[:peer_device]]
              next unless peer

              engine.schedule_delayed(delay: 0) do
                peer.receive_packet(port: adj[:peer_port], payload: msg[:payload])
              end
            end
          end
        end
      end

      # 周期性协议交换。
      def periodic_exchange(engine, topology, interval: 10, until_time: 100)
        t = 0
        while t < until_time
          protocol_exchange(engine, topology, at: t)
          t += interval
        end
      end
    end
  end
end
