# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Config::Settings do
  describe "DEFAULT_SETTINGS" do
    it "包含默认终端类型" do
      expect(described_class::DEFAULT_SETTINGS[:default_terminal]).to eq("xterm-256color")
    end

    it "默认回滚 10000 行" do
      expect(described_class::DEFAULT_SETTINGS[:default_scrollback]).to eq(10_000)
    end

    it "默认保活间隔 30 秒" do
      expect(described_class::DEFAULT_SETTINGS[:default_keepalive_interval]).to eq(30)
    end
  end

  describe "#initialize (无配置文件)" do
    let(:settings) { described_class.new(Dir.mktmpdir("settings_spec")) }

    after do
      FileUtils.rm_rf(settings.config_dir)
    end

    it "返回默认值" do
      expect(settings.default_terminal).to eq("xterm-256color")
      expect(settings.default_scrollback).to eq(10_000)
    end

    it "log_dir 默认在 config_dir/logs 下" do
      expect(settings.log_dir).to eq(File.join(settings.config_dir, "logs"))
    end

    it "路径方法返回 config_dir 下路径" do
      expect(settings.sessions_path).to eq(File.join(settings.config_dir, "sessions.yml"))
      expect(settings.vault_path).to eq(File.join(settings.config_dir, "vault.yml"))
      expect(settings.known_hosts_path).to eq(File.join(settings.config_dir, "known_hosts.yml"))
      expect(settings.settings_path).to eq(File.join(settings.config_dir, "settings.yml"))
    end
  end

  describe "master_password" do
    let(:settings) { described_class.new(Dir.mktmpdir("settings_spec")) }

    after do
      FileUtils.rm_rf(settings.config_dir)
    end

    it "默认为 nil" do
      expect(settings.master_password).to be nil
    end

    it "可设置" do
      settings.master_password = "secret"
      expect(settings.master_password).to eq("secret")
    end
  end
end
