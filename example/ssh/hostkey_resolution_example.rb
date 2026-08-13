# frozen_string_literal: true

# example/ssh/hostkey_resolution_example.rb
#
# 功能场景：主机密钥验证全流程
# 覆盖需求：FR-SEC-002
#
# 验证三条裁决路径：
#   1. 未知主机 → 用户确认 → 存盘 → 下次自动 accept
#   2. 已知主机指纹匹配 → 自动 accept
#   3. 指纹变更 → 告警 → reject

require "network"
require "tmpdir"

RSpec.describe "主机密钥验证全流程" do
  let(:tmp_dir) { Dir.mktmpdir("hostkey_e2e") }
  let(:store_path) { File.join(tmp_dir, "known_hosts.yml") }
  let(:host_key) { NetworkInfraUtility::SSH::Security::HostKey.new(store_path) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  it "路径1：未知主机经用户确认后存盘，重连自动 accept" do
    fingerprint = "SHA256:ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"

    # 模拟用户交互回调
    prompt_calls = []
    host_key.on_prompt do |host, port, fp|
      prompt_calls << { host: host, port: port, fp: fp }
      :accept
    end

    # 第一次连接：未知主机
    result1 = host_key.resolve("10.0.0.1", 22, fingerprint)
    expect(result1[:action]).to eq("accept")
    expect(prompt_calls.size).to eq(1)
    expect(prompt_calls[0][:host]).to eq("10.0.0.1")
    expect(prompt_calls[0][:fp]).to eq(fingerprint)

    # 第二次连接：已存盘
    prompt_calls.clear
    result2 = host_key.resolve("10.0.0.1", 22, fingerprint)
    expect(result2[:action]).to eq("accept")
    expect(prompt_calls.size).to eq(0) # 不再弹 prompt
  end

  it "路径2：不同端口的同一主机视为不同条目" do
    fp_22 = "SHA256:port22_fingerprint"
    fp_2222 = "SHA256:port2222_fingerprint"

    host_key.on_prompt { :accept }

    host_key.resolve("10.0.0.2", 22, fp_22)
    host_key.resolve("10.0.0.2", 2222, fp_2222)

    expect(host_key.get("10.0.0.2", 22)[:fingerprint]).to eq(fp_22)
    expect(host_key.get("10.0.0.2", 2222)[:fingerprint]).to eq(fp_2222)
  end

  it "路径3：指纹变更触发告警并 reject" do
    old_fp = "SHA256:original_key"
    new_fp = "SHA256:changed_key"

    host_key.add("10.0.0.3", 22, old_fp)

    changed_events = []
    host_key.on_key_changed do |host, port, old, new|
      changed_events << { host: host, port: port, old: old, new: new }
    end

    result = host_key.resolve("10.0.0.3", 22, new_fp)
    expect(result[:action]).to eq("reject")
    expect(changed_events.size).to eq(1)
    expect(changed_events[0][:old]).to eq(old_fp)
    expect(changed_events[0][:new]).to eq(new_fp)

    # 确认旧指纹仍在文件中（reject 不覆盖）
    stored = host_key.get("10.0.0.3", 22)
    expect(stored[:fingerprint]).to eq(old_fp)
  end

  it "持久化：重启后已存条目可用" do
    host_key.add("10.0.0.4", 22, "SHA256:persist_test")

    # 新实例模拟重启
    hk_restarted = NetworkInfraUtility::SSH::Security::HostKey.new(store_path)
    entry = hk_restarted.get("10.0.0.4", 22)
    expect(entry[:fingerprint]).to eq("SHA256:persist_test")
    expect(entry[:added_at]).not_to be nil
  end

  it "list 返回结构化条目列表" do
    host_key.add("10.0.0.1", 22, "SHA256:aaa")
    host_key.add("10.0.0.2", 2222, "SHA256:bbb")

    list = host_key.list
    expect(list.size).to eq(2)

    list.each do |e|
      expect(e).to include(:host, :port, :fingerprint, :added_at)
    end
  end
end
