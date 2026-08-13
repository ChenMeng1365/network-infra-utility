# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH do
  it "有版本号" do
    expect(described_class::VERSION).to eq("1.0.0")
  end

  it "协议版本与 PROTOCOL_VER 一致" do
    expect(described_class::Client::PROTOCOL_VER).to eq("1.0")
  end

  it "引擎启动超时为 10 秒" do
    expect(described_class::Client::ENGINE_STARTUP_TIMEOUT).to eq(10)
  end
end
