---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: '88e1794b-cd8d-483e-b3d2-ee4485fccf96'
  PropagateID: '88e1794b-cd8d-483e-b3d2-ee4485fccf96'
  ReservedCode1: '20f6bf17-f91c-4c4c-b721-e45f1eb19345'
  ReservedCode2: '20f6bf17-f91c-4c4c-b721-e45f1eb19345'
---

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- 新增 `gen-get` 命令行工具：调用免费互联网接口查询 IP 归属，默认 ip-api.com 及其参数（`lang=zh-CN` + `status,message,country,regionName,city,isp,as,query`，`message` 为诊断扩展），内置 45 req/min 限速（最小间隔 1.4s）与本地 JSON 缓存；互联网不通时返回明确的 `unreachable`（互联网查询不可达）空结果状态并区分于 `empty`（确认无归属，如私有地址）。
- 新增 `ngeo-get` 命令行工具：综合 geo-get（本地 geo-api）与 gen-get（互联网）两个数据源——本地接口可用时优先使用；归属不满意（省/市/ASN 缺失）时自动补互联网查询；本地与互联网结果字段级叠加（省/城市/用途 IDC·云等准确字段择优，网段保留本地，运营商按合并后组织名归一化）。结果状态可信度链：`unreachable < local-partial < empty < local < online < merged`，互联网不可达时本地部分结果保留；连续 3 次不可达触发 60s 熔断。
- 新增 `service/geoquery/` 服务模块：`OnlineClient`（ip-api.com 客户端）、`LocalClient`（geo-api 客户端）、`Merge`（字段叠加）、`Normalize`（运营商/用途归一化）、`Cache`（线程安全 JSON 缓存）、`NGeo`（综合查询门面），移植自 `ip_geo_lookup.py` 的多级回退 + 缓存 + 归一化设计。
- `gen-get` / `ngeo-get` 加入 gemspec executables，`network.rb` 统一入口挂载 geoquery；新增 `spec/geoquery_spec.rb`（状态机/归一化/合并/缓存/熔断）与 `document/example/geoquery_example.rb` 功能用例；接口文档见 `service/geoquery/GeoQuery.md`。

### Changed

- `geo-get` 重构为 `GeoQuery::LocalClient` 的瘦封装：三接口拉取与汇总逻辑统一收口在 `service/geoquery/local.rb`（新增 `fetch_raw` 原始接口查询，保持 geo-get `-j` 输出的原始响应契约不变），geo-get 与 ngeo-get / gen-get 共享同一套客户端实现，消除双实现；CLI 选项、文字/JSON 输出格式、服务未启动提示均保持向后兼容，另支持 `GEO_API_BASE` 环境变量覆盖服务地址。
- 合并 `geo_api_query_example.rb`（geo-api 服务三接口）与旧版 `geoquery_example.rb`（GeoQuery 查询编排）为单一 `document/example/geoquery_example.rb`：按“Part A 服务接口 → Part B 查询编排”组织为 11 个案例块，新增 LocalClient（`fetch_raw` / `lookup`）演示；Part B 复用 Part A 启动的服务实例（支持 `GEOAPI=` 覆盖为外部服务），通过 `$LOAD_PATH` 前插仓库根消除工作区与已安装 gem 的双重加载警告。
- `example/` 目录整体移至 `document/example/`（并入文档层），`Rakefile` example 任务 pattern、gemspec 文件排除规则（新增 `document/example/`）与根 README 项目结构表同步更新。
- 新增 `probe` 服务连通性探测工具箱（`tool/probe/`），覆盖 icmp / telnet / ssh / netconf / snmp / twamp / dns / ntp / radius 九类协议，纯 Ruby 标准库实现、零第三方运行时依赖。
  - 统一探测框架：`Probe::Base` 基类 + `Probe::Result` 统一结果 + `Probe::Registry` 注册表，协议名从类名自动派生，支持 `Registry.register` 扩展自定义探针。
  - 内置 BER 编码器（SNMPv1/v2c GET 请求自编码）、NTP 48 字节客户端报文、RADIUS Access-Request 报文构造。
  - TCP 探针区分 timeout / refused / unreachable；SSH/NETCONF 附加横幅校验；ICMP 复用系统 ping 并兼容中英文输出解析 RTT。
  - 提供 `Probe.run(protocol, host)` / `Probe.check(host, protocols:)` 代码级 API 与 `bin/probe` 命令行工具（支持 `--all` / `--json` / `--timeout` / `--community` 等选项）。
  - `probe` 加入 gemspec executables，`tool/probe/lib` 加入 require_paths，`network.rb` 统一入口已挂载。

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

> AI生成