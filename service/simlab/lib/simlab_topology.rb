# coding: utf-8
# frozen_string_literal: true

# 拓扑模型：定义 node（router/switch/host）、link（带宽/延迟/开销）、interface。
#
# 这是仿真的"图纸"，不跑协议。支持 YAML 场景文件加载与校验，生成邻接关系。
#
# 用法：
#   topo = Topology.new
#   topo.add_router("R1", interfaces: {"Gi0/0" => "10.0.0.1/24"})
#   topo.add_switch("S1", ports: ["Gi0/1", "Gi0/2"])
#   topo.add_link("R1:Gi0/0", "S1:Gi0/1", bandwidth: 100_000, delay: 10)
#   topo.devices    # => {"R1" => Router, "S1" => Switch}

require 'set'

module NetworkInfraUtility
  module SimLab
    # 链路：连接两个设备的接口。
    class Link
      attr_reader :endpoint_a, :endpoint_b, :bandwidth, :delay, :cost
      attr_accessor :status

      def initialize(endpoint_a:, endpoint_b:, bandwidth:, delay:, cost:, status:)
        @endpoint_a = endpoint_a
        @endpoint_b = endpoint_b
        @bandwidth  = bandwidth
        @delay      = delay
        @cost       = cost
        @status     = status
      end

      def up?
        status == :up
      end

      def down?
        status == :down
      end

      def activate
        self.status = :up
      end

      def deactivate
        self.status = :down
      end

      def other_end(endpoint)
        endpoint == endpoint_a ? endpoint_b : endpoint_a
      end
    end

    # 接口端点：设备名 + 端口名。
    Endpoint = Data.define(:device, :port) do
      def to_s
        "#{device}:#{port}"
      end
    end

    class Topology
      attr_reader :devices, :links, :hosts

      def initialize
        @devices = {}  # name => Router/Switch
        @links   = []  # Link 数组
        @hosts   = {}  # name => {ip:, gateway:}
        @adjacency = {}  # device_name => [{port:, peer_device:, peer_port:, link:}]
      end

      # 添加路由器。
      def add_router(name, interfaces: {}, **opts)
        require_relative "simlab_router"
        router = Device::Router.new(name: name, interfaces: interfaces, **opts)
        @devices[name] = router
      end

      # 添加交换机。
      def add_switch(name, ports: [], **opts)
        require_relative "simlab_switch"
        switch = Device::Switch.new(name: name, ports: ports, **opts)
        @devices[name] = switch
      end

      # 添加主机。
      def add_host(name, ip:, gateway:, mac: nil)
        @hosts[name] = { ip: ip, gateway: gateway, mac: mac }
      end

      # 添加链路。
      # endpoint 格式: "Device:Port" 或 Endpoint 对象
      def add_link(endpoint_a, endpoint_b, bandwidth: 1_000_000, delay: 0, cost: 10, status: :up)
        ep_a = parse_endpoint(endpoint_a)
        ep_b = parse_endpoint(endpoint_b)

        link = Link.new(
          endpoint_a: ep_a,
          endpoint_b: ep_b,
          bandwidth: bandwidth,
          delay: delay,
          cost: cost,
          status: status
        )

        @links << link
        update_adjacency(ep_a, ep_b, link)
        update_adjacency(ep_b, ep_a, link)

        link
      end

      # 获取设备的邻接关系。
      def neighbors_of(device_name)
        @adjacency[device_name] || []
      end

      # 获取设备上某端口连接的对端。
      def peer_of(device_name, port)
        (@adjacency[device_name] || []).find { |adj| adj[:port] == port }
      end

      # 查找两个设备之间的链路。
      def link_between(device_a, device_b)
        @links.find do |link|
          (link.endpoint_a.device == device_a && link.endpoint_b.device == device_b) ||
            (link.endpoint_a.device == device_b && link.endpoint_b.device == device_a)
        end
      end

      # 所有设备名。
      def device_names
        @devices.keys
      end

      # 路由器列表。
      def routers
        @devices.select { |_, d| d.is_a?(Device::Router) }
      end

      # 交换机列表。
      def switches
        @devices.select { |_, d| d.is_a?(Device::Switch) }
      end

      # 拓扑校验。
      def validate!
        errors = []

        @links.each do |link|
          ep_a = link.endpoint_a
          ep_b = link.endpoint_b

          errors << "Unknown device: #{ep_a.device}" unless @devices.key?(ep_a.device)
          errors << "Unknown device: #{ep_b.device}" unless @devices.key?(ep_b.device)
        end

        raise Error, "Topology validation failed: #{errors.join(', ')}" unless errors.empty?

        true
      end

      # 导出为 Hash（便于序列化）。
      def to_h
        {
          devices: @devices.transform_values { |d| d.to_h },
          links: @links.map { |l| { a: l.endpoint_a.to_s, b: l.endpoint_b.to_s, bandwidth: l.bandwidth, delay: l.delay, cost: l.cost, status: l.status } },
          hosts: @hosts
        }
      end

      private

      def parse_endpoint(arg)
        case arg
        when Endpoint
          arg
        when String
          device, port = arg.split(':', 2)
          Endpoint.new(device: device, port: port)
        else
          raise ArgumentError, "Invalid endpoint: #{arg}"
        end
      end

      def update_adjacency(from_ep, to_ep, link)
        @adjacency[from_ep.device] ||= []
        @adjacency[from_ep.device] << {
          port: from_ep.port,
          peer_device: to_ep.device,
          peer_port: to_ep.port,
          link: link
        }
      end
    end
  end
end
