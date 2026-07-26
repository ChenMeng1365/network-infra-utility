
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-07-26

### Added

- 新增 `geo-load` 命令行工具：GeoLite2 CSV → JSON 转换，支持 `geo-load [RAW_DIR] [DOC_DIR]` 双位置参数，RAW_DIR 省略时在当前目录自动查找，DOC_DIR 省略时默认 `./geodb/`，不存在的输出目录自动创建。支持 `--asn-only` / `--city-only` / `--country-only` 单选转换。
- 新增 `geo-get` 命令行工具：向运行中的 geo-api 服务查询单个 IP 归属信息，一次输入三接口齐查，支持 `--text` / `--json` 两种输出格式与 `--country` / `--city` / `--asn` 单接口选择。
- `geo-load` / `geo-get` 加入 gemspec executables，`gem install` 后自动进入 PATH。
- 新增 example 文档：`ip_usage.md`（IP 模块代码级用法）、`geo_commands_usage.md`（Geo 三命令的命令行用法与代码级用法）。

## [0.2.0] - 2026-07-25

### Added

- 新增 `IPv4` / `IPv6` / `IPv4Mask` / `IPv6Mask` 地址解析模块，提供地址分类、掩码运算、CIDR 展开、子网划分、区间相交判断等能力。
- 新增 `IP` 统一入口模块，提供 `v4` / `v6` / `range` / `cross` / `xross` 五个方法，按地址串自动分派 IPv4 / IPv6。
- 从原版 `network` gem（`utility/ipv4_address.rb` / `ipv6_address.rb`）迁移并重新编码。

### Changed

- ⚠️ **部分 IP 转换含义发生变化**，与原版 `network` gem（`utility/ipv4_address.rb` / `ipv6_address.rb`）不兼容，升级时需注意：
  - `+` / `-` 算术运算从**破坏性**（原版直接修改 `@number` 并 `generate` 覆写自身）改为**非破坏性**（返回新对象，原对象不变）。
  - `&` 按位与的返回值从原版的 `IP.v4(...)` / `IP.v6(...)`（依赖 `module IP` 上下文）改为直接 `IPv4.new` / `IPv6.new`，不再隐式依赖 `IP` 模块。
  - `range_with` 原版返回 `[网络地址+1, 广播地址]`（排除了网络地址），新版改为 `[网络地址, 广播地址]`（含两端完整的网段区间）。
  - `delegation` 的子网生成从原版的 `clone` + 破坏性 `+` 改为非破坏性 `base + offset`，返回的结果是独立对象。
  - 方法命名规范化：原版的 `is_class_a?` / `is_mask?` / `is_private?` 等 `is_` 前缀方法保留为别名，新增无前缀的 `class_a?` / `mask?` / `private?` 等作为主方法名。
  - `is_another?` 重命名为 `special?`（保留 `is_another?` 别名）。
  - `IPv6` 非法地址从 `raise` + 返回 `nil` 的混合行为统一为抛出异常并附带 IPAddr 错误信息。
- `generate` 中的 `formmat` → `format_parts`、`check` / `checks` → `valid?`，内部方法名规范化，外部接口不变。

## [0.1.0] - 2026-07-24

### Added

- 初始化 gem 骨架，按 document / service / support / tool 四层 require_paths 组织代码。
- 配置 RSpec 原子能力测试（`spec/`）与功能用例（`example/`）双套结构。
- 提供标准 gem 文件：gemspec / Gemfile / Rakefile / .rspec / bin/console / bin/setup 等。
