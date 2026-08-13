# frozen_string_literal: true

require "timeout"

module NetworkInfraUtility
  module SSH
    module Automation
      # 登录宏引擎，连接后自动执行预设命令序列。
      # 对应需求 FR-AUTO-001。
      #
      # LLD §7.9 修正：
      #   1. wait_for 不轮询 buffer.last_line，改为订阅 channel.data 事件，在事件到达时进行匹配
      #   2. on_fail: :ask 通过外部传入的 on_ask 回调处理，不依赖 block_given
      #
      # DoD（LLD §11.2）：50 步宏执行；wait_pattern 匹配；on_fail 三分支
      #
      # on_fail 三分支：
      #   :continue — 超时后继续执行下一步
      #   :abort    — 超时后中止整个宏
      #   :ask      — 超时后调用 on_ask 回调询问用户
      class MacroEngine
        MAX_STEPS = 50

        # 单步定义
        # @!attribute action
        #   @return [String] 要发送的命令
        # @!attribute wait_pattern
        #   @return [String, Regexp, nil] 等待匹配的文本/正则，nil 不等待
        # @!attribute delay
        #   @return [Float] 发送前延迟（秒）
        # @!attribute on_fail
        #   @return [Symbol] :continue / :abort / :ask
        Step = Struct.new(:action, :wait_pattern, :delay, :on_fail, keyword_init: true)

        attr_reader :steps, :running, :current_step_index

        # @param session [Session::Session] 关联的会话
        def initialize(session)
          @session = session
          @steps = []
          @running = false
          @abort = false
          @current_step_index = nil
          @data_subscription_sid = nil
          @on_ask_callback = nil
        end

        # 设置 on_fail=:ask 时的回调
        # 回调签名: ->(step, step_index) { :continue | :abort }
        def on_ask(&block)
          @on_ask_callback = block
        end

        # 添加一步。
        # @param action [String] 要发送的命令
        # @param wait_pattern [String, Regexp, nil] 等待匹配的文本/正则
        # @param delay [Float] 发送前延迟（秒），默认 0
        # @param on_fail [Symbol] 失败时行为：:continue / :abort / :ask
        def add_step(action:, wait_pattern: nil, delay: 0, on_fail: :continue)
          raise "Too many steps (max #{MAX_STEPS})" if @steps.size >= MAX_STEPS

          @steps << Step.new(action: action, wait_pattern: wait_pattern,
                             delay: delay, on_fail: on_fail)
        end

        # 从 YAML 配置加载步骤（sessions.yml macro.steps）
        # @param config [Hash] { enabled: bool, steps: [{action, wait_pattern, delay, on_fail}] }
        def load_from_config(config)
          return unless config && config[:enabled]

          Array(config[:steps]).each do |step_cfg|
            add_step(
              action: step_cfg[:action],
              wait_pattern: step_cfg[:wait_pattern],
              delay: step_cfg[:delay] || 0,
              on_fail: (step_cfg[:on_fail] || :continue).to_sym
            )
          end
        end

        # 执行宏。
        # @param on_progress [Proc, nil] 进度回调 ->(step, index, total) {}
        # @return [Symbol] :completed | :aborted
        def run(on_progress: nil)
          raise "Macro already running" if @running
          return :completed if @steps.empty?

          @running = true
          @abort = false

          @steps.each_with_index do |step, i|
            break if @abort
            @current_step_index = i
            on_progress&.call(step, i + 1, @steps.size)

            sleep step.delay if step.delay > 0

            @session.terminal.send(step.action)

            if step.wait_pattern
              result = wait_for(step.wait_pattern, timeout: 30)
              handle_step_result(step, i, result)
            end
          end

          @abort ? :aborted : :completed
        ensure
          @running = false
          @current_step_index = nil
          cleanup_subscription
        end

        # 中止执行中的宏
        def abort!
          @abort = true
        end

        # 清空步骤
        def clear
          raise "Cannot clear while running" if @running
          @steps.clear
        end

        # 步骤数
        def step_count
          @steps.size
        end

        private

        # LLD §7.9 修正1：wait_for 不轮询 buffer.last_line，
        # 改为订阅 channel.data 事件，在事件到达时匹配。
        # @param pattern [String, Regexp] 等待匹配的文本/正则
        # @param timeout [Integer] 超时秒数
        # @return [Symbol] :matched | :timeout
        def wait_for(pattern, timeout:)
          regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern.to_s))
          deadline = Time.now + timeout
          accumulated = +""
          matched = false
          queue = Queue.new

          # 订阅 channel.data 推送
          @data_subscription_sid = @session.client.ipc.subscribe("channel.data") do |params|
            next unless params[:conn_id] == @session.conn_id &&
                        params[:channel_id] == @session.terminal.channel_id

            data = decode_data(params[:data])
            accumulated << data
            queue << :data if accumulated.match?(regex)
          end

          deadline
          loop do
            remaining = deadline - Time.now
            return :timeout if remaining <= 0
            return :matched if accumulated.match?(regex)

            # 等待新数据到达或超时
            begin
              Timeout.timeout(remaining) { queue.pop }
              return :matched if accumulated.match?(regex)
            rescue Timeout::Error
              return :timeout
            end
          end
        ensure
          cleanup_subscription
        end

        # LLD §7.9 修正2：on_fail=:ask 通过外部回调处理
        # @param step [Step] 当前步骤
        # @param index [Integer] 步骤索引
        # @param result [Symbol] :matched | :timeout
        def handle_step_result(step, index, result)
          return if result == :matched

          case step.on_fail
          when :continue
            # 超时后继续
          when :abort
            @abort = true
          when :ask
            if @on_ask_callback
              user_decision = @on_ask_callback.call(step, index)
              @abort = true if user_decision == :abort
            else
              # 无回调时默认 abort
              @abort = true
            end
          end
        end

        def cleanup_subscription
          return unless @data_subscription_sid

          @session.client.ipc.unsubscribe("channel.data", @data_subscription_sid)
          @data_subscription_sid = nil
        end

        # 解码 Base64 通道数据
        def decode_data(encoded)
          return "" unless encoded

          require "base64"
          Base64.strict_decode64(encoded)
        rescue StandardError
          ""
        end
      end
    end
  end
end
