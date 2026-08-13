# frozen_string_literal: true

require "network"
require "tmpdir"

RSpec.describe NetworkInfraUtility::SSH::Config::Store do
  let(:tmp_dir) { Dir.mktmpdir("store_spec") }
  let(:store_path) { File.join(tmp_dir, "sessions.yml") }
  let(:store) { described_class.new(store_path) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe "初始化（无文件）" do
    it "空文档包含正确结构" do
      expect(store.doc[:version]).to eq(1)
      expect(store.sessions).to eq([])
      expect(store.groups).to eq([])
    end
  end

  describe "#add_session / #find_session" do
    it "添加会话后可按 id 查找" do
      store.add_session(id: "sess_001", host: "10.0.0.1", user: "admin")
      s = store.find_session("sess_001")
      expect(s[:host]).to eq("10.0.0.1")
    end
  end

  describe "#update_session" do
    it "更新会话字段" do
      store.add_session(id: "sess_001", host: "10.0.0.1", user: "admin")
      store.update_session("sess_001", user: "root")
      expect(store.find_session("sess_001")[:user]).to eq("root")
    end

    it "不存在的 id 不报错" do
      expect { store.update_session("nonexistent", user: "x") }.not_to raise_error
    end
  end

  describe "#remove_session" do
    it "删除后 find 返回 nil" do
      store.add_session(id: "sess_001", host: "10.0.0.1", user: "admin")
      store.remove_session("sess_001")
      expect(store.find_session("sess_001")).to be nil
    end
  end

  describe "#add_group / #remove_group / #find_group" do
    it "管理分组生命周期" do
      store.add_group(id: "grp_001", name: "Prod")
      expect(store.find_group("grp_001")[:name]).to eq("Prod")
      store.remove_group("grp_001")
      expect(store.find_group("grp_001")).to be nil
    end
  end

  describe "#reload" do
    it "从磁盘重新加载" do
      store.add_session(id: "sess_001", host: "10.0.0.1", user: "admin")
      # 直接修改文件
      doc = YAML.safe_load(File.read(store_path), symbolize_names: true, permitted_classes: [Symbol])
      doc[:sessions] << { id: "sess_002", host: "10.0.0.2", user: "root" }
      File.write(store_path, YAML.dump(doc))
      store.reload
      expect(store.sessions.size).to eq(2)
    end
  end
end
