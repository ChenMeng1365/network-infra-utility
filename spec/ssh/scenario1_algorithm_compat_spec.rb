# frozen_string_literal: true

require "network"
require "thor"
require_relative "../../service/ssh/bin/ssh-client" if File.exist?("#{__dir__}/../../service/ssh/bin/ssh-client.rb")
# ssh-client 文件无 .rb 扩展名，用 load 加载
load File.expand_path("../../service/ssh/bin/ssh-client", __dir__) unless defined?(NetworkInfraUtility::SSH::CLI)

# 场景1：算法兼容测试
# 服务端支持的算法有限时，客户端需要能自定义算法列表来适配
RSpec.describe NetworkInfraUtility::SSH::Config::Schema, "场景1: 算法兼容" do
  describe ".validate — algorithms 字段" do
    it "algorithms 为 Hash 类型时校验通过" do
      doc = {
        version: 1,
        sessions: [
          { host: "10.0.0.1", user: "admin", algorithms: { kex: ["diffie-hellman-group14-sha256"] } }
        ],
        groups: []
      }
      expect { described_class.validate(doc) }.not_to raise_error
    end

    it "algorithms 为非 Hash 类型时抛 SchemaError" do
      doc = {
        version: 1,
        sessions: [
          { host: "10.0.0.1", user: "admin", algorithms: "aes256-ctr" }
        ],
        groups: []
      }
      expect { described_class.validate(doc) }.to raise_error(NetworkInfraUtility::SSH::Config::SchemaError)
    end
  end
end

# CLI 算法参数解析测试
RSpec.describe NetworkInfraUtility::SSH::CLI, "场景1: 算法兼容 - CLI 参数解析", :cli do
  # CLI 是 Thor 类，parse_algorithms 是 private 方法
  # 通过 send 触发私有方法测试
  describe "#parse_algorithms" do
    let(:cli) { described_class.new }

    it "解析单个算法类别" do
      result = cli.send(:parse_algorithms, "kex=curve25519-sha256,diffie-hellman-group14-sha256")
      expect(result[:kex]).to eq(["curve25519-sha256", "diffie-hellman-group14-sha256"])
    end

    it "解析多个算法类别（分号分隔）" do
      result = cli.send(:parse_algorithms, "kex=curve25519-sha256;cipher=aes256-ctr,aes128-ctr;mac=hmac-sha2-256")
      expect(result[:kex]).to eq(["curve25519-sha256"])
      expect(result[:cipher]).to eq(["aes256-ctr", "aes128-ctr"])
      expect(result[:mac]).to eq(["hmac-sha2-256"])
    end

    it "处理空格" do
      result = cli.send(:parse_algorithms, "kex = curve25519-sha256 , diffie-hellman-group14-sha256")
      expect(result[:kex]).to eq(["curve25519-sha256", "diffie-hellman-group14-sha256"])
    end

    it "缺少等号时抛异常" do
      expect { cli.send(:parse_algorithms, "kex") }.to raise_error(RuntimeError)
    end
  end
end
