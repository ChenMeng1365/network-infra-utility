---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'b2f96116-44bf-4de9-98ce-09f3024c1bc2'
  PropagateID: 'b2f96116-44bf-4de9-98ce-09f3024c1bc2'
  ReservedCode1: 'c2be245c-55df-4468-ae05-eb437b82973b'
  ReservedCode2: 'c2be245c-55df-4468-ae05-eb437b82973b'
---

# Network Infrastructure Utility

重新编排 Network（`gem: network-utility`）。

## 项目结构

本 gem 按应用层次拆分，各层目录即其子模块的 `require` 根，不再统一 `lib/`：

| 目录 | 层次定位 |
| --- | --- |
| `document/` | 文档/配置生成层 |
| `service/` | 业务服务层 |
| `support/` | 辅助/支撑层 |
| `tool/` | 工具/原子能力层 |

测试体系：

- `spec/` —— 原子能力验证（单元规格）
- `document/example/` —— 常用场景的功能用例

## 安装

```sh
bin/setup        # 安装开发依赖
bin/console      # 进入带 gem 环境的 IRB
```

## 使用

```ruby
require "network"   # 统一入口，按 support → tool → service → document 顺序加载所有子模块
```

## 开发

```sh
bundle exec rake spec      # 跑原子能力
bundle exec rake example   # 跑功能用例
bundle exec rake           # 两者都跑（默认）
```

## License

采用 [GNU Affero General Public License v3.0 或更高版本](https://www.gnu.org/licenses/agpl-3.0.html)（AGPL-3.0-or-later），详见 [LICENSE.txt](LICENSE.txt)。

> AI生成