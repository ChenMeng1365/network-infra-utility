# packbit — pcap 抓包解析工具

> Ruby CLI + Erlang 引擎，通过 YAML 配置文件驱动筛选、统计、展示。

## 架构

```
bin/packbit              Ruby 命令行入口 (参数解析 + 调用 escript)
tool/packbit/erl/        Erlang escript 核心引擎 (pcap 读取 + 协议解析 + 统计)
tool/packbit/config/     YAML 配置文件
```

零第三方依赖：Ruby 仅用标准库，Erlang 仅用标准库。

## 快速上手

```sh
# 全量逐字段解析 (每包每层所有字段)
packbit -f capture.pcap

# 摘要模式 (统计表 + 每包一行)
packbit -f capture.pcap -d

# 按配置文件筛选/统计/展示
packbit -f capture.pcap -c tool/packbit/config/packbit.yml

# 按端口+协议筛选
packbit -f capture.pcap -p 80 tcp

# flow 分组统计 (源IP->目的IP)
packbit -f capture.pcap -c tool/packbit/config/flow.yml -d

# 五元组分组统计
packbit -f capture.pcap -c tool/packbit/config/five-tuple.yml -d
```

## 配置文件

配置文件为 YAML 格式，分三个段：`filter`（筛选）、`stats`（统计）、`display`（展示）。

### filter — 筛选

```yaml
filter:
  protocol:       # 按协议名筛选，留空 = 不过滤
    - tcp
    - udp
  port: 80        # 按端口号筛选 (源或目的)
  ip: 10.0.0.1    # 按 IP 地址筛选 (源或目的)
```

### stats — 统计

```yaml
stats:
  group_by: stack     # 分组维度 (见下表)
  sort_by: count      # count (按包数排序) | bytes (按流量排序)
  sort: desc          # desc (多→少) | asc (少→多)
  top: 10             # 只显示前 N 条，0 = 全部
```

#### group_by 取值

| 取值 | 说明 | 示例输出 |
|------|------|---------|
| `stack` | 按协议栈分组 | `Ethernet/IPv4/TCP 12345>80` |
| `protocol` | 按顶层协议分组 | `TCP`、`UDP`、`ARP` |
| `flow` | 源IP->目的IP 组合 | `10.0.0.1 -> 8.8.8.8` |
| 字段列表 | 任意字段组合 | 见下方说明 |

**字段列表写法**（多行 `- field_name` 格式）：

```yaml
stats:
  group_by:
    - src_ip
    - dst_ip
    - src_port
    - dst_port
    - protocol
```

输出形如 `10.0.0.1 -> 8.8.8.8 -> 12345 -> 80 -> tcp`，缺失字段用 `-` 填充。

可用字段：`src_ip`、`dst_ip`、`src_port`、`dst_port`、`protocol`、`ttl`、`header_len`、`total_length` 等协议栈各层字段。

### display — 展示

```yaml
display:
  mode: detail       # detail (逐包逐层) | summary (统计表)
  fields:            # 紧凑模式: 只显示这些字段，一行一包
    - src_ip
    - dst_ip
    - src_port
    - dst_port
  payload: true      # 显示载荷 (detail 模式)
  color: false       # 彩色输出 (false = 纯文本)
```

## 命令行选项

```
packbit -f <pcap> [选项]

  -f, --file FILE       pcap 文件路径
  -c, --config FILE     YAML 配置文件 (筛选/统计/展示)
  -d, --summary         摘要模式 (统计表 + 每包一行)
  -p, --port PORT PROTO 按端口+协议筛选 (如 -p 80 tcp)
  -h, --help            显示帮助
  -v, --version         显示版本
```

## 支持的协议

Ethernet II、802.1Q VLAN、IPv4、IPv6、ARP、TCP、UDP、ICMP、ICMPv6。

## 内置配置文件

| 文件 | 说明 |
|------|------|
| `packbit.yml` | 默认配置 (filter: tcp, stats: stack, display: detail) |
| `flow.yml` | 源IP->目的IP 流量统计 |
| `five-tuple.yml` | 五元组流量统计 (源/目的IP + 源/目的端口 + 协议) |

## 依赖

- **Ruby** — 命令行入口 (仅标准库)
- **Erlang/OTP** — 核心解析引擎 (escript)

```sh
# 安装 Erlang/OTP
# Windows:  choco install erlang
# Linux:    apt install erlang / yum install erlang
# macOS:    brew install erlang
```
