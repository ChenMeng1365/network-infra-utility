# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Terminal
      # 屏幕状态：行数组 + 光标 + 滚动区 + alt buffer + 字符属性。
      # 由 AnsiParser 经 Emulator 回调驱动。
      class Screen
        attr_reader :cols, :rows, :cursor_x, :cursor_y
        attr_reader :scroll_top, :scroll_bottom
        attr_reader :alt_mode

        def initialize(cols, rows)
          @cols = cols
          @rows = rows
          @cursor_x = 0
          @cursor_y = 0
          @scroll_top = 0
          @scroll_bottom = rows - 1
          @alt_mode = false
          @main_lines = Array.new(rows) { Line.new(@cols) }
          @alt_lines = Array.new(rows) { Line.new(@cols) }
          @current_style = {}
        end

        def lines
          @alt_mode ? @alt_lines : @main_lines
        end

        def put_char(ch, x, y, style = {})
          line = lines[y]
          return unless line

          line.put_char(ch, x, style.empty? ? @current_style : style)
          @cursor_x = x + 1
          @cursor_y = y
        end

        def cursor_to(x, y)
          @cursor_x = [[x, 0].max, @cols - 1].min
          @cursor_y = [[y, 0].max, @rows - 1].min
        end

        def newline
          if @cursor_y >= @scroll_bottom
            scroll_up(1)
          else
            @cursor_y += 1
          end
          @cursor_x = 0
        end

        def backspace
          @cursor_x = [@cursor_x - 1, 0].max
        end

        def tab
          @cursor_x = ((@cursor_x / 8) + 1) * 8
          @cursor_x = [@cursor_x, @cols - 1].min
        end

        def clear(mode = :full)
          case mode
          when :full
            @main_lines.each { |l| l.clear(@cols) }
            @alt_lines.each { |l| l.clear(@cols) }
            @cursor_x = 0
            @cursor_y = 0
          when :above
            clear_above_cursor
          when :below
            clear_below_cursor
          end
        end

        def clear_line(mode = :full)
          line = lines[@cursor_y]
          return unless line

          case mode
          when :full then line.clear(@cols)
          when :right then line.clear_from(@cursor_x, @cols)
          when :left then line.clear_range(0, @cursor_x)
          end
        end

        def scroll_up(n = 1)
          n.times do
            # 将滚动区首行移入回滚（由 Buffer 处理），后续行上移
            @scroll_top.upto(@scroll_bottom - 1) do |i|
              lines[i] = lines[i + 1]
            end
            lines[@scroll_bottom] = Line.new(@cols)
          end
        end

        def scroll_down(n = 1)
          n.times do
            @scroll_bottom.downto(@scroll_top + 1) do |i|
              lines[i] = lines[i - 1]
            end
            lines[@scroll_top] = Line.new(@cols)
          end
        end

        def set_scroll_region(top, bottom)
          @scroll_top = [[top, 0].max, @rows - 1].min
          @scroll_bottom = [[bottom, 0].max, @rows - 1].min
          @cursor_x = 0
          @cursor_y = @scroll_top
        end

        def enter_alt
          @alt_mode = true
          @cursor_x = 0
          @cursor_y = 0
        end

        def exit_alt
          @alt_mode = false
          @cursor_x = 0
          @cursor_y = 0
        end

        def set_style(style)
          @current_style = @current_style.merge(style)
        end

        def reset_style
          @current_style = {}
        end

        def resize(cols, rows)
          old_cols = @cols
          @cols = cols
          [@main_lines, @alt_lines].each do |ary|
            if rows > ary.size
              (rows - ary.size).times { ary << Line.new(cols) }
            elsif rows < ary.size
              ary.slice!(rows..)
            end
            ary.each { |l| l.resize(cols) } if cols != old_cols
          end
          @rows = rows
          @scroll_bottom = rows - 1
          @cursor_x = [@cursor_x, cols - 1].min
          @cursor_y = [@cursor_y, rows - 1].min
        end

        def to_text
          lines.map(&:to_s).join("\n")
        end

        private

        def clear_above_cursor
          0.upto(@cursor_y - 1) { |i| lines[i]&.clear(@cols) }
          lines[@cursor_y]&.clear_range(0, @cursor_x)
        end

        def clear_below_cursor
          lines[@cursor_y]&.clear_from(@cursor_x, @cols)
          (@cursor_y + 1).upto(@rows - 1) { |i| lines[i]&.clear(@cols) }
        end

        # 一行字符
        class Line
          attr_reader :cells

          def initialize(cols)
            @cells = Array.new(cols) { Cell.new }
          end

          def put_char(ch, x, style = {})
            @cells[x] = Cell.new(ch, style) if x < @cells.size
          end

          def clear(cols)
            @cells = Array.new(cols) { Cell.new }
          end

          def clear_from(x, cols)
            x.upto([cols - 1, @cells.size - 1].min) { |i| @cells[i] = Cell.new }
          end

          def clear_range(from, to)
            from.upto([to, @cells.size - 1].min) { |i| @cells[i] = Cell.new }
          end

          def resize(cols)
            if cols > @cells.size
              @cells += Array.new(cols - @cells.size) { Cell.new }
            elsif cols < @cells.size
              @cells = @cells[0...cols]
            end
          end

          def to_s
            @cells.map(&:char).join.rstrip
          end
        end

        # 单字符单元
        Cell = Struct.new(:char, :style) do
          def initialize(char = " ", style = {})
            super
          end
        end
      end
    end
  end
end
