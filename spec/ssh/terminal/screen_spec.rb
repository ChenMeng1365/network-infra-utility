# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Terminal::Screen do
  let(:screen) { described_class.new(80, 24) }

  describe "初始化" do
    it "光标在 (0,0)" do
      expect(screen.cursor_x).to eq(0)
      expect(screen.cursor_y).to eq(0)
    end

    it "滚动区覆盖全屏" do
      expect(screen.scroll_top).to eq(0)
      expect(screen.scroll_bottom).to eq(23)
    end
  end

  describe "#put_char" do
    it "在指定位置写入字符" do
      screen.put_char("A", 0, 0)
      expect(screen.lines[0].to_s).to start_with("A")
    end

    it "更新光标位置" do
      screen.put_char("X", 5, 3)
      expect(screen.cursor_x).to eq(6)
      expect(screen.cursor_y).to eq(3)
    end
  end

  describe "#cursor_to" do
    it "设置光标位置并钳位到屏幕范围" do
      screen.cursor_to(10, 5)
      expect(screen.cursor_x).to eq(10)
      expect(screen.cursor_y).to eq(5)
    end

    it "负值钳位到 0" do
      screen.cursor_to(-5, -5)
      expect(screen.cursor_x).to eq(0)
      expect(screen.cursor_y).to eq(0)
    end

    it "超范围钳位到最大值" do
      screen.cursor_to(100, 100)
      expect(screen.cursor_x).to eq(79)
      expect(screen.cursor_y).to eq(23)
    end
  end

  describe "#newline" do
    it "在非底部行时光标下移并归零列" do
      screen.cursor_to(5, 10)
      screen.newline
      expect(screen.cursor_y).to eq(11)
      expect(screen.cursor_x).to eq(0)
    end

    it "在底部行时触发上滚" do
      screen.cursor_to(5, 23)
      expect { screen.newline }.not_to raise_error
      expect(screen.cursor_y).to eq(23)
    end
  end

  describe "#backspace" do
    it "光标左移" do
      screen.cursor_to(5, 0)
      screen.backspace
      expect(screen.cursor_x).to eq(4)
    end

    it "已经在最左时不变" do
      screen.backspace
      expect(screen.cursor_x).to eq(0)
    end
  end

  describe "#tab" do
    it "跳到下一个 8 的倍数" do
      screen.tab
      expect(screen.cursor_x).to eq(8)
    end
  end

  describe "#resize" do
    it "改变行列数" do
      screen.resize(120, 40)
      expect(screen.cols).to eq(120)
      expect(screen.rows).to eq(40)
    end

    it "调整后光标在新范围内" do
      screen.cursor_to(70, 20)
      screen.resize(40, 10)
      expect(screen.cursor_x).to eq(39)
      expect(screen.cursor_y).to eq(9)
    end
  end

  describe "#clear" do
    it ":full 清空全部行和光标" do
      screen.put_char("X", 0, 0)
      screen.clear(:full)
      expect(screen.lines[0].to_s).to eq("")
      expect(screen.cursor_x).to eq(0)
      expect(screen.cursor_y).to eq(0)
    end
  end

  describe "alt buffer" do
    it "切换到 alt 模式" do
      screen.enter_alt
      expect(screen.alt_mode).to be true
      expect(screen.cursor_x).to eq(0)
    end

    it "退出 alt 模式" do
      screen.enter_alt
      screen.exit_alt
      expect(screen.alt_mode).to be false
    end
  end
end
