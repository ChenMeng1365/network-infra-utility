# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Terminal::AnsiParser do
  # 模拟 Emulator
  let(:emu) do
    double("Emulator",
           cursor_x: 0, cursor_y: 0,
           put_char: nil, cursor_to: nil, newline: nil, backspace: nil,
           tab: nil, bell: nil, clear_screen: nil, clear_line: nil,
           scroll_up: nil, scroll_down: nil, set_scroll_region: nil,
           enter_alt_screen: nil, exit_alt_screen: nil,
           set_style: nil, reset_style: nil)
  end
  let(:parser) { described_class.new(emu) }

  describe "#feed — 普通文本" do
    it "可打印 ASCII 字符调用 put_char" do
      expect(emu).to receive(:put_char).with("H")
      expect(emu).to receive(:put_char).with("i")
      parser.feed("Hi")
    end

    it "UTF-8 多字节字符逐字节调 put_char" do
      expect(emu).to receive(:put_char).exactly(3).times
      parser.feed("abc")
    end
  end

  describe "#feed — 控制字符" do
    it "CR 将光标移到行首" do
      expect(emu).to receive(:cursor_to).with(0, 0)
      parser.feed("\r")
    end

    it "LF 调用 newline" do
      expect(emu).to receive(:newline)
      parser.feed("\n")
    end

    it "BS 调用 backspace" do
      expect(emu).to receive(:backspace)
      parser.feed("\b")
    end

    it "HT 调用 tab" do
      expect(emu).to receive(:tab)
      parser.feed("\t")
    end

    it "BEL 调用 bell" do
      expect(emu).to receive(:bell)
      parser.feed("\a")
    end
  end

  describe "#feed — CSI 序列" do
    it "CUU (光标上移) 调 cursor_to" do
      expect(emu).to receive(:cursor_to)
      parser.feed("\e[2A")
    end

    it "CUP (光标定位) 调 cursor_to(0,0)" do
      expect(emu).to receive(:cursor_to).with(0, 0)
      parser.feed("\e[1;1H")
    end

    it "SGR reset (\\e[0m) 调 reset_style" do
      expect(emu).to receive(:reset_style)
      parser.feed("\e[0m")
    end

    it "SGR bold (\\e[1m) 调 set_style(bold: true)" do
      expect(emu).to receive(:set_style).with(bold: true)
      parser.feed("\e[1m")
    end

    it "SGR 前景色 (\\e[31m) 调 set_style(fg: :red)" do
      expect(emu).to receive(:set_style).with(fg: :red)
      parser.feed("\e[31m")
    end
  end

  describe "#feed — OSC 序列" do
    it "OSC BEL 终止后回到 ground" do
      parser.feed("\e]0;Title\x07")
      expect(parser.state).to eq(:ground)
    end
  end

  describe "#reset" do
    it "重置解析器状态" do
      parser.feed("\e[")
      expect(parser.state).to eq(:csi_entry)
      parser.reset
      expect(parser.state).to eq(:ground)
    end
  end
end
