# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Terminal
      # 回滚区 + 当前屏幕快照，提供 search/export。
      # 写入由 Screen 触发（滚动时旧行进入回滚区）。
      # 对应需求 FR-TERM-007：默认 ≥ 10000 行，可配置 1000–100000。
      class Buffer
        attr_reader :scrollback_lines, :max_lines
        attr_accessor :screen

        def initialize(max_lines: 10_000)
          @max_lines = max_lines
          @scrollback_lines = []   # 已滚出屏幕的历史行
          @screen = nil
        end

        # 绑定 Screen，接收滚动事件
        def attach_screen(screen)
          @screen = screen
        end

        # Screen 滚动时调用，将被推出的行加入回滚区
        def push_scrollback(line_text)
          @scrollback_lines << line_text
          trim
        end

        # 全量行数（回滚 + 屏幕）
        def total_lines
          @scrollback_lines.size + (@screen&.rows || 0)
        end

        # 搜索全部内容（回滚 + 屏幕）
        # @param pattern [String] 正则表达式
        # @return [Array<Match>]
        def search(pattern)
          regex = Regexp.new(pattern, Regexp::IGNORECASE)
          matches = []
          all_lines.each_with_index do |line, idx|
            line.scan(regex) do
              m = Regexp.last_match
              matches << Match.new(line: idx, start: m.begin(0), end_: m.end(0), text: m[0])
            end
          end
          matches
        end

        # 导出纯文本
        def to_text
          all_lines.join("\n")
        end

        # 设置最大回滚行数
        def max_lines=(n)
          @max_lines = n
          trim
        end

        private

        def all_lines
          @scrollback_lines + (@screen ? @screen.lines.map(&:to_s) : [])
        end

        def trim
          return if @scrollback_lines.size <= @max_lines

          @scrollback_lines = @scrollback_lines[-@max_lines..]
        end
      end

      # 搜索匹配结果
      Match = Struct.new(:line, :start, :end_, :text)
    end
  end
end
