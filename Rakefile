# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

# 原子能力验证
RSpec::Core::RakeTask.new(:spec)

# 功能场景用例
RSpec::Core::RakeTask.new(:example) do |t|
  t.pattern = "example/**/*_example.rb"
end

task default: %i[spec example]
