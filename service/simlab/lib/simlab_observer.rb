# coding: utf-8
# frozen_string_literal: true

# 观测导出：RIB/MAC 快照、转发路径 trace、收敛时间统计。
#
# 输出 JSON/文本快照，便于断言和教学演示。
#
# 用法：
#   observer = Observer.new
#   observer.rib_dump(router)
#   observer.mac_dump(switch)
#   observer.trace(topology: topo, from: "H1", to: "10.0.0.2")

require 'json'
require 'set'

module NetworkInfraUtility
  module SimLab
    class Observer
      # RIB 快照。
      def rib_dump(device)
        device.rib_dump
      end

      # MAC 表快照。
      def mac_dump(device)
        device.mac_dump
      end

      # 转发路径追踪。
      # 返回 [{device:, port:, decision:}] 的跳转路径。
      def trace(topology:, from:, to:)
        path = []
        visited = Set.new
        current_device = topology.devices[from]

        return path unless current_device

        while current_device && !visited.include?(current_device.name)
          visited.add(current_device.name)

          if current_device.is_a?(Device::Router)
            # 路由器：查 RIB 确定下一跳
            route = current_device.rib.lookup(parse_ip(to))
            break unless route

            hop = {
              device: current_device.name,
              type: :router,
              port: route.ifindex,
              next_hop: route.next_hop,
              protocol: route.protocol
            }
            path << hop

            # 找对端设备
            adj = topology.peer_of(current_device.name, route.ifindex)
            break unless adj

            current_device = topology.devices[adj[:peer_device]]

          elsif current_device.is_a?(Device::Switch)
            # 交换机：查 MAC 表确定出端口
            mac_entry = current_device.mac_table.lookup(to)
            port = mac_entry ? mac_entry.port : nil

            hop = {
              device: current_device.name,
              type: :switch,
              port: port || 'flood',
              decision: mac_entry ? :forward : :flood
            }
            path << hop

            if port
              adj = topology.peer_of(current_device.name, port)
              break unless adj
              current_device = topology.devices[adj[:peer_device]]
            else
              break
            end
          else
            break
          end
        end

        path
      end

      # 收敛检测：统计 N 个 tick 内 RIB/MAC 是否无变化。
      def converged?(topology:, ticks:, engine:)
        # 简化实现：检查是否还有 pending 事件
        # 真实实现应比较 RIB/MAC 快照
        snapshots_before = capture_snapshots(topology)

        ticks.times do
          engine.step do |time, event|
            topology.devices.each_value { |d| d.tick(now: time) }
            event.call
          end
        end

        snapshots_after = capture_snapshots(topology)
        snapshots_before == snapshots_after
      end

      # 全局快照。
      def snapshot(topology)
        {
          devices: topology.devices.transform_values { |d| d.to_h },
          links: topology.links.map { |l| { a: l.endpoint_a.to_s, b: l.endpoint_b.to_s, status: l.status } },
          timestamp: engine_now
        }
      end

      # 导出为 JSON。
      def to_json(topology)
        JSON.pretty_generate(snapshot(topology))
      end

      # RIB 快照格式化输出。
      def format_rib(device)
        rib_data = device.rib_dump
        lines = ["=== RIB: #{device.name} ==="]

        rib_data.each do |prefix, routes|
          routes.each do |r|
            lines << "  #{prefix} via #{r[:next_hop]} (#{r[:protocol]} metric=#{r[:metric]})"
          end
        end

        lines.join("\n")
      end

      # MAC 表快照格式化输出。
      def format_mac(device)
        mac_data = device.mac_dump
        lines = ["=== MAC Table: #{device.name} ==="]

        mac_data.each do |mac, info|
          lines << "  #{mac} -> #{info[:port]}" + (info[:static] ? ' (static)' : '')
        end

        lines.join("\n")
      end

      # 路径追踪格式化输出。
      def format_trace(trace_result)
        lines = ["=== Trace ==="]
        trace_result.each do |hop|
          lines << "  #{hop[:device]} (#{hop[:type]}) -> port #{hop[:port]}" +
            (hop[:next_hop] ? " next_hop=#{hop[:next_hop]} proto=#{hop[:protocol]}" : '') +
            (hop[:decision] ? " decision=#{hop[:decision]}" : '')
        end
        lines << "  (reached destination)" if trace_result.any?
        lines.join("\n")
      end

      private

      def capture_snapshots(topology)
        topology.devices.transform_values do |d|
          d.is_a?(Device::Router) ? d.rib_dump : d.mac_dump
        end
      end

      def parse_ip(ip_str)
        ip_str.include?(':') ? IPv6.new(ip_str) : IPv4.new(ip_str)
      end

      def engine_now
        Time.now.to_i  # 简化
      end
    end
  end
end
