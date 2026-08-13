# frozen_string_literal: true

require "base64"
require "forwardable"
require_relative "screen"
require_relative "buffer"
require_relative "theme"
require_relative "logger"
require_relative "ansi_parser"

module NetworkInfraUtility
  module SSH
    module Terminal
      # ANSI/xterm 转义序列解析与终端状态维护。
      # 四层分离（LLD §7.6）：
      #   AnsiParser — 纯解析器，解析 ANSI 转义序列，回调 Emulator 方法
      #   Emulator  — 终端状态协调器，接收 AnsiParser 回调，委托给 Screen
      #   Screen    — 屏幕状态（行/光标/滚动区/alt buffer/字符属性）
      #   Buffer    — 回滚区 + 快照 + search/export
      class Emulator
        extend Forwardable

        attr_reader :conn_id, :channel_id, :screen, :buffer, :theme, :logger

        def initialize(client, conn_id, ch_id, cols, rows, theme: nil)
          @client = client
          @conn_id = conn_id
          @channel_id = ch_id
          @cols = cols
          @rows = rows
          @screen = Screen.new(cols, rows)
          @buffer = Buffer.new(max_lines: 10_000)
          @buffer.attach_screen(@screen)
          @theme = Theme.load(theme || "default")
          @parser = AnsiParser.new(self)
          @logger = nil
        end

        # 输入从 SSH 收到的原始字节
        def feed(data)
          @parser.feed(data)
          @logger&.write(data)
        end

        # 发送数据到 SSH 通道
        def send(data)
          @client.ipc.call("channel.send", {
            id: @channel_id,
            data: Base64.strict_encode64(data)
          })
        end

        # 发送一行（带 \r）
        def puts(text)
          send("#{text}\r")
        end

        # 窗口大小变更
        def resize(cols, rows)
          @screen.resize(cols, rows)
          @client.ipc.call("channel.window_change", {
            id: @channel_id, cols: cols, rows: rows
          })
        end

        def_delegators :@screen, :cursor_x, :cursor_y

        # 设置配色主题（FR-TERM-002）
        def theme=(theme_name)
          @theme = Theme.load(theme_name)
        end

        # 搜索缓冲区内容（FR-TERM-005, FR-TERM-007）
        def search(pattern)
          @buffer.search(pattern)
        end

        # 导出缓冲区为文本
        def export(path = nil)
          text = @buffer.to_text
          File.write(path, text) if path
          text
        end

        # 启动会话日志（FR-TERM-006）
        def start_logging(path, max_size: 100 * 1024 * 1024, rotate: 10)
          @logger = Logger.new(path, max_size: max_size, rotate: rotate)
        end

        def stop_logging
          @logger&.close
          @logger = nil
        end

        # ---- AnsiParser 回调 ----

        def put_char(ch, x = nil, y = nil, style = {})
          @screen.put_char(ch, x || @screen.cursor_x, y || @screen.cursor_y, style)
        end

        def cursor_to(x, y)
          @screen.cursor_to(x, y)
        end

        def newline
          @screen.newline
        end

        def backspace
          @screen.backspace
        end

        def tab
          @screen.tab
        end

        def clear_screen(mode = :full)
          @screen.clear(mode)
        end

        def clear_line(mode = :full)
          @screen.clear_line(mode)
        end

        def scroll_up(n = 1)
          @screen.scroll_up(n)
        end

        def scroll_down(n = 1)
          @screen.scroll_down(n)
        end

        def set_scroll_region(top, bottom)
          @screen.set_scroll_region(top, bottom)
        end

        def enter_alt_screen
          @screen.enter_alt
        end

        def exit_alt_screen
          @screen.exit_alt
        end

        def set_style(style)
          @screen.set_style(style)
        end

        def reset_style
          @screen.reset_style
        end

        def bell
          # 响铃回调，由 UI 层处理
        end
      end
    end
  end
end
