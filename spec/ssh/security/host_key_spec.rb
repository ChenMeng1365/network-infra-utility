# frozen_string_literal: true

require "network"
require "tmpdir"

RSpec.describe NetworkInfraUtility::SSH::Security::HostKey do
  let(:tmp_dir) { Dir.mktmpdir("hostkey_spec") }
  let(:store_path) { File.join(tmp_dir, "known_hosts.yml") }
  let(:host_key) { described_class.new(store_path) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#resolve — 未知主机" do
    it "prompt 返回 :accept 时存盘并返回 accept" do
      host_key.on_prompt { |_h, _p, _f| :accept }
      result = host_key.resolve("10.0.0.1", 22, "SHA256:abc123")
      expect(result[:action]).to eq("accept")
      # 验证已存盘
      entry = host_key.get("10.0.0.1", 22)
      expect(entry[:fingerprint]).to eq("SHA256:abc123")
    end

    it "prompt 返回 :reject 时不存盘并返回 reject" do
      host_key.on_prompt { |_h, _p, _f| :reject }
      result = host_key.resolve("10.0.0.2", 22, "SHA256:def456")
      expect(result[:action]).to eq("reject")
      expect(host_key.get("10.0.0.2", 22)).to be nil
    end

    it "prompt 返回 :once 时存盘并返回 once" do
      host_key.on_prompt { |_h, _p, _f| :once }
      result = host_key.resolve("10.0.0.3", 2222, "SHA256:once1")
      expect(result[:action]).to eq("once")
    end
  end

  describe "#resolve — 已知主机指纹匹配" do
    it "直接返回 accept 不调 prompt" do
      host_key.add("10.0.0.1", 22, "SHA256:abc123")
      prompt_called = false
      host_key.on_prompt { prompt_called = true; :reject }
      result = host_key.resolve("10.0.0.1", 22, "SHA256:abc123")
      expect(result[:action]).to eq("accept")
      expect(prompt_called).to be false
    end
  end

  describe "#resolve — 指纹变更" do
    it "返回 reject 不调 prompt" do
      host_key.add("10.0.0.1", 22, "SHA256:abc123")
      prompt_called = false
      host_key.on_prompt { prompt_called = true }
      result = host_key.resolve("10.0.0.1", 22, "SHA256:changed")
      expect(result[:action]).to eq("reject")
      expect(prompt_called).to be false
    end

    it "触发 on_key_changed 回调" do
      host_key.add("10.0.0.1", 22, "SHA256:old")
      changed_info = nil
      host_key.on_key_changed { |h, p, old, new| changed_info = { host: h, port: p, old: old, new: new } }
      host_key.resolve("10.0.0.1", 22, "SHA256:new")
      expect(changed_info[:old]).to eq("SHA256:old")
      expect(changed_info[:new]).to eq("SHA256:new")
    end
  end

  describe "#add / #remove / #get" do
    it "手动添加条目后可查询" do
      host_key.add("10.0.0.5", 22, "SHA256:manual")
      entry = host_key.get("10.0.0.5", 22)
      expect(entry[:fingerprint]).to eq("SHA256:manual")
    end

    it "删除条目后查询返回 nil" do
      host_key.add("10.0.0.6", 22, "SHA256:del")
      host_key.remove("10.0.0.6", 22)
      expect(host_key.get("10.0.0.6", 22)).to be nil
    end
  end

  describe "#list" do
    it "列出全部条目" do
      host_key.add("10.0.0.1", 22, "SHA256:one")
      host_key.add("10.0.0.2", 22, "SHA256:two")
      list = host_key.list
      expect(list.size).to eq(2)
      hosts = list.map { |e| e[:host] }
      expect(hosts).to include("10.0.0.1", "10.0.0.2")
    end
  end

  describe "持久化" do
    it "重启后读取已存条目" do
      host_key.add("10.0.0.1", 22, "SHA256:persist")
      # 新建实例（模拟重启）
      hk2 = described_class.new(store_path)
      entry = hk2.get("10.0.0.1", 22)
      expect(entry[:fingerprint]).to eq("SHA256:persist")
    end
  end
end
