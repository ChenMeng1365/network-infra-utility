# coding: utf-8
# frozen_string_literal: true

# SimLab 统一入口模块。
#
# 负责加载仿真服务的所有子模块，提供统一接口。
#
# 用法：
#   require_relative "lib/simlab"
#   simlab = NetworkInfraUtility::SimLab::Simulation.new
#   simlab.load("scenario.yml")
#   simlab.run(final_time: 100)
#   simlab.dump_rib("R1")

require_relative "simlab_topology"
require_relative "simlab_engine"
require_relative "simlab_router"
require_relative "simlab_switch"
require_relative "simlab_traffic"
require_relative "simlab_observer"
require_relative "simlab_scenario"

module NetworkInfraUtility
  module SimLab
    class Error < StandardError; end

    class Simulation
      attr_reader :topology, :engine, :observer, :time

      def initialize
        @topology = Topology.new
        @engine   = Engine.new
        @observer = Observer.new
        @traffic  = Traffic.new
        @time     = 0
      end

      # 加载场景文件（YAML 或 Ruby DSL）。
      def load(file_path)
        scenario = Scenario.load(file_path)
        scenario.apply_to(self)
        self
      end

      # 从拓扑构建仿真环境。
      def build
        @topology.devices.each_value(&:build)
        @topology.links.each { |link| link.activate }
        self
      end

      # 运行仿真直到指定时间。
      def run(final_time: nil, steps: nil)
        if final_time
          @engine.run_until(final_time) do |time, event|
            @time = time
            tick_devices(time)
            event.call
          end
        elsif steps
          @engine.run_steps(steps) do |time, event|
            @time = time
            tick_devices(time)
            event.call
          end
        end
        self
      end

      # 单步执行。
      def step
        @engine.step do |time, event|
          @time = time
          tick_devices(time)
          event.call
        end
        self
      end

      # 注入流量/事件。
      def inject(event)
        @traffic.inject(@engine, event)
      end

      # 导出 RIB 快照。
      def dump_rib(device_name)
        device = @topology.devices[device_name]
        raise Error, "Device #{device_name} not found" unless device

        @observer.rib_dump(device)
      end

      # 导出 MAC 表快照。
      def dump_mac(device_name)
        device = @topology.devices[device_name]
        raise Error, "Device #{device_name} not found" unless device

        @observer.mac_dump(device)
      end

      # 转发路径追踪。
      def trace(from:, to:)
        @observer.trace(topology: @topology, from: from, to: to)
      end

      # 收敛检测。
      def converged?(ticks: 5)
        @observer.converged?(topology: @topology, ticks: ticks, engine: @engine)
      end

      # 快照导出。
      def snapshot
        @observer.snapshot(@topology)
      end

      private

      # 全局时钟推进时，所有设备同步 tick。
      def tick_devices(now)
        @topology.devices.each_value { |device| device.tick(now: now) }
      end
    end
  end
end
