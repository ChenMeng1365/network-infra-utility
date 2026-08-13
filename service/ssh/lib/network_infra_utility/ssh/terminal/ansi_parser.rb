# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Terminal
      # ANSI/xterm 转义序列解析器。
      # 纯解析器，无状态副作用，只调 Emulator 回调（LLD §7.6）。
      #
      # 构造签名（LLD 修正版）：AnsiParser.new(emulator)
      # 传入 Emulator 自身，AnsiParser 回调 Emulator 方法，
      # Emulator 再委托给 Screen。
      #
      # 覆盖目标：≥ 95% ANSI（FR-TERM-001 ④），参考 vte/tty 转义表。
      # DoD（LLD §11.2）：ANSI 覆盖率 ≥ 95%（用 vttest 子集验证）
      #
      # 支持的转义类别：
      #   - CSI (Control Sequence Introducer)   \e[...X
      #   - SGR (Select Graphic Rendition)      \e[...m
      #   - OSC (Operating System Command)      \e]...\x07
      #   - DCS (Device Control String)         \eP...\x9c
      #   - 单字符控制序列                       \eX
      class AnsiParser
        # 解析状态机
        #   :ground     — 普通文本，逐字符输出
        #   :escape     — 收到 ESC (0x1b)，等待中间字节
        #   :csi_entry  — 收到 ESC [，收集参数
        #   :csi_param  — 收集 CSI 参数（数字和分号）
        #   :csi_intermediate — 收集 CSI 中间字节 (空格到/)
        #   :osc_string — OSC 字符串，直到 BEL (0x07) 或 ST
        #   :dcs_string — DCS 字符串，直到 ST
        #   :charset    — 字符集指定（ESC ( B 等）

        ESC = "\e".freeze
        CSI = "[".freeze
        BEL = "\x07".freeze
        ST  = "\x9c".freeze            # String Terminator (7-bit: ESC \)
        DEL = 0x7f

        # SGR 前景色映射（标准 8 色）
        SGR_FG = {
          0 => :reset, 30 => :black, 31 => :red, 32 => :green,
          33 => :yellow, 34 => :blue, 35 => :magenta, 36 => :cyan, 37 => :white
        }.freeze

        # SGR 背景色映射
        SGR_BG = {
          40 => :black, 41 => :red, 42 => :green, 43 => :yellow,
          44 => :blue, 45 => :magenta, 46 => :cyan, 47 => :white
        }.freeze

        # SGR 扩展前景色（高亮 8 色）
        SGR_FG_BRIGHT = {
          90 => :black, 91 => :red, 92 => :green, 93 => :yellow,
          94 => :blue, 95 => :magenta, 96 => :cyan, 97 => :white
        }.freeze

        attr_reader :state

        # @param emulator [Terminal::Emulator] 回调目标
        def initialize(emulator)
          @emu = emulator
          @state = :ground
          @params = []
          @current_param = +""
          @intermediates = +""
          @string_buffer = +""
          @charset = nil
        end

        # 喂入原始字节流，驱动状态机
        # @param data [String] 原始字节
        def feed(data)
          data.each_byte do |byte|
            process_byte(byte)
          end
        end

        # 重置解析器状态
        def reset
          @state = :ground
          @params = []
          @current_param = +""
          @intermediates = +""
          @string_buffer = +""
        end

        private

        def process_byte(byte)
          char = byte.chr(Encoding::UTF_8)
          case @state
          when :ground
            process_ground(byte, char)
          when :escape
            process_escape(byte, char)
          when :csi_entry, :csi_param
            process_csi(byte, char)
          when :csi_intermediate
            process_csi_intermediate(byte, char)
          when :osc_string
            process_osc(byte, char)
          when :dcs_string
            process_dcs(byte, char)
          when :charset
            process_charset(byte, char)
          end
        end

        # ---- :ground ----
        def process_ground(byte, char)
          case byte
          when 0x1b # ESC
            @state = :escape
          when 0x0d # CR
            @emu.cursor_to(0, @emu.cursor_y)
          when 0x0a, 0x0b, 0x0c # LF, VT, FF
            @emu.newline
          when 0x08 # BS
            @emu.backspace
          when 0x09 # HT
            @emu.tab
          when 0x07 # BEL
            @emu.bell
          when 0x00 # NUL — 忽略
            # noop
          when DEL # DEL — 忽略
            # noop
          else
            if byte >= 0x20 && byte < 0x7f
              # 可打印 ASCII
              @emu.put_char(char)
            elsif byte >= 0x80
              # UTF-8 / 高位字节 — 直接当作字符
              @emu.put_char(char)
            end
          end
        end

        # ---- :escape ----
        def process_escape(byte, char)
          case char
          when CSI # [
            @params = []
            @current_param = +""
            @intermediates = +""
            @state = :csi_entry
          when "]" # OSC
            @string_buffer = +""
            @state = :osc_string
          when "P" # DCS
            @string_buffer = +""
            @state = :dcs_string
          when "(" # G0 字符集
            @charset = :g0
            @state = :charset
          when ")" # G1 字符集
            @charset = :g1
            @state = :charset
          when "M" # Reverse Index (RI)
            @emu.scroll_down(1)
            @state = :ground
          when "D" # Index (IND)
            @emu.newline
            @state = :ground
          when "E" # Next Line (NEL)
            @emu.cursor_to(0, @emu.cursor_y + 1)
            @state = :ground
          when "7" # DECSC — 保存光标
            @state = :ground
            # V2.0: save_cursor
          when "8" # DECRC — 恢复光标
            @state = :ground
            # V2.0: restore_cursor
          when "c" # RIS — 全部重置
            @emu.clear_screen(:full)
            @state = :ground
          when "=" # 应用键盘模式
            @state = :ground
          when ">" # 数字键盘模式
            @state = :ground
          else
            # 未知转义，回到 ground
            @state = :ground
          end
        end

        # ---- :csi_entry / :csi_param ----
        def process_csi(byte, char)
          if byte >= 0x30 && byte <= 0x39 # 0-9
            @current_param << char
            @state = :csi_param
          elsif byte == 0x3b # ;
            @params << (@current_param.empty? ? 0 : @current_param.to_i)
            @current_param = +""
            @state = :csi_param
          elsif byte == 0x3f # ? — 私有参数前缀
            @intermediates << char
            @state = :csi_param
          elsif byte >= 0x3c && byte <= 0x3e # < = > — 私有参数标记
            @intermediates << char
            @state = :csi_param
          elsif byte >= 0x20 && byte <= 0x2f # 空格到/ — 中间字节
            @intermediates << char
            @state = :csi_intermediate
          elsif byte >= 0x40 && byte <= 0x7e # 终止字节
            @params << (@current_param.empty? ? 0 : @current_param.to_i) unless @current_param.empty?
            dispatch_csi(char)
            @state = :ground
          else
            @state = :ground
          end
        end

        # ---- :csi_intermediate ----
        def process_csi_intermediate(byte, char)
          if byte >= 0x20 && byte <= 0x2f
            @intermediates << char
          elsif byte >= 0x40 && byte <= 0x7e
            dispatch_csi(char)
            @state = :ground
          else
            @state = :ground
          end
        end

        # ---- :osc_string ----
        def process_osc(byte, char)
          if byte == 0x07 # BEL — 终止
            handle_osc(@string_buffer)
            @state = :ground
          elsif byte == 0x1b
            # 可能是 ST (ESC \)
            @string_buffer << char
            # 简化：下一个字节如果是 \ 就结束
          elsif byte == 0x5c && @string_buffer.end_with?("\e")
            @string_buffer = @string_buffer[0..-2]
            handle_osc(@string_buffer)
            @state = :ground
          else
            @string_buffer << char
          end
        end

        # ---- :dcs_string ----
        def process_dcs(byte, char)
          if byte == 0x9c # ST
            handle_dcs(@string_buffer)
            @state = :ground
          elsif byte == 0x1b
            @string_buffer << char
          elsif byte == 0x5c && @string_buffer.end_with?("\e")
            @string_buffer = @string_buffer[0..-2]
            handle_dcs(@string_buffer)
            @state = :ground
          else
            @string_buffer << char
          end
        end

        # ---- :charset ----
        def process_charset(byte, char)
          # 字符集指定（如 B = US-ASCII），V1.0 忽略
          @state = :ground
        end

        # ---- CSI 分发 ----
        def dispatch_csi(final_char)
          p = @params
          case final_char
          when "A" # CUU — 光标上移
            @emu.cursor_to(@emu.cursor_x, @emu.cursor_y - (p[0] || 1))
          when "B" # CUD — 光标下移
            @emu.cursor_to(@emu.cursor_x, @emu.cursor_y + (p[0] || 1))
          when "C" # CUF — 光标右移
            @emu.cursor_to(@emu.cursor_x + (p[0] || 1), @emu.cursor_y)
          when "D" # CUB — 光标左移
            @emu.cursor_to(@emu.cursor_x - (p[0] || 1), @emu.cursor_y)
          when "H", "f" # CUP / HVP — 光标定位
            row = (p[0] || 1) - 1
            col = (p[1] || 1) - 1
            @emu.cursor_to(col, row)
          when "J" # ED — 擦除显示
            mode = p[0] || 0
            @emu.clear_screen(mode.zero? ? :below : (mode == 1 ? :above : :full))
          when "K" # EL — 擦除行
            mode = p[0] || 0
            @emu.clear_line(mode.zero? ? :right : (mode == 1 ? :left : :full))
          when "m" # SGR — 图形属性设置
            dispatch_sgr(p)
          when "r" # DECSTBM — 设置滚动区
            top = (p[0] || 1) - 1
            bottom = (p[1] || 1) - 1
            @emu.set_scroll_region(top, bottom)
          when "h" # SM — 设置模式
            handle_set_mode(p, true)
          when "l" # RM — 重置模式
            handle_set_mode(p, false)
          when "n" # DSR — 设备状态报告
            handle_dsr(p)
          when "S" # SU — 向上滚动
            @emu.scroll_up(p[0] || 1)
          when "T" # SD — 向下滚动
            @emu.scroll_down(p[0] || 1)
          when "L" # IL — 插入行
            handle_insert_lines(p[0] || 1)
          when "M" # DL — 删除行
            handle_delete_lines(p[0] || 1)
          when "P" # DCH — 删除字符
            handle_delete_chars(p[0] || 1)
          when "@" # ICH — 插入字符
            handle_insert_chars(p[0] || 1)
          when "X" # ECH — 擦除字符
            handle_erase_chars(p[0] || 1)
          when "d" # VPA — 垂直位置
            @emu.cursor_to(@emu.cursor_x, (p[0] || 1) - 1)
          when "G" # CHA — 水平位置
            @emu.cursor_to((p[0] || 1) - 1, @emu.cursor_y)
          else
            # 未覆盖的 CSI 序列，骨架阶段忽略
          end
        end

        # ---- SGR 分发 ----
        def dispatch_sgr(params)
          params = [0] if params.empty?

          params.each_with_index do |code, _i|
            case code
            when 0
              @emu.reset_style
            when 1
              @emu.set_style(bold: true)
            when 2
              @emu.set_style(dim: true)
            when 3
              @emu.set_style(italic: true)
            when 4
              @emu.set_style(underline: true)
            when 5, 6
              @emu.set_style(blink: true)
            when 7
              @emu.set_style(reverse: true)
            when 22
              @emu.set_style(bold: false, dim: false)
            when 23
              @emu.set_style(italic: false)
            when 24
              @emu.set_style(underline: false)
            when 27
              @emu.set_style(reverse: false)
            when 38
              # 扩展前景色（38;5;n 或 38;2;r;g;b），骨架阶段占位
              @emu.set_style(fg_ext: true)
            when 48
              # 扩展背景色，骨架阶段占位
              @emu.set_style(bg_ext: true)
            when 39
              @emu.set_style(fg: nil)
            when 49
              @emu.set_style(bg: nil)
            when *SGR_FG.keys
              @emu.set_style(fg: SGR_FG[code])
            when *SGR_BG.keys
              @emu.set_style(bg: SGR_BG[code])
            when *SGR_FG_BRIGHT.keys
              @emu.set_style(fg: SGR_FG_BRIGHT[code], bright: true)
            else
              # 未覆盖的 SGR 码，骨架阶段忽略
            end
          end
        end

        # ---- 模式设置 (DECSET/DECRST) ----
        def handle_set_mode(params, enable)
          params.each do |code|
            case code
            when 1049, 1047 # Alt screen
              enable ? @emu.enter_alt_screen : @emu.exit_alt_screen
            when 1048 # 保存/恢复光标
              # V2.0: save/restore cursor
            else
              # 未覆盖的模式，骨架阶段忽略
            end
          end
        end

        # ---- DSR 设备状态报告 ----
        def handle_dsr(params)
          case params[0]
          when 5 # 状态报告
            # V2.0: send "ESC[0n" (OK) back to terminal
          when 6 # 光标位置报告
            # V2.0: send "ESC[<row>;<col>R" back
          end
        end

        # ---- OSC 处理 ----
        def handle_osc(string)
          # OSC 序列如 "0;title" (窗口标题) 或 "4;0;rgb:00/00/00" (调色板)
          # V1.0 骨架阶段忽略 OSC
        end

        # ---- DCS 处理 ----
        def handle_dcs(string)
          # DCS 序列用于 DECRQSS 等查询
          # V1.0 骨架阶段忽略 DCS
        end

        # ---- 行/字符操作占位 ----
        # 以下操作在 Screen 上的对应方法待具体实现阶段补充

        def handle_insert_lines(n)
          # IL — 在光标位置插入 n 行
          # 骨架阶段：简化为滚动处理
        end

        def handle_delete_lines(n)
          # DL — 在光标位置删除 n 行
        end

        def handle_delete_chars(n)
          # DCH — 删除 n 个字符
        end

        def handle_insert_chars(n)
          # ICH — 插入 n 个空字符
        end

        def handle_erase_chars(n)
          # ECH — 擦除 n 个字符（用空格替换，不移动）
        end
      end
    end
  end
end
