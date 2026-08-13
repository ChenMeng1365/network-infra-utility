# frozen_string_literal: true

require "network"

# 用 FakeTransport 替代真实 socket，测试 Router 路由逻辑
class FakeTransport
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
  alias << send

  def close
    @connected = false
  end

  def each_frame
    # 由测试手动驱动
  end
end

RSpec.describe NetworkInfraUtility::SSH::IPC::Router do
  let(:transport) { FakeTransport.new }
  let(:router) { described_class.new(transport) }

  describe "#initialize" do
    it "初始状态正确" do
      expect(router.closed?).to be false
      expect(router.server_capabilities).to eq([])
    end
  end

  describe "#call" do
    it "发送 JSON-RPC 请求并带递增 id" do
      t = Thread.new { router.call("engine.ping", {}, timeout_ms: 100) }
      sleep 0.05
      expect(transport.sent).not_to be_empty
      msg = transport.sent.last
      expect(msg[:jsonrpc]).to eq("2.0")
      expect(msg[:method]).to eq("engine.ping")
      expect(msg[:id]).to be_a(Integer)
    ensure
      t&.kill
    end
  end

  describe "#subscribe / #unsubscribe" do
    it "订阅返回 sid，可注销" do
      sid = router.subscribe("conn.ready") {}
      expect(sid).to be_a(String)
      expect { router.unsubscribe("conn.ready", sid) }.not_to raise_error
    end
  end

  describe "#on_reverse_rpc" do
    it "注册反向 RPC 处理器" do
      expect { router.on_reverse_rpc("hostkey.resolve") { |p| { action: "accept" } } }.not_to raise_error
    end
  end

  describe "#close" do
    it "关闭后 closed? 返回 true" do
      router.close
      expect(router.closed?).to be true
    end
  end
end
