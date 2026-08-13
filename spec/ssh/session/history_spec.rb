# frozen_string_literal: true

require "network"

RSpec.describe NetworkInfraUtility::SSH::Session::History do
  let(:history) { described_class.new }

  # Stub Session 对象
  let(:sess1) { double("Session", conn_id: "conn_001") }
  let(:sess2) { double("Session", conn_id: "conn_002") }
  let(:sess3) { double("Session", conn_id: "conn_003") }

  describe "#record" do
    it "记录后出现在 items 中" do
      history.record(sess1)
      expect(history.items).to include(sess1)
    end

    it "最新记录排在最前" do
      history.record(sess1)
      history.record(sess2)
      expect(history.items.first).to eq(sess2)
    end

    it "同一会话不重复" do
      history.record(sess1)
      history.record(sess1)
      expect(history.items.size).to eq(1)
    end
  end

  describe "#pin / #unpin" do
    it "置顶条目排在 recent 最前" do
      history.record(sess1)
      history.record(sess2)
      history.pin("conn_001")
      recent = history.recent
      expect(recent.first.conn_id).to eq("conn_001")
    end

    it "取消置顶恢复排序" do
      history.record(sess1)
      history.record(sess2)
      history.pin("conn_001")
      history.unpin("conn_001")
      recent = history.recent
      expect(recent.first.conn_id).to eq("conn_002")
    end
  end

  describe "#recent" do
    it "置顶在前，非置顶在后" do
      history.record(sess1)
      history.record(sess2)
      history.record(sess3)
      history.pin("conn_001")
      recent = history.recent
      pinned = recent.select { |s| history.pinned[s.conn_id] }
      unpinned = recent.reject { |s| history.pinned[s.conn_id] }
      expect(pinned.map(&:conn_id)).to eq(["conn_001"])
      # unpinned 按时间倒序: sess3 在 sess2 前
      expect(unpinned.map(&:conn_id)).to eq(["conn_003", "conn_002"])
    end
  end

  describe "#clear" do
    it "清空全部" do
      history.record(sess1)
      history.pin(sess1)
      history.clear
      expect(history.items).to eq([])
      expect(history.pinned).to eq({})
    end
  end

  describe "上限" do
    it "超过 20 条自动裁剪" do
      25.times do |i|
        history.record(double("Session", conn_id: "conn_#{i}"))
      end
      expect(history.items.size).to eq(20)
    end
  end
end
