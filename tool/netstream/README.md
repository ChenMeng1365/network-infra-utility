# netstream — NetStream v5/v9 pcap 解析工具

从 pcap 抓包文件中解析华为 NetStream v5/v9 流记录，输出结构化 JSON。纯 Ruby 标准库实现，零第三方依赖。

## 两种工作模式

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| **预定义模板**（无模板猜测） | 使用逆向推断的预定义模板解析数据流 | 设备未发送模板、模板 FlowSet 已丢失 |
| **报文模板**（有模板解析） | 从抓包中解析模板 FlowSet，按报文模板解码 | 正常抓包含模板 FlowSet |

两种模式可同时启用。报文模板优先级高于预定义模板——当抓包中包含模板 FlowSet 时，自动覆盖同 ID 的预定义模板。

## 预定义模板

针对华为 NE5000E-20 (VRP V8) 逆向推断的 4 个 v9 模板：

| 模板 ID | 描述 | 记录长度 | 字段数 |
|---------|------|---------|--------|
| 1315 | IPv4 原始流 | 60B | 24 |
| 1316 | IPv6 原始流 | 112B | 23 |
| 1505 | IPv6/SR6-aware 原始流 | 84B | 22 |
| 1501 | 未知类型流 | 72B | 22 |

推断依据：对 2.2GB 抓包文件（linktype=1, UDP dst_port=9015, 全部 v9, 无模板 FlowSet）前 50000 包做 4B/2B/1B 三级粒度统计分析，20/20 校验通过。

## 命令行用法

```sh
netstream capture.pcap                         # 默认输出到 capture_netstream/
netstream capture.pcap -o output/              # 指定输出目录
netstream capture.pcap --templates-only        # 仅导出模板
netstream capture.pcap --no-predefined         # 仅用报文模板
netstream capture.pcap --no-capture-templates  # 仅用预定义模板
netstream capture.pcap --limit 50              # 每模板最多 50 条记录
netstream capture.pcap --stats                 # 输出统计到终端
netstream capture.pcap -q                      # 静默模式
```

## 输出结构

```
<output_dir>/
  templates.json    # 模板定义（预定义 + 报文，标注来源）
  records/          # 流记录 JSON（每条一个文件）
    00000001_1315_20260924T102030_000000Z.json
    00000002_1315_20260924T102030_000001Z.json
    ...
  summary.json      # 解析摘要 + 流量统计
```

## 代码级用法

```ruby
require "netstream"

# 解析 pcap 文件
result = NetworkInfraUtility::NetStream.parse("capture.pcap")
result.templates   # => { 1315 => { version: 9, option: false, fields: [...], ... }, ... }
result.records     # => [{ "ipv4_src_addr" => "10.0.0.1", "in_bytes" => 1000, ... }, ...]
result.stats       # => FlowStats
result.summary     # => Hash

# 仅用报文模板（不使用预定义）
result = NetworkInfraUtility::NetStream.parse("capture.pcap", use_predefined: false)

# 仅用预定义模板（不解析报文模板）
result = NetworkInfraUtility::NetStream.parse("capture.pcap", parse_templates: false)

# 限制每模板输出条数
result = NetworkInfraUtility::NetStream.parse("capture.pcap", limit: 100)

# 导出到目录
result = NetworkInfraUtility::NetStream.parse("capture.pcap", output_dir: "output/")
```

## 支持的 pcap 格式

- pcap little/big endian（magic 0xa1b2c3d4 / 0xd4c3b2a1）
- 链路类型 SLL(113) / EN10MB(1)
- IPv4 UDP 载荷
- NetStream v5: 固定 24B 头 + 48B/条记录
- NetStream v9: 模板化格式，20B 头 + FlowSet 序列
  - 模板 FlowSet (ID=0)
  - 选项模板 FlowSet (ID=1)
  - 数据 FlowSet (ID>1)

## 流式读取

采用流式逐包读取 pcap 文件，内存恒定，适合处理大文件（2GB+）。
