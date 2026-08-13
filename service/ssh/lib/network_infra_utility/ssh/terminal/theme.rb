# frozen_string_literal: true

require "yaml"

module NetworkInfraUtility
  module SSH
    module Terminal
      # 配色方案加载/查询。
      # 对应需求 FR-TERM-002：内置 ≥ 10 套配色，支持导入 iTerm2/VSCode。
      class Theme
        BUILTIN_THEMES = {
          "default" => {
            bg: "#1e1e1e", fg: "#d4d4d4", cursor: "#d4d4d4",
            palette: %w[#000000 #cd3131 #0dbc79 #e5e510 #2472c8 #bc3fbc #11a8cd #e5e5e5
                        #666666 #f14c4c #23d18b #f5f543 #3b8eea #d670d6 #29b8db #e5e5e5]
          },
          "solarized-dark" => {
            bg: "#002b36", fg: "#839496", cursor: "#93a1a1",
            palette: %w[#073642 #dc322f #859900 #b58900 #268bd2 #d33682 #2aa198 #eee8d5
                        #002b36 #cb4b16 #586e75 #657b83 #839496 #6c71c4 #93a1a1 #fdf6e3]
          },
          "solarized-light" => {
            bg: "#fdf6e3", fg: "#657b83", cursor: "#586e75",
            palette: %w[#073642 #dc322f #859900 #b58900 #268bd2 #d33682 #2aa198 #eee8d5
                        #002b36 #cb4b16 #586e75 #657b83 #839496 #6c71c4 #93a1a1 #fdf6e3]
          },
          "dracula" => {
            bg: "#282a36", fg: "#f8f8f2", cursor: "#f8f8f2",
            palette: %w[#000000 #ff5555 #50fa7b #f1fa8c #bd93f9 #ff79c6 #8be9fd #bfbfbf
                        #4d4d4d #ff6e67 #5af78e #f4f99d #caa9fa #ff92d0 #9aedfe #e6e6e6]
          },
          "monokai" => {
            bg: "#272822", fg: "#f8f8f2", cursor: "#f8f8f0",
            palette: %w[#272822 #f92672 #a6e22e #fd971f #66d9ef #ae81ff #a1efe4 #f8f8f2
                        #75715e #f92672 #a6e22e #fd971f #66d9ef #ae81ff #a1efe4 #f9f8f5]
          },
          "nord" => {
            bg: "#2e3440", fg: "#d8dee9", cursor: "#d8dee9",
            palette: %w[#3b4252 #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #88c0d0 #e5e9f0
                        #4c566a #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #8fbcbb #eceff4]
          },
          "gruvbox-dark" => {
            bg: "#282828", fg: "#ebdbb2", cursor: "#ebdbb2",
            palette: %w[#282828 #cc241d #98971a #d79921 #458588 #b16286 #689d6a #a89984
                        #928374 #fb4934 #b8bb26 #fabd2f #83a598 #d3869b #8ec07c #ebdbb2]
          },
          "one-dark" => {
            bg: "#282c34", fg: "#abb2bf", cursor: "#abb2bf",
            palette: %w[#282c34 #e06c75 #98c379 #e5c07b #61afef #c678dd #56b6c2 #abb2bf
                        #5c6370 #e06c75 #98c379 #e5c07b #61afef #c678dd #56b6c2 #ffffff]
          },
          "tokyo-night" => {
            bg: "#1a1b26", fg: "#a9b1d6", cursor: "#c0caf5",
            palette: %w[#15161e #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #a9b1d6
                        #414868 #f7768e #9ece6a #e0af68 #7aa2f7 #bb9af7 #7dcfff #c0caf5]
          },
          "catppuccin-mocha" => {
            bg: "#1e1e2e", fg: "#cdd6f4", cursor: "#f5e0dc",
            palette: %w[#45475a #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #bac2de
                        #585b70 #f38ba8 #a6e3a1 #f9e2af #89b4fa #f5c2e7 #94e2d5 #a6adc8]
          },
          "github-dark" => {
            bg: "#0d1117", fg: "#c9d1d9", cursor: "#6cae50",
            palette: %w[#484f58 #ff7b72 #7ee787 #f2cc60 #79c0ff #d2a8ff #56d4dd #c9d1d9
                        #6e7681 #ffa198 #56d364 #e3b341 #79c0ff #bc8cff #56d4dd #f0f6fc]
          }
        }.freeze

        attr_reader :name, :data

        class << self
          def load(name)
            data = BUILTIN_THEMES[name] || load_custom(name) || BUILTIN_THEMES["default"]
            new(name, data)
          end

          def default
            load("default")
          end

          def builtin_names
            BUILTIN_THEMES.keys
          end

          # 从 iTerm2 .itermcolors 文件导入
          def import_iterm(path)
            # V2.0 功能，预留接口
            raise NotImplementedError, "iTerm2 import is V2.0"
          end

          # 从 VSCode .json 主题文件导入
          def import_vscode(path)
            # V2.0 功能，预留接口
            raise NotImplementedError, "VSCode import is V2.0"
          end

          private

          def load_custom(name)
            # 从 ~/.network-infra-utility/themes/<name>.yml 加载
            themes_dir = File.expand_path("~/.network-infra-utility/themes")
            path = File.join(themes_dir, "#{name}.yml")
            return nil unless File.exist?(path)

            YAML.safe_load(File.read(path), symbolize_names: true)
          end
        end

        def initialize(name, data)
          @name = name
          @data = data.transform_keys(&:to_sym)
        end

        def bg;   @data[:bg] || "#000000"; end
        def fg;   @data[:fg] || "#ffffff"; end
        def cursor; @data[:cursor] || fg; end
        def palette; @data[:palette] || []; end

        def color(index)
          return fg if index.nil? || index < 0 || index >= palette.size

          palette[index]
        end
      end
    end
  end
end
