# frozen_string_literal: true

# example/ssh/vault_lifecycle_example.rb
#
# 功能场景：Vault 凭据加密存储完整生命周期
# 覆盖需求：FR-SEC-001
#
# 验证：
#   1. 主密码设置
#   2. 凭据加密存储
#   3. 凭据解密读取
#   4. 在连接规格中解析 vault 引用
#   5. 删除凭据
#   6. 持久化（重启后可读）

require "network"
require "tmpdir"

RSpec.describe "Vault 凭据生命周期" do
  let(:tmp_dir) { Dir.mktmpdir("vault_life") }
  let(:vault_path) { File.join(tmp_dir, "vault.yml") }
  let(:master_password) { "MySecurePassword123!" }
  let(:vault) { NetworkInfraUtility::SSH::Security::Vault.new(master_password, vault_path) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  it "完整生命周期：存储 → 读取 → 引用解析 → 删除 → 持久化" do
    # 1. 存储凭据
    vault.store("router_admin_pass", "C!sco#123")
    vault.store("linux_root_pass", "r00t$secret")

    # 2. 读取
    expect(vault.load("router_admin_pass")).to eq("C!sco#123")
    expect(vault.load("linux_root_pass")).to eq("r00t$secret")

    # 3. 在连接规格中解析引用
    spec = {
      host: "192.168.1.1",
      port: 22,
      user: "admin",
      auth: {
        type: "password",
        password: "~vault:router_admin_pass"
      }
    }
    resolved = vault.resolve_credentials(spec)
    expect(resolved[:auth][:password]).to eq("C!sco#123")
    # 原始规格不被修改
    expect(spec[:auth][:password]).to eq("~vault:router_admin_pass")

    # 4. 列出全部 key
    expect(vault.keys.sort).to eq(["linux_root_pass", "router_admin_pass"])

    # 5. 删除
    vault.delete("router_admin_pass")
    expect(vault.load("router_admin_pass")).to be nil

    # 6. 持久化——新建实例（模拟重启）
    vault_restarted = NetworkInfraUtility::SSH::Security::Vault.new(master_password, vault_path)
    expect(vault_restarted.load("linux_root_pass")).to eq("r00t$secret")

    # 7. 错误主密码无法解密
    vault_wrong = NetworkInfraUtility::SSH::Security::Vault.new("WrongPassword", vault_path)
    expect { vault_wrong.load("linux_root_pass") }.to raise_error(OpenSSL::Cipher::CipherError)
  end

  it "支持嵌套规格的递归引用解析" do
    vault.store("jump_pass", "jumP@123")

    spec = {
      host: "10.0.0.1",
      user: "admin",
      auth: { type: "password", password: "~vault:jump_pass" },
      jumps: [
        {
          host: "192.168.1.254",
          user: "jumpuser",
          auth: { type: "password", password: "~vault:jump_pass" }
        }
      ]
    }

    resolved = vault.resolve_credentials(spec)
    expect(resolved[:auth][:password]).to eq("jumP@123")
    expect(resolved[:jumps][0][:auth][:password]).to eq("jumP@123")
  end
end
