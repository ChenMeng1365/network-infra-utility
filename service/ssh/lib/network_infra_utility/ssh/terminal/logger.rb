# frozen_string_literal: true

require "fileutils"
require "time"
require "stringio"

module NetworkInfraUtility
  module SSH
    module Terminal
      # 会话日志记录与自动轮转。
      # 对应需求 FR-TERM-006。
      #
      # LLD §10.1 可观测性：
      #   路径模式  logs/<sess_id>/<ts>.log
      #   格式      纯文本带时间戳；可选 HTML
      #   轮转      单文件 100MB / 保留 10
      #
      # DoD（LLD §11.2）：自动轮转；HTML 格式带颜色还原
      #
      # 集成点：Emulator#feed 中 @logger&.write(data)
      class Logger
        DEFAULT_MAX_SIZE = 100 * 1024 * 1024 # 100MB
        DEFAULT_ROTATE   = 10                 # 保留 10 个文件
        TIMESTAMP_FORMAT = "%Y%m%d_%H%M%S"

        attr_reader :path, :max_size, :rotate, :format, :current_size

        # @param path [String] 日志文件路径（不含扩展名，自动加 .log 或 .html）
        # @param max_size [Integer] 单文件最大字节数
        # @param rotate [Integer] 保留轮转文件数
        # @param format [Symbol] :text 或 :html
        def initialize(path, max_size: DEFAULT_MAX_SIZE, rotate: DEFAULT_ROTATE, format: :text)
          @base_path = path
          @max_size = max_size
          @rotate = rotate
          @format = format
          @current_size = 0
          @write_mutex = Mutex.new
          @io = nil
          @html_header_written = false
          @seq = 0
          open_new_file
        end

        # 写入原始终端数据。
        # 由 Emulator#feed 调用，每次收到 SSH 通道数据即写入。
        # @param data [String] 原始字节
        def write(data)
          @write_mutex.synchronize do
            return unless @io

            if @format == :html
              write_html(data)
            else
              write_text(data)
            end

            @current_size += data.bytesize
            rotate_if_needed
          end
        end
        alias << write

        # 关闭当前日志文件
        def close
          @write_mutex.synchronize do
            if @format == :html && @io
              @io.write("</pre>\n</body>\n</html>\n")
            end
            @io&.close
            @io = nil
          end
        end

        # 切换格式（需重新打开文件）
        def format=(fmt)
          close
          @format = fmt
          @html_header_written = false
          open_new_file
        end

        private

        # 打开新的日志文件
        def open_new_file
          dir = File.dirname(@base_path)
          FileUtils.mkdir_p(dir)

          ext = @format == :html ? ".html" : ".log"
          timestamp = Time.now.strftime(TIMESTAMP_FORMAT)
          @seq += 1
          @path = "#{@base_path}_#{timestamp}_#{@seq}#{ext}"

          @io = File.open(@path, "wb")
          @io.sync = true
          @current_size = 0

          if @format == :html
            write_html_header
          else
            # 纯文本头部：时间戳
            @io.write("# Session log started at #{Time.now.iso8601}\n")
            @current_size += 30
          end
        end

        # 纯文本写入：带时间戳前缀
        def write_text(data)
          # 每行加时间戳前缀
          lines = data.split("\n", -1)
          lines.each_with_index do |line, i|
            next if line.empty? && i == lines.size - 1

            ts = Time.now.strftime("[%H:%M:%S] ")
            @io.write("#{ts}#{line}\n")
          end
        end

        # HTML 写入：保留 ANSI 颜色信息，转义 HTML 实体
        def write_html_header
          @io.write(<<~HTML)
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>SSH Session Log</title>
            <style>
              body { background: #1e1e1e; color: #d4d4d4; font-family: monospace; }
              pre { white-space: pre-wrap; word-wrap: break-word; }
            </style>
            </head>
            <body>
            <pre>
          HTML
          @html_header_written = true
        end

        # HTML 写入：ANSI 转义转为 span 标签
        def write_html(data)
          # 转义 HTML 实体
          escaped = data.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

          # ANSI SGR 转义序列 → <span style="color:...">
          # 这里的实现是骨架，完整 ANSI→HTML 转换在具体实现阶段完善
          # 覆盖常见 SGR：重置 \e[0m、前景色 \e[3Xm、加粗 \e[1m
          escaped.gsub!(/\e\[0m/, "</span>")
          escaped.gsub!(/\e\[1m/, '<span style="font-weight:bold">')
          escaped.gsub!(/\e\[3(\d)m/) do
            idx = Regexp.last_match(1).to_i
            color = ansi_color_to_css(idx)
            %(<span style="color:#{color}">)
          end

          @io.write(escaped)
        end

        # ANSI 8 色映射到 CSS 颜色
        def ansi_color_to_css(idx)
          %w[#000000 #cc0000 #00aa00 #aa5500 #0033cc #aa00aa #00aaaa #aaaaaa
             #555555 #ff5555 #55ff55 #ffff55 #5555ff #ff55ff #55ffff #ffffff][idx] || "#ffffff"
        end

        # 检查是否需要轮转
        def rotate_if_needed
          return if @current_size < @max_size

          @io.close
          if @format == :html
            # 需要给当前文件写尾部
            File.open(@path, "a") { |f| f.write("</pre>\n</body>\n</html>\n") }
          end

          # 清理超出 rotate 数量的旧文件
          cleanup_old_files
          open_new_file
        end

        # 清理超出保留数量的旧日志文件
        def cleanup_old_files
          dir = File.dirname(@base_path)
          base = File.basename(@base_path)
          ext = @format == :html ? ".html" : ".log"

          pattern = File.join(dir, "#{base}_*#{ext}")
          files = Dir.glob(pattern).sort_by { |f| File.mtime(f) }
          excess = files.size - @rotate
          return if excess <= 0

          files.first(excess).each { |f| File.delete(f) }
        end
      end
    end
  end
end
