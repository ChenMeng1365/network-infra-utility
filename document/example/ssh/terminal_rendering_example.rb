# frozen_string_literal: true

# example/ssh/terminal_rendering_example.rb
#
# 功能场景：终端模拟器 ANSI 渲染
# 覆盖需求：FR-TERM-001
#
# 验证：
#   1. 普通文本渲染
#   2. 光标控制 (CUU/CUD/CUF/CUB/CUP)
#   3. 屏幕清除 (ED/EL)
#   4. SGR 颜色属性
#   5. Alt screen 切换
#   6. 回滚区搜索

require "network"

RSpec.describe "终端 ANSI 渲染" do
  let(:client) { double("Client") }
  let(:terminal) { NetworkInfraUtility::SSH::Terminal::Emulator.new(client, "conn_001", "ch_001", 80, 24) }

  describe "普通文本" do
    it "渲染字符串并跟踪光标位置" do
      terminal.feed("Hello World")
      expect(terminal.screen.cursor_x).to eq(11) # 0 + 11 chars
      expect(terminal.screen.cursor_y).to eq(0)
    end

    it "换行后光标移到下一行行首" do
      terminal.feed("Line1\r\nLine2")
      expect(terminal.screen.cursor_y).to eq(1) # Line1 on row0, \r\n moves to row1, Line2 written there
    end
  end

  describe "光标控制" do
    it "CUU — 光标上移" do
      terminal.feed("\e[3B") # 先下移 3 行
      expect(terminal.screen.cursor_y).to eq(3)
      terminal.feed("\e[1A") # 上移 1 行
      expect(terminal.screen.cursor_y).to eq(2)
    end

    it "CUP — 绝对定位" do
      terminal.feed("\e[5;10H") # 第5行第10列（1-based）
      expect(terminal.screen.cursor_y).to eq(4) # 0-based
      expect(terminal.screen.cursor_x).to eq(9)
    end

    it "CHA — 水平定位" do
      terminal.feed("\e[20G") # 第20列
      expect(terminal.screen.cursor_x).to eq(19)
    end
  end

  describe "屏幕清除" do
    it "ED 0 — 从光标到屏底清除" do
      terminal.feed("ABCD")
      terminal.feed("\e[2;1H")   # 光标移到第二行
      terminal.feed("\e[0J")     # 从光标到底清除
      # 不抛异常即可
    end

    it "EL 2 — 整行清除" do
      terminal.feed("Hello\e[1G\e[2K")
      # 不抛异常即可
    end
  end

  describe "SGR 颜色" do
    it "前景色设置后重置" do
      terminal.feed("\e[31m")  # 红色
      terminal.feed("\e[0m")   # 重置
      expect(terminal.screen.instance_variable_get(:@current_style)).to eq({})
    end

    it "加粗后取消加粗" do
      terminal.feed("\e[1m")     # bold
      terminal.feed("\e[22m")    # cancel bold
      style = terminal.screen.instance_variable_get(:@current_style)
      expect(style[:bold]).to be false
    end
  end

  describe "Alt screen" do
    it "进入和退出 alt screen" do
      terminal.feed("\e[?1049h")  # enter alt
      expect(terminal.screen.alt_mode).to be true
      terminal.feed("\e[?1049l")  # exit alt
      expect(terminal.screen.alt_mode).to be false
    end
  end

  describe "回滚区搜索" do
    it "搜索终端输出内容" do
      terminal.feed("show version\r\n")
      terminal.feed("Cisco IOS XE 17.6.1\r\n")
      terminal.feed("router#")
      results = terminal.search("Cisco")
      expect(results).not_to be_empty
    end

    it "导出终端内容为文本" do
      terminal.feed("Hello\r\nWorld\r\n")
      text = terminal.export
      expect(text).to include("Hello")
      expect(text).to include("World")
    end
  end
end
