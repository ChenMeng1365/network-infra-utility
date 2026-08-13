# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::IPC do
  it "定义了 IPC 层异常体系" do
    expect(described_class::Error).to be < StandardError
    expect(described_class::RPCTimeout).to be < described_class::Error
    expect(described_class::RPCError).to be < described_class::Error
    expect(described_class::NotReady).to be < described_class::Error
    expect(described_class::FlowPaused).to be < described_class::Error
    expect(described_class::ConnectionLost).to be < described_class::Error
    expect(described_class::SchemaMismatch).to be < described_class::Error
  end

  describe NetworkInfraUtility::SSH::IPC::RPCError do
    it "从 error 对象提取 code、message 和 data" do
      err = described_class.new({ code: -32_601, message: "Method not found", data: "foo" })
      expect(err.code).to eq(-32_601)
      expect(err.data).to eq("foo")
      expect(err.message).to eq("Method not found")
    end

    it "无 message 时回退到 code" do
      err = described_class.new({ code: -32_603 })
      expect(err.message).to eq("RPC error code=-32603")
    end
  end
end
