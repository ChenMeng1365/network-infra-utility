# frozen_string_literal: true

# example/ssh/macro_execution_example.rb
#
# 功能场景：登录宏引擎执行
# 覆盖需求：FR-AUTO-001
#
# 验证：
#   1. 多步骤宏执行
#   2. wait_for 模式匹配成功
#   3. on_fail 三分支（:continue / :abort / :ask）
#   4. 超过 50 步限制拒绝

require "network"

RSpec.describe "登录宏引擎执行" do
  let(:client_ipc) { double("IPC", subscribe: nil, unsubscribe: nil) }
  let(:client) { double("Client", ipc: client_ipc) }
  let(:terminal) { double("Terminal", channel_id: "ch_001", send: nil) }
  let(:session) { double("Session", client: client, conn_id: "conn_001", terminal: terminal) }
  let(:engine) { NetworkInfraUtility::SSH::Automation::MacroEngine.new(session) }

  it "多步骤宏完整执行" do
    commands_sent = []
    allow(terminal).to receive(:send) { |cmd| commands_sent << cmd }

    engine.add_step(action: "enable", delay: 0)
    engine.add_step(action: "configure terminal", delay: 0)
    engine.add_step(action: "interface GigabitEthernet0/0", delay: 0)
    engine.add_step(action: "end", delay: 0)

    result = engine.run
    expect(result).to eq(:completed)
    expect(commands_sent).to eq([
      "enable", "configure terminal",
      "interface GigabitEthernet0/0", "end"
    ])
  end

  it "从 YAML 配置加载宏步骤" do
    config = {
      enabled: true,
      steps: [
        { action: "show version", wait_pattern: "#", delay: 0.5, on_fail: "continue" },
        { action: "show ip interface brief", wait_pattern: "#", delay: 0.5 }
      ]
    }
    engine.load_from_config(config)
    expect(engine.step_count).to eq(2)
  end

  it "on_fail=:abort 超时后中止" do
    engine.add_step(action: "show version", wait_pattern: "PATTERN_NEVER_MATCH", on_fail: :abort, delay: 0)
    engine.add_step(action: "show ip route", delay: 0)

    allow_any_instance_of(NetworkInfraUtility::SSH::Automation::MacroEngine)
      .to receive(:wait_for).and_return(:timeout)

    commands_sent = []
    allow(terminal).to receive(:send) { |cmd| commands_sent << cmd }

    result = engine.run
    expect(result).to eq(:aborted)
    # 第二步不应执行
    expect(commands_sent).to eq(["show version"])
  end

  it "on_fail=:continue 超时后继续执行" do
    engine.add_step(action: "cmd1", wait_pattern: "X", on_fail: :continue, delay: 0)
    engine.add_step(action: "cmd2", delay: 0)

    allow_any_instance_of(NetworkInfraUtility::SSH::Automation::MacroEngine)
      .to receive(:wait_for).and_return(:timeout)

    commands_sent = []
    allow(terminal).to receive(:send) { |cmd| commands_sent << cmd }

    result = engine.run
    expect(result).to eq(:completed)
    expect(commands_sent).to eq(["cmd1", "cmd2"])
  end

  it "on_fail=:ask 回调返回 :continue 时继续" do
    engine.on_ask { |_step, _idx| :continue }
    engine.add_step(action: "cmd1", wait_pattern: "X", on_fail: :ask, delay: 0)
    engine.add_step(action: "cmd2", delay: 0)

    allow_any_instance_of(NetworkInfraUtility::SSH::Automation::MacroEngine)
      .to receive(:wait_for).and_return(:timeout)

    commands_sent = []
    allow(terminal).to receive(:send) { |cmd| commands_sent << cmd }

    result = engine.run
    expect(result).to eq(:completed)
  end

  it "on_fail=:ask 回调返回 :abort 时中止" do
    engine.on_ask { |_step, _idx| :abort }
    engine.add_step(action: "cmd1", wait_pattern: "X", on_fail: :ask, delay: 0)
    engine.add_step(action: "cmd2", delay: 0)

    allow_any_instance_of(NetworkInfraUtility::SSH::Automation::MacroEngine)
      .to receive(:wait_for).and_return(:timeout)

    result = engine.run
    expect(result).to eq(:aborted)
  end

  it "超过 50 步限制拒绝添加" do
    50.times { |i| engine.add_step(action: "step#{i}", delay: 0) }
    expect { engine.add_step(action: "overflow") }.to raise_error(/Too many steps/)
  end

  it "abort! 中止执行中的宏" do
    engine.add_step(action: "cmd1", delay: 0)
    engine.add_step(action: "cmd2", delay: 0)

    allow(terminal).to receive(:send) do |_cmd|
      engine.abort!
    end

    result = engine.run
    expect(result).to eq(:aborted)
  end
end
