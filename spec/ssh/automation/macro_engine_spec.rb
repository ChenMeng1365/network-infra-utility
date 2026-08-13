# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Automation::MacroEngine do
  let(:client_ipc) { double("IPC", subscribe: "sid_001", unsubscribe: nil) }
  let(:client) { double("Client", ipc: client_ipc) }
  let(:terminal) { double("Terminal", channel_id: "ch_001", send: nil) }
  let(:session) { double("Session", client: client, conn_id: "conn_001", terminal: terminal) }
  let(:engine) { described_class.new(session) }

  describe "#add_step" do
    it "添加步骤" do
      engine.add_step(action: "show version", wait_pattern: "#", delay: 0.5)
      expect(engine.step_count).to eq(1)
    end

    it "超过 50 步抛异常" do
      50.times { |i| engine.add_step(action: "cmd#{i}") }
      expect { engine.add_step(action: "overflow") }.to raise_error(/Too many steps/)
    end
  end

  describe "#load_from_config" do
    it "从配置加载步骤" do
      config = {
        enabled: true,
        steps: [
          { action: "show version", wait_pattern: "#", delay: 0 },
          { action: "show ip route", wait_pattern: "#", delay: 0.5 }
        ]
      }
      engine.load_from_config(config)
      expect(engine.step_count).to eq(2)
    end

    it "disabled 时不加载" do
      engine.load_from_config(enabled: false, steps: [{ action: "test" }])
      expect(engine.step_count).to eq(0)
    end
  end

  describe "#run" do
    it "空步骤直接返回 :completed" do
      expect(engine.run).to eq(:completed)
    end

    it "执行步骤并发送命令" do
      engine.add_step(action: "show version")
      expect(terminal).to receive(:send).with("show version")
      result = engine.run
      expect(result).to eq(:completed)
    end

    it "有 wait_pattern 但无匹配时 :abort 中止" do
      engine.add_step(action: "show version", wait_pattern: "NONEXISTENT", on_fail: :abort, delay: 0)

      # subscribe 回调不触发匹配，wait_for 超时
      allow(client_ipc).to receive(:subscribe).and_return("sid")
      allow(client_ipc).to receive(:unsubscribe)

      # 用短超时，覆盖 30s 默认
      allow_any_instance_of(described_class).to receive(:wait_for).and_return(:timeout)

      result = engine.run
      expect(result).to eq(:aborted)
    end

    it ":continue 时超时后继续执行" do
      engine.add_step(action: "cmd1", wait_pattern: "X", on_fail: :continue, delay: 0)
      engine.add_step(action: "cmd2", delay: 0)

      allow_any_instance_of(described_class).to receive(:wait_for).and_return(:timeout)

      expect(terminal).to receive(:send).with("cmd1")
      expect(terminal).to receive(:send).with("cmd2")
      result = engine.run
      expect(result).to eq(:completed)
    end
  end

  describe "#abort!" do
    it "中止执行中的宏" do
      engine.add_step(action: "cmd1", delay: 0)
      engine.add_step(action: "cmd2", delay: 0)

      # 在第一步后中断
      allow(terminal).to receive(:send) do |_cmd|
        engine.abort!
      end

      result = engine.run
      expect(result).to eq(:aborted)
    end
  end

  describe "#clear" do
    it "清空步骤" do
      engine.add_step(action: "test")
      engine.clear
      expect(engine.step_count).to eq(0)
    end

    it "执行中不允许清空" do
      engine.add_step(action: "cmd", delay: 0)
      allow_any_instance_of(described_class).to receive(:wait_for).and_return(:matched)
      allow(terminal).to receive(:send)
      # 在 run 过程中尝试 clear
      allow(terminal).to receive(:send) do
        expect { engine.clear }.to raise_error(/Cannot clear while running/)
      end
      engine.run
    end
  end

  describe "#on_ask" do
    it "设置 :ask 回调" do
      engine.on_ask { |_step, _idx| :continue }
      expect { engine.on_ask { |_| :abort } }.not_to raise_error
    end
  end
end
