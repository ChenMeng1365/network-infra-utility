# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Terminal::Buffer do
  let(:buffer) { described_class.new(max_lines: 100) }

  # Stub Screen
  let(:screen) do
    double("Screen", rows: 5, lines: [
      double("Line", to_s: "line1"),
      double("Line", to_s: "line2")
    ])
  end

  before do
    buffer.attach_screen(screen)
  end

  describe "#push_scrollback" do
    it "添加行到回滚区" do
      buffer.push_scrollback("old_line")
      expect(buffer.scrollback_lines).to include("old_line")
    end

    it "超过 max_lines 时裁剪" do
      120.times { |i| buffer.push_scrollback("line_#{i}") }
      expect(buffer.scrollback_lines.size).to eq(100)
    end
  end

  describe "#total_lines" do
    it "回滚 + 屏幕行数" do
      buffer.push_scrollback("hist1")
      buffer.push_scrollback("hist2")
      # scrollback size 2, screen rows 5
      expect(buffer.total_lines).to eq(7)
    end
  end

  describe "#search" do
    before do
      buffer.push_scrollback("the quick brown")
      buffer.push_scrollback("fox jumps over")
    end

    it "搜索匹配字符串" do
      results = buffer.search("quick")
      expect(results).not_to be_empty
      expect(results.first.text).to eq("quick")
    end

    it "大小写不敏感" do
      results = buffer.search("QUICK")
      expect(results).not_to be_empty
    end

    it "无匹配返回空数组" do
      results = buffer.search("nonexistent_text")
      expect(results).to eq([])
    end
  end

  describe "#to_text" do
    it "回滚 + 屏幕拼接" do
      buffer.push_scrollback("hist_line")
      text = buffer.to_text
      expect(text).to include("hist_line")
      expect(text).to include("line1")
    end
  end

  describe "#max_lines=" do
    it "更新上限并裁剪" do
      50.times { |i| buffer.push_scrollback("line_#{i}") }
      buffer.max_lines = 20
      expect(buffer.scrollback_lines.size).to eq(20)
    end
  end
end
