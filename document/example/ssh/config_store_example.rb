# frozen_string_literal: true

# example/ssh/config_store_example.rb
#
# 功能场景：会话配置持久化完整流程
# 覆盖需求：FR-SESS-001 ~ FR-SESS-004
#
# 验证：
#   1. 创建会话配置
#   2. 分组管理
#   3. 搜索会话
#   4. Schema 校验
#   5. 持久化与重载

require "network"
require "tmpdir"

RSpec.describe "会话配置持久化流程" do
  let(:tmp_dir) { Dir.mktmpdir("config_e2e") }
  let(:store_path) { File.join(tmp_dir, "sessions.yml") }
  let(:store) { NetworkInfraUtility::SSH::Config::Store.new(store_path) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  it "完整：创建会话 → 分组 → 搜索 → 更新 → 删除 → 重载" do
    # 1. 创建分组
    store.add_group(id: "grp_prod", name: "Production", parent: "root", collapsed: false)
    store.add_group(id: "grp_dev", name: "Development", parent: "root", collapsed: true)

    # 2. 创建会话并关联分组
    store.add_session(
      id: "sess_core_rt01", name: "Core-RT01", group: "grp_prod",
      host: "10.0.0.1", port: 22, user: "admin",
      auth: { type: "publickey", key_path: "~/.ssh/id_rsa" },
      tags: %w[core bgp], keepalive: { interval: 30 }
    )
    store.add_session(
      id: "sess_dev_srv01", name: "Dev-SRV01", group: "grp_dev",
      host: "192.168.1.100", port: 22, user: "developer",
      auth: { type: "password" },
      tags: %w[dev web]
    )

    # 3. Schema 校验
    expect { NetworkInfraUtility::SSH::Config::Schema.validate(store.doc) }.not_to raise_error

    # 4. 查找会话
    s = store.find_session("sess_core_rt01")
    expect(s[:host]).to eq("10.0.0.1")
    expect(s[:tags]).to include("bgp")

    # 5. 更新会话
    store.update_session("sess_core_rt01", port: 2222)
    expect(store.find_session("sess_core_rt01")[:port]).to eq(2222)

    # 6. 搜索——用 Tree 模拟分组层级
    # 搜索不在 Store 职责内，验证 find_session 替代
    expect(store.find_session("nonexistent")).to be nil

    # 7. 列出全部
    expect(store.sessions.size).to eq(2)
    expect(store.groups.size).to eq(2)

    # 8. 删除会话
    store.remove_session("sess_dev_srv01")
    expect(store.sessions.size).to eq(1)

    # 9. 删除分组
    store.remove_group("grp_dev")
    expect(store.groups.size).to eq(1)

    # 10. 重载
    store.reload
    expect(store.sessions.size).to eq(1)
    expect(store.find_session("sess_core_rt01")[:host]).to eq("10.0.0.1")
  end

  it "Schema 校验拒绝非法配置" do
    store.add_session(
      id: "bad_sess", host: "10.0.0.1", user: "admin",
      port: "not_a_port" # 应为 Integer
    )
    expect {
      NetworkInfraUtility::SSH::Config::Schema.validate(store.doc)
    }.to raise_error(NetworkInfraUtility::SSH::Config::SchemaError, /type mismatch/)
  end

  it "Schema 校验拒绝缺少必填字段" do
    store.add_session(
      id: "no_host", user: "admin" # 缺 host
    )
    expect {
      NetworkInfraUtility::SSH::Config::Schema.validate(store.doc)
    }.to raise_error(NetworkInfraUtility::SSH::Config::SchemaError, /missing required host/)
  end
end
