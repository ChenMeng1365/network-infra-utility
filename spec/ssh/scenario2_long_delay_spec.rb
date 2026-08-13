# frozen_string_literal: true

require "network"

# 场景2：长延迟响应测试
# 一些设备连接发起或发送命令后很长时间才有反馈，在收到反馈前连接就断了
# 需要支持可配置的连接超时
RSpec.describe NetworkInfraUtility::SSH, "场景2: 长延迟响应" do
  describe "Config::Schema — connect_timeout_ms 字段" do
    it "connect_timeout_ms 为 Integer 类型时校验通过" do
      doc = {
        version: 1,
        sessions: [
          { host: "10.0.0.1", user: "admin", connect_timeout_ms: 180_000 }
        ],
        groups: []
      }
      expect { NetworkInfraUtility::SSH::Config::Schema.validate(doc) }.not_to raise_error
    end

    it "connect_timeout_ms 为非 Integer 类型时抛 SchemaError" do
      doc = {
        version: 1,
        sessions: [
          { host: "10.0.0.1", user: "admin", connect_timeout_ms: "180" }
        ],
        groups: []
      }
      expect { NetworkInfraUtility::SSH::Config::Schema.validate(doc) }.to raise_error(NetworkInfraUtility::SSH::Config::SchemaError)
    end
  end

  describe "Config::Store — 持久化 connect_timeout_ms" do
    let(:dir) { Dir.mktmpdir("timeout_store_spec") }
    let(:path) { File.join(dir, "sessions.yml") }
    let(:store) { NetworkInfraUtility::SSH::Config::Store.new(path) }

    after { FileUtils.rm_rf(dir) }

    it "添加含 connect_timeout_ms 的会话并通过 reload 验证持久化" do
      store.add_session(
        id: "sess_001", host: "10.0.0.1", user: "admin",
        connect_timeout_ms: 300_000
      )
      store.reload
      session = store.find_session("sess_001")
      expect(session[:connect_timeout_ms]).to eq(300_000)
    end
  end

  describe "IPC::Router — RPC 超时配置" do
    let(:transport) { FakeTransportForTimeout.new }
    let(:router) { NetworkInfraUtility::SSH::IPC::Router.new(transport) }

    it "call 方法接受自定义 timeout_ms 参数" do
      # 验证 timeout_ms 可以被设置为大于默认值 30s 的值
      t = Thread.new { router.call("conn.connect", {}, timeout_ms: 180_000) }
      sleep 0.05
      msg = transport.sent.last
      expect(msg[:method]).to eq("conn.connect")
      # 验证没有立即抛出超时异常（180s 足够长）
      expect(t).to be_alive
    ensure
      t&.kill
    end
  end

  describe "Automation::MacroEngine — wait_for 超时" do
    # MacroEngine 的 wait_for 默认 30s 超时
    # 这是已有测试的补充：验证长延迟场景下 wait_for 的行为
    let(:client) { double("Client") }
    let(:ipc) { double("IPC::Router") }
    let(:session) { double("Session", client: client, conn_id: "conn_1") }
    let(:terminal) { double("Terminal", channel_id: "ch_1") }
    let(:macro_engine) { NetworkInfraUtility::SSH::Automation::MacroEngine.new(session) }

    before do
      allow(session).to receive(:terminal).and_return(terminal)
      allow(client).to receive(:ipc).and_return(ipc)
      allow(ipc).to receive(:subscribe).and_return("sub_1")
      allow(ipc).to receive(:unsubscribe)
    end

    it "wait_pattern 30 秒内无匹配数据时返回 :timeout" do
      macro_engine.add_step(action: "show version\n", wait_pattern: "#", on_fail: :continue)

      # 模拟 wait_for 始终超时
      expect(macro_engine).to receive(:wait_for).and_return(:timeout)
      expect(terminal).to receive(:send).with("show version\n")

      result = macro_engine.run
      expect(result).to eq(:completed) # on_fail: :continue 所以继续
    end

    it "on_fail: :abort 时超时中止整个宏" do
      macro_engine.add_step(action: "show version\n", wait_pattern: "#", on_fail: :abort)
      macro_engine.add_step(action: "show ip route\n", wait_pattern: "#")

      expect(macro_engine).to receive(:wait_for).and_return(:timeout)
      expect(terminal).to receive(:send).with("show version\n")

      result = macro_engine.run
      expect(result).to eq(:aborted)
    end
  end
end

# FakeTransport for timeout tests
class FakeTransportForTimeout
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
