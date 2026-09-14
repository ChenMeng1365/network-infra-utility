# coding: utf-8
# frozen_string_literal: true

# 离散事件仿真核心：全局虚拟时钟 + 事件队列。
#
# 设计要点：
# - 全局虚拟时钟
# - 事件队列（按时间排序）
# - 支持延迟事件（链路延迟、计时器、老化）
# - 收敛检测辅助（统计 N 个 tick 内 RIB/MAC 无变化）
#
# support 组件通过 tick(now) 被动推进，不自己计时。
# device 之间不直接互调方法，由 engine 按链路投递帧/报文（可带延迟）。
#
# 用法：
#   engine = Engine.new
#   engine.schedule(at: 10) { puts "tick at 10" }
#   engine.schedule(at: 20, delay: 5) { puts "delayed event" }
#   engine.run_until(30) { |time, event| event.call }

module NetworkInfraUtility
  module SimLab
    # 仿真事件。
    Event = Data.define(:at, :priority, :id, :block) do
      include Comparable

      def <=>(other)
        [at, priority] <=> [other.at, other.priority]
      end
    end

    # 投递信封：封装设备间传递的报文。
    Envelope = Data.define(:at, :src_node, :src_if, :dst_node, :dst_if, :payload)

    class Engine
      attr_reader :clock, :event_count

      def initialize
        @clock       = 0     # 虚拟时钟（秒）
        @queue       = []    # 事件队列（最小堆模拟）
        @event_count = 0
        @seq         = 0    # 事件序号（用于稳定排序）
        @stopped     = false
      end

      # 调度一个事件在指定时间执行。
      # at: 执行时间
      # priority: 优先级（数字小的先执行，默认 0）
      # 返回事件 ID（可用于取消）。
      def schedule(at:, priority: 0, &block)
        @seq += 1
        event = Event.new(at: at, priority: priority, id: @seq, block: block)
        @queue << event
        @queue.sort_by! { |e| [e.at, e.priority, e.id] }
        @event_count += 1
        @seq
      end

      # 调度一个延迟事件。
      # delay: 从当前时钟起的延迟
      def schedule_delayed(delay:, priority: 0, &block)
        schedule(at: @clock + delay, priority: priority, &block)
      end

      # 投递信封（带链路延迟）。
      def deliver(envelope, delay: 0)
        schedule(at: envelope.at + delay) do
          yield envelope if block_given?
        end
      end

      # 取消指定 ID 的事件。
      def cancel(event_id)
        @queue.reject! { |e| e.id == event_id }
      end

      # 运行到指定时间。
      def run_until(final_time)
        while !@queue.empty? && !@stopped
          event = @queue.first
          break if event.at > final_time

          @queue.shift
          @clock = event.at
          yield event.at, event.block if block_given?
        end
        @clock = final_time if @clock < final_time
      end

      # 执行指定步数的事件。
      def run_steps(steps)
        steps.times do
          break if @queue.empty? || @stopped

          event = @queue.shift
          @clock = event.at
          yield event.at, event.block if block_given?
        end
      end

      # 执行单步。
      def step
        return nil if @queue.empty? || @stopped

        event = @queue.shift
        @clock = event.at
        yield event.at, event.block if block_given?
        event
      end

      # 停止仿真。
      def stop
        @stopped = true
      end

      # 重置。
      def reset
        @clock = 0
        @queue.clear
        @event_count = 0
        @seq = 0
        @stopped = false
      end

      # 队列中剩余事件数。
      def pending
        @queue.size
      end

      # 是否有空闲（队列空）。
      def idle?
        @queue.empty?
      end

      # 当前时钟。
      def now
        @clock
      end

      # 查看下一个事件时间。
      def next_event_time
        @queue.first&.at
      end
    end
  end
end
