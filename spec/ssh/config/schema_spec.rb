# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Config::Schema do
  let(:valid_session) do
    {
      id: "sess_001", name: "test", host: "10.0.0.1", port: 22, user: "admin",
      tags: [], auth: {}, terminal: {}, keepalive: {}, proxy: {}, jumps: [],
      port_forwards: [], macro: {}, log: {}, auto_reconnect: {}
    }
  end

  let(:valid_group) do
    { id: "grp_001", name: "Prod", parent: "root", collapsed: false }
  end

  describe ".validate" do
    it "合法文档返回 :ok" do
      doc = { version: 1, sessions: [valid_session], groups: [valid_group] }
      expect(described_class.validate(doc)).to eq(:ok)
    end

    it "版本不匹配抛 SchemaError" do
      doc = { version: 2, sessions: [], groups: [] }
      expect { described_class.validate(doc) }.to raise_error(
        NetworkInfraUtility::SSH::Config::SchemaError, /version mismatch/
      )
    end

    it "缺少必填 host 抛 SchemaError" do
      session = valid_session.dup
      session.delete(:host)
      expect { described_class.validate(version: 1, sessions: [session]) }.to raise_error(
        NetworkInfraUtility::SSH::Config::SchemaError, /missing required host/
      )
    end

    it "缺少必填 user 抛 SchemaError" do
      session = valid_session.dup
      session.delete(:user)
      expect { described_class.validate(version: 1, sessions: [session]) }.to raise_error(
        NetworkInfraUtility::SSH::Config::SchemaError, /missing required user/
      )
    end

    it "字段类型不匹配抛 SchemaError" do
      session = valid_session.merge(port: "not_a_number")
      expect { described_class.validate(version: 1, sessions: [session]) }.to raise_error(
        NetworkInfraUtility::SSH::Config::SchemaError, /type mismatch/
      )
    end

    it "空 sessions 和 groups 合法" do
      expect(described_class.validate(version: 1)).to eq(:ok)
    end
  end

  describe ".migrate" do
    it "V1.0 返回原文档" do
      doc = { version: 1, foo: "bar" }
      expect(described_class.migrate(doc)).to eq(doc)
    end
  end
end
