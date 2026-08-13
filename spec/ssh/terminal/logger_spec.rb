# frozen_string_literal: true

require "network"
require "tmpdir"

RSpec.describe NetworkInfraUtility::SSH::Terminal::Logger do
  let(:tmp_dir) { Dir.mktmpdir("logger_spec") }
  let(:base_path) { File.join(tmp_dir, "session", "sess_001") }
  let(:logger) { described_class.new(base_path, max_size: 1024, rotate: 3) }

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe "#initialize" do
    it "自动创建目录和日志文件" do
      expect(File.exist?(logger.path)).to be true
    end

    it "文本格式写入头部时间戳" do
      content = File.read(logger.path)
      expect(content).to match(/Session log started/)
    end
  end

  describe "#write" do
    it "写入数据带时间戳前缀" do
      logger.write("hello\n")
      content = File.read(logger.path)
      expect(content).to match(/\[\d{2}:\d{2}:\d{2}\] hello/)
    end

    it "别名 << 等同 write" do
      logger << "world\n"
      content = File.read(logger.path)
      expect(content).to match(/world/)
    end
  end

  describe "轮转" do
    it "超过 max_size 触发轮转创建新文件" do
      old_path = logger.path
      logger.write("x" * 2048)
      expect(logger.path).not_to eq(old_path)
      expect(File.exist?(old_path)).to be true
    end

    it "超过保留数量时清理旧文件" do
      # max_size=1024, rotate=3, 写入大量数据触发多次轮转
      10.times { logger.write("x" * 2048 + "\n") }
      dir = File.dirname(base_path)
      log_files = Dir.glob(File.join(dir, "*.log"))
      expect(log_files.size).to be <= 4 # rotate(3) + current(1)
    end
  end

  describe "HTML 格式" do
    let(:html_logger) { described_class.new(base_path, max_size: 1024, rotate: 3, format: :html) }

    it "写入 HTML 头部" do
      content = File.read(html_logger.path)
      expect(content).to include("<!DOCTYPE html>")
      expect(content).to include("<pre>")
    end

    it "转义 HTML 实体" do
      html_logger.write("<script>alert('xss')</script>")
      content = File.read(html_logger.path)
      expect(content).to include("&lt;script&gt;")
    end
  end

  describe "#close" do
    let(:html_logger) { described_class.new(base_path, max_size: 1024, rotate: 3, format: :html) }

    it "HTML 格式写入尾部后关闭" do
      html_logger.close
      content = File.read(html_logger.path)
      expect(content).to include("</pre>")
      expect(content).to include("</html>")
    end

    it "文本格式直接关闭" do
      expect { logger.close }.not_to raise_error
    end
  end

  describe "#format=" do
    it "切换格式重新打开文件" do
      old_path = logger.path
      logger.format = :html
      expect(logger.path).not_to eq(old_path)
      content = File.read(logger.path)
      expect(content).to include("<html>")
    end
  end
end
