# frozen_string_literal: true

require "network"

# 场景3：保活机制测试
# 需要维持较长时间的连接，但经常和设备交互几条后就断开了
# 需要保活机制：在若干时间超过阈值之前一直维持连接并计时
# 一旦双端有交互，则更新这个计时
RSpec.describe NetworkInfraUtility::SSH, "场景3: 保活机制" do
  describe "Config::Settings — keepalive 默认配置" do
    it "default_keepalive_interval 默认为 30 秒" do
      expect(NetworkInfraUtility::SSH::Config::Settings::DEFAULT_SETTINGS[:default_keepalive_interval]).to eq(30)
    end

    it "可通过配置文件覆盖" do
      dir = Dir.mktmpdir("keepalive_settings_spec")
      path = File.join(dir, "settings.yml")
      File.write(path, { "default_keepalive_interval" => 10 }.to_yaml)
      settings = NetworkInfraUtility::SSH::Config::Settings.new(dir)
      expect(settings.default_keepalive_interval).to eq(10)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  describe "Config::Schema — keepalive 字段" do
    it "keepalive 为 Hash 类型时校验通过" do
      doc = {
        version: 1,
        sessions: [
          { host: "10.0.0.1", user: "admin", keepalive: { interval: 30, max_fail: 3 } }
        ],
        groups: []
      }
      expect { NetworkInfraUtility::SSH::Config::Schema.validate(doc) }.not_to raise_error
    end
  end

  describe "Client — keepalive RPC 暴露" do
    # 验证 Client 可以通过 IPC 调用 keepalive 相关 RPC
    # 这些 RPC 由新添加的 Erlang 代码提供
    let(:transport) { FakeTransportForKeepalive.new }
    let(:ipc) { NetworkInfraUtility::SSH::IPC::Router.new(transport) }

    it "keepalive.set_interval 请求格式正确" do
      t = Thread.new { ipc.call("keepalive.set_interval", { interval_ms: 15_000 }, timeout_ms: 5_000) }
      sleep 0.05
      msg = transport.sent.last
      expect(msg[:method]).to eq("keepalive.set_interval")
      expect(msg[:params][:interval_ms]).to eq(15_000)
    ensure
      t&.kill
    end

    it "keepalive.get_interval 请求格式正确" do
      t = Thread.new { ipc.call("keepalive.get_interval", {}, timeout_ms: 5_000) }
      sleep 0.05
      msg = transport.sent.last
      expect(msg[:method]).to eq("keepalive.get_interval")
    ensure
      t&.kill
    end

    it "keepalive.get_status 请求格式正确" do
      t = Thread.new { ipc.call("keepalive.get_status", {}, timeout_ms: 5_000) }
      sleep 0.05
      msg = transport.sent.last
      expect(msg[:method]).to eq("keepalive.get_status")
    ensure
      t&.kill
    end
  end

  describe "IPC::Router — conn.closed 事件订阅（保活失败通知）" do
    let(:transport) { FakeTransportForKeepalive.new }
    let(:router) { NetworkInfraUtility::SSH::IPC::Router.new(transport) }

    it "可以订阅 conn.closed 推送事件" do
      received = []
      sid = router.subscribe("conn.closed") do |params|
        received << params
      end

      # 模拟 Erlang 推送 conn.closed 事件
      router.send(:dispatch_push, "conn.closed", {
        conn_id: "conn_001",
        reason: "keepalive_failed"
      })

      expect(received.size).to eq(1)
      expect(received.first[:conn_id]).to eq("conn_001")
      expect(received.first[:reason]).to eq("keepalive_failed")

      router.unsubscribe("conn.closed", sid)
    end
  end

  describe "CLI — keepalive 命令行选项" do
    let(:cli) { NetworkInfraUtility::SSH::CLI.new }

    it "connect 命令支持 --keepalive-interval 选项" do
      options = NetworkInfraUtility::SSH::CLI.all_commands["connect"].options
      expect(options).to have_key(:keepalive_interval)
      expect(options[:keepalive_interval].type).to eq(:numeric)
    end

    it "connect 命令支持 --connect-timeout 选项" do
      options = NetworkInfraUtility::SSH::CLI.all_commands["connect"].options
      expect(options).to have_key(:connect_timeout)
      expect(options[:connect_timeout].type).to eq(:numeric)
    end

    it "connect 命令支持 --algorithms 选项" do
      options = NetworkInfraUtility::SSH::CLI.all_commands["connect"].options
      expect(options).to have_key(:algorithms)
      expect(options[:algorithms].type).to eq(:string)
    end
  end

  describe "Session — 活动通知间接验证" do
    # Erlang 端在 channel.send 和 channel.data 时会通知 keepalive_mgr
    # Ruby 端通过正常的 terminal.puts / terminal.send 触发
    # 这里验证 Terminal::Emulator 的 send/puts 方法正常工作
    let(:client) { double("Client") }
    let(:ipc) { double("IPC::Router") }
    let(:emulator) do
      NetworkInfraUtility::SSH::Terminal::Emulator.new(client, "conn_1", "ch_1", 80, 24, theme: "default")
    end

    before do
      allow(client).to receive(:ipc).and_return(ipc)
    end

    it "terminal.puts 发送命令时触发 channel.send RPC" do
      expect(ipc).to receive(:call).with("channel.send", hash_including(
        id: "ch_1",
        data: kind_of(String)
      ))
      emulator.puts("show version")
    end

    it "terminal.send 直接发送数据时触发 channel.send RPC" do
      allow(ipc).to receive(:call)
      emulator.send("ping")

      # 验证发送的数据是 Base64 编码的
      expect(ipc).to have_received(:call).with("channel.send", hash_including(
        id: "ch_1",
        data: Base64.strict_encode64("ping")
      ))
    end
  end
end

# FakeTransport for keepalive tests
class FakeTransportForKeepalive
  attr_reader :sent, :connected

  def initialize
    @sent = []
    @connected = true
  end

  def connect(_endpoint)
    @connected = true
  end

  def send(hash)
    @sent << hash
  end

  def close
    @connected = false
  end

  def each_frame
    # 由测试手动驱动
  end
end
