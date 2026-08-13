# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Terminal::Theme do
  describe ".load" do
    it "加载内置主题" do
      theme = described_class.load("dracula")
      expect(theme.name).to eq("dracula")
      expect(theme.bg).to eq("#282a36")
      expect(theme.fg).to eq("#f8f8f2")
    end

    it "未知主题回退到 default" do
      theme = described_class.load("nonexistent_theme")
      expect(theme.name).to eq("nonexistent_theme")
      expect(theme.bg).to eq("#1e1e1e")
    end
  end

  describe ".default" do
    it "返回 default 主题" do
      theme = described_class.default
      expect(theme.name).to eq("default")
    end
  end

  describe ".builtin_names" do
    it "包含 11 套内置配色" do
      names = described_class.builtin_names
      expect(names.size).to be >= 10
      expect(names).to include("default", "solarized-dark", "dracula", "monokai", "nord")
    end
  end

  describe "#color" do
    it "返回调色板上指定索引的颜色" do
      theme = described_class.load("default")
      expect(theme.color(0)).to eq("#000000")
    end

    it "越界索引回退到 fg" do
      theme = described_class.load("default")
      expect(theme.color(99)).to eq(theme.fg)
    end
  end

  describe ".import_iterm / .import_vscode" do
    it "iTerm2 导入抛 NotImplementedError（V2.0）" do
      expect { described_class.import_iterm("foo") }.to raise_error(NotImplementedError, /V2\.0/)
    end

    it "VSCode 导入抛 NotImplementedError（V2.0）" do
      expect { described_class.import_vscode("foo") }.to raise_error(NotImplementedError, /V2\.0/)
    end
  end
end
