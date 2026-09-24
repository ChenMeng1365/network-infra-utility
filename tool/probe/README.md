# probe — 网络服务连通性探测工具箱

对网络/服务类设备探测各类服务的连通性，纯 Ruby 标准库实现，零第三方运行时依赖。

## 覆盖协议

| 协议 | 类型 / 默认端口 | 探测方式 |
|------|----------------|---------|
| icmp | ICMP，无端口 | 系统 `ping`（跨平台，无需 root） |
| telnet | TCP 23 | TCP 三次握手 |
| ssh | TCP 22 | TCP 连接 + SSH 横幅校验 |
| netconf | TCP 830 | TCP 连接 + SSH 横幅校验（netconf-over-ssh） |
| snmp | UDP 161 | SNMP GET (sysDescr.0)，BER 自编码 |
| twamp | TCP 862 | TWAMP 控制会话端口可达（RFC 5357） |
| dns | UDP 53 | 向目标服务器发起 A 记录查询 |
| ntp | UDP 123 | 发送 NTP 客户端报文，等待响应 |
| radius | UDP 1812 | 发送 Access-Request，等待响应 |

## 命令行用法

```sh
probe 10.0.0.1 ssh snmp dns        # 指定协议
probe 10.0.0.1 --all               # 全部协议
probe 10.0.0.1 snmp --community RO # SNMP 团体名
probe 10.0.0.1 --all --json        # JSON 输出
probe 10.0.0.1 ssh --timeout 5     # 自定义超时
probe --list                       # 列出可用协议
```

## 代码级用法

```ruby
require "probe"

# 单协议
r = NetworkInfraUtility::Probe.run(:ssh, "10.0.0.1", timeout: 3)
r.ok?      # => true / false
r.status   # => :ok / :timeout / :refused / :unreachable / :fail / :unknown
r.latency  # => 耗时（秒）
r.to_h     # => Hash，便于 JSON 序列化

# 批量
results = NetworkInfraUtility::Probe.check("10.0.0.1", protocols: %i[ssh snmp dns])

# 全部协议
NetworkInfraUtility::Probe.check("10.0.0.1")

# 可用协议
NetworkInfraUtility::Probe.protocols
```

## 状态说明

| status | 含义 |
|--------|------|
| `ok` | 服务连通/正常响应 |
| `timeout` | 超时未响应 |
| `refused` | 连接被拒绝 |
| `unreachable` | 主机/网络不可达 |
| `fail` | 其它失败（如地址解析失败） |
| `unknown` | 未知错误或无法判定 |

## 扩展自定义协议

继承 `Probe::Base`，实现 `call`（返回 `Result`）并可选覆盖 `default_port`，再注册即可。

```ruby
class MyProbe < NetworkInfraUtility::Probe::Base
  def self.default_port
    9999
  end

  def call
    # ... 返回 result(:ok) / result(:timeout) 等
  end
end

NetworkInfraUtility::Probe::Registry.register(MyProbe)
```

## 注意事项

- **ICMP** 依赖系统 `ping` 命令；个别精简环境无 `ping` 时结果为 `:unknown`。
- **RADIUS** 无共享密钥时，服务器可能静默丢弃请求，「无响应」≠「服务不可达」。
- **SNMP** 需正确团体名/版本，否则即便服务可达也可能超时。
- **TWAMP** 仅验证控制端口（862）可达，完整会话需控制协议协商。
