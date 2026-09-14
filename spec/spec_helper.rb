# frozen_string_literal: true

# Spec helper for routing/switching/simlab tests.
# 不依赖 bundler/setup，直接加载所需模块。
require "rspec"

# 加载项目根目录到 LOAD_PATH
$LOAD_PATH.unshift File.expand_path("..", __dir__)
