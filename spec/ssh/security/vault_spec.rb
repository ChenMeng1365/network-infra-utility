# frozen_string_literal: true

require "network"
require "tmpdir"

RSpec.describe NetworkInfraUtility::SSH::Security::Vault do
  let(:tmp_dir) { Dir.mktmpdir("vault_spec") }
  let(:vault_path) { File.join(tmp_dir, "vault.yml") }
  let(:vault) { described_class.new("test_master_password", vault_path) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#store / #load" do
    it "加密存储后可解密读取" do
      vault.store("sess_001_pass", "s3cr3t")
      expect(vault.load("sess_001_pass")).to eq("s3cr3t")
    end

    it "不同 key 互不干扰" do
      vault.store("key_a", "aaa")
      vault.store("key_b", "bbb")
      expect(vault.load("key_a")).to eq("aaa")
      expect(vault.load("key_b")).to eq("bbb")
    end

    it "未存储的 key 返回 nil" do
      expect(vault.load("nonexistent")).to be nil
    end

    it "load 结果缓存，二次读取不重复解密" do
      vault.store("cached", "val1")
      vault.load("cached")
      # 删除文件后缓存仍生效
      File.delete(vault_path)
      expect(vault.load("cached")).to eq("val1")
    end
  end

  describe "#delete" do
    it "删除后 load 返回 nil" do
      vault.store("to_delete", "del")
      expect(vault.load("to_delete")).to eq("del")
      vault.delete("to_delete")
      expect(vault.load("to_delete")).to be nil
    end
  end

  describe "#keys" do
    it "列出全部凭据标识" do
      vault.store("key1", "v1")
      vault.store("key2", "v2")
      expect(vault.keys.sort).to eq(%w[key1 key2])
    end
  end

  describe "#resolve_credentials" do
    it "替换 vault 引用为明文" do
      vault.store("srv_pass", "p@ssw0rd")
      spec = {
        host: "10.0.0.1",
        user: "admin",
        auth: { type: "password", password: "~vault:srv_pass" }
      }
      resolved = vault.resolve_credentials(spec)
      expect(resolved[:auth][:password]).to eq("p@ssw0rd")
      # 不修改入参
      expect(spec[:auth][:password]).to eq("~vault:srv_pass")
    end

    it "非引用值保持原样" do
      spec = { host: "10.0.0.1", port: 22 }
      resolved = vault.resolve_credentials(spec)
      expect(resolved[:host]).to eq("10.0.0.1")
      expect(resolved[:port]).to eq(22)
    end

    it "递归处理嵌套 hash 和数组" do
      vault.store("nested_key", "nested_val")
      spec = {
        jumps: [
          { host: "jump1", password: "~vault:nested_key" }
        ]
      }
      resolved = vault.resolve_credentials(spec)
      expect(resolved[:jumps][0][:password]).to eq("nested_val")
    end
  end

  describe "#vault_ref?" do
    it "识别 vault 引用" do
      expect(vault.vault_ref?("~vault:key1")).to be true
    end

    it "非引用返回 false" do
      expect(vault.vault_ref?("plain_text")).to be false
      expect(vault.vault_ref?(123)).to be false
    end
  end

  describe "初始化校验" do
    it "空主密码抛 ArgumentError" do
      expect { described_class.new("", vault_path) }.to raise_error(ArgumentError, /Master password/)
    end

    it "nil 主密码抛 ArgumentError" do
      expect { described_class.new(nil, vault_path) }.to raise_error(ArgumentError, /Master password/)
    end
  end
end
