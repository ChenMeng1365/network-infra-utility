# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::IPC::Transport do
  let(:transport) { described_class.new }

  describe "#initialize" do
    it "初始状态为未连接" do
      expect(transport.connected).to be false
      expect(transport.endpoint).to be nil
    end
  end

  describe "#connect" do
    it "无端点时抛 ArgumentError" do
      expect { transport.connect }.to raise_error(ArgumentError, /No endpoint/)
    end

    it "未知端点格式时抛 ArgumentError" do
      expect { transport.connect("foo://bar") }.to raise_error(ArgumentError, /Unknown endpoint format/)
    end
  end

  describe "#send (未连接)" do
    it "未连接时抛 ConnectionLost" do
      expect { transport.send(foo: 1) }.to raise_error(
        NetworkInfraUtility::SSH::IPC::ConnectionLost, /Not connected/
      )
    end
  end

  describe "#each_frame (未连接)" do
    it "未连接时抛 ConnectionLost" do
      expect { transport.each_frame { |f| } }.to raise_error(
        NetworkInfraUtility::SSH::IPC::ConnectionLost, /Not connected/
      )
    end
  end

  describe "#close" do
    it "可在未连接状态下安全调用" do
      expect { transport.close }.not_to raise_error
      expect(transport.connected).to be false
    end
  end
end
