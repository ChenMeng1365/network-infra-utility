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

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features|example)/}) }
  end
  spec.bindir       = "exe"
  spec.executables  = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["document", "service", "support", "tool", "."]
end
