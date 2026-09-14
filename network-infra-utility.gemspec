# frozen_string_literal: true

require_relative "version"

Gem::Specification.new do |spec|
  spec.name          = "network-infra-utility"
  spec.version       = NetworkInfraUtility::VERSION
  spec.authors       = ["Matt"]
  spec.email         = ["matthrewchains@gmail.com","18995691365@189.cn"]

  spec.summary       = "这是`gem:network-utility`的AIGC重编码版"
  spec.description   = "这是`gem:network-utility`的AIGC重编码版，提供了基于工具、服务、文档、兼容支持的多种网络应用基础设施。"
  spec.homepage      = "https://github.com/ChenMeng1365/network-infra-utility"
  spec.license       = "AGPL-3.0-or-later"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")

  spec.metadata["homepage_uri"]    = "https://github.com/ChenMeng1365/network-infra-utility#readme"
  spec.metadata["source_code_uri"] = "https://github.com/ChenMeng1365/network-infra-utility"
  spec.metadata["changelog_uri"]   = "https://github.com/ChenMeng1365/network-infra-utility/blob/main/CHANGELOG.md"

  # example 用例随目录重组移至 document/example/, 排除规则同步覆盖新旧路径
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features|example|document/example)/}) }
  end
  # bin/ 既放对外命令 (geo-api) 也放开发脚本 (console/setup)，
  # executables 显式声明，避免把开发脚本当作系统命令安装到用户 PATH。
  spec.bindir       = "bin"
  spec.executables  = %w[geo-api geo-get geo-load geo-doc geo-update gen-get ngeo-get dns-query packbit probe simctl]
  spec.require_paths = ["document", "service", "service/ssh/lib", "service/simlab/lib", "support", "tool", "tool/probe/lib", "."]

  # 仿真场景 DSL 需要的运行时 gem
  spec.add_runtime_dependency "yaml", "~> 0.1"
  spec.add_runtime_dependency "roda", "~> 3.0"
  spec.add_runtime_dependency "rackup", "~> 2.0"
  spec.add_runtime_dependency "puma", "~> 6.0"
  spec.add_runtime_dependency "thor", "~> 1.3"
  spec.add_runtime_dependency "json", "~> 2.6"
end
