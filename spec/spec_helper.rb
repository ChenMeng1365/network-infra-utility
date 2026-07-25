# frozen_string_literal: true

require "bundler/setup"

# 本 gem 按应用层次拆分为四个 require_paths（document/service/support/tool），
# 并提供根目录统一入口 network.rb。
#
# 推荐用统一入口：
#   require "network"
#
# 也可按需直接 require 具体模块（用于只测某一层）：
#   require "tool/xxx"
#   require "support/yyy"
#
# require_paths 已由 Bundler.setup 注入 $LOAD_PATH，无需手动 add_path。
