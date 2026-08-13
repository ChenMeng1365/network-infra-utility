
# DNS Query 命令工具使用方法

> 命令文件：`bin/dns-query`
> 运行方式：`ruby bin/dns-query`

跨平台统一域名查询工具：自动检测当前系统所有可用的 DNS 查询工具（dig / nslookup / host / Resolve-DnsName / ping -a 等），默认使用优先级最高的工具执行查询。用户无需关心底层工具差异，也不需要记住各家工具的参数差异。

---

## 一、命令行用法

**用法：**

```
ruby bin/dns-query <目标> [选项]
```

**位置参数：**

| 参数 | 说明 |
|------|------|
| `<目标>` | 域名（正查）或 IP 地址（反查 PTR）。目标为 IP 地址时自动切换为 PTR 反查 |

**选项：**

| 选项 | 说明 |
|------|------|
| `-t, --type TYPE` | DNS 记录类型，默认 `A`。支持 `A` / `AAAA` / `CNAME` / `MX` / `NS` / `PTR` / `SOA` / `TXT` / `SRV` / `ANY` |
| `-s, --server SERVER` | 指定 DNS 服务器（IP 或域名），默认用系统 DNS |
| `-a, --all` | 使用当前平台所有可用工具交叉查询 |
| `--tools` | 列出当前平台可用工具及优先级 |
| `--matrix` | 显示 10 个查询工具的全平台支持矩阵 |
| `--no-color` | 禁用 ANSI 颜色输出（适合重定向到文件或管道） |
| `-v, --version` | 显示版本号 |
| `-h, --help` | 显示帮助 |

**示例：**

```bash
# 正查 A 记录（默认）
ruby bin/dns-query www.baidu.com

# 反查 PTR 记录（自动识别 IP）
ruby bin/dns-query 8.8.8.8

# 指定记录类型
ruby bin/dns-query www.baidu.com -t MX
ruby bin/dns-query baidu.com -t NS

# 指定 DNS 服务器
ruby bin/dns-query www.baidu.com -s 8.8.8.8
ruby bin/dns-query www.baidu.com -s 114.114.114.114 -t AAAA

# 用所有可用工具交叉查询
ruby bin/dns-query www.baidu.com -a

# 查看当前平台可用工具
ruby bin/dns-query --tools

# 查看全平台工具矩阵
ruby bin/dns-query --matrix

# 无颜色输出（重定向到文件时不带 ANSI 转义码）
ruby bin/dns-query www.baidu.com --no-color > result.txt
```

**退出码：**

| 退出码 | 含义 |
|--------|------|
| `0` | 查询成功 |
| `1` | 参数错误 / 当前平台无可用工具 / 查询全部失败 |

---

## 二、自动行为说明

### 1. 工具自动选择

每次查询前会做运行时检测（命令是否存在），按优先级自动选择：

- **Linux**：`dig` → `host` → `nslookup` → `drill` → `kdig` → `dog` → `getent` → `resolvectl`
- **Windows**：`dig`（若安装）→ `nslookup` → `Resolve-DnsName` → `ping -a`

可通过 `--tools` 查看当前平台实际可用工具。

### 2. IP 自动反查 PTR

目标为合法 IPv4 / IPv6 地址时，若未显式指定 `-t`，自动把记录类型切换为 `PTR`，并统一转换成反向域名（`in-addr.arpa` / `ip6.arpa`）再查询，保证 dig / drill / kdig 等工具行为一致。

```bash
ruby bin/dns-query 8.8.8.8
# 等效于: ruby bin/dns-query 8.8.8.8 -t PTR
# 实际查询: nslookup -type=PTR 8.8.8.8.in-addr.arpa
```

### 3. 记录类型与工具能力对照

各工具支持能力不同（可用 `--matrix` 查看完整矩阵），摘要如下：

| 记录类型 | dig | nslookup | host | drill | kdig | dog | Resolve-DnsName |
|----------|-----|----------|------|-------|------|-----|-----------------|
| A / AAAA / CNAME / MX / NS / PTR / SOA / TXT / SRV | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| ANY | ✅ | – | – | – | – | – | – |
| AXFR / DNSSEC / trace | ✅ | – | – | ✅ | ✅ | – | – |
| DoH / DoT | – | – | – | – | ✅ | – | – |

部分工具（如 `getent hosts`）只支持 A / AAAA，`ping -a` 仅支持 PTR。`--all` 模式下查询失败的工具会显示 `[查询失败或不可用]`，不影响其他工具结果。

---

## 三、全平台工具矩阵（--matrix）

`--matrix` 输出 10 个 DNS 工具的跨平台支持情况：

- **dig**（DNS 查询瑞士军刀）：Linux 各发行版可用；Windows 需手动安装 ISC BIND
- **nslookup**（经典工具）：全平台内置（Linux 需 bind 工具包）
- **host**：仅 Linux（bind 工具包）
- **drill**（ldns，支持 DNSSEC）：Linux 各发行版；Windows 需手动安装
- **kdig**（Knot DNS，支持 DNSSEC / DoH / DoT）：Linux 各发行版
- **dog**（Rust 彩色工具）：Linux 各发行版（部分需 cargo 安装）
- **Resolve-DnsName**（PowerShell）：仅 Windows（PS 4.0+）
- **ping -a**（反查主机名）：仅 Windows，仅支持 PTR
- **getent hosts**：仅 Linux
- **resolvectl query**：仅 Linux（systemd-resolved，Alpine 无）

**缺失工具的安装命令**（Linux）：

| 工具 | Ubuntu / Debian | Alpine | RHEL/CentOS |
|------|-----------------|--------|-------------|
| dig / host / nslookup | `sudo apt install -y dnsutils` | `sudo apk add bind-tools` | `sudo yum install -y bind-utils` |
| drill | `sudo apt install -y ldnsutils` | `sudo apk add drill` | `sudo yum install -y ldns` |
| kdig | `sudo apt install -y knot-dnsutils` | `sudo apk add knot` | `sudo yum install -y knot-utils` |

---

## 四、典型使用场景

### 1. 正查域名 A 记录

```bash
$ ruby bin/dns-query www.baidu.com
=== 使用 nslookup 查询 www.baidu.com (A) ===

非权威应答:

服务器:  UnKnown
Address:  10.140.209.68

名称:    www.a.shifen.com
Addresses:  39.156.70.46
	39.156.70.239
Aliases:  www.baidu.com
```

### 2. 反查 IP 归属域名

```bash
$ ruby bin/dns-query 8.8.8.8
=== 使用 nslookup 查询 8.8.8.8 (PTR) ===

非权威应答:

服务器:  UnKnown
Address:  10.140.209.68

8.8.8.8.in-addr.arpa	name = dns.google
```

### 3. 指定公网 DNS 服务器校验解析结果

```bash
# 对比系统 DNS 与公共 DNS 的解析差异（排查 DNS 污染/劫持）
ruby bin/dns-query www.baidu.com
ruby bin/dns-query www.baidu.com -s 8.8.8.8
ruby bin/dns-query www.baidu.com -s 114.114.114.114
```

### 4. 多工具交叉验证（--all）

```bash
$ ruby bin/dns-query www.baidu.com -a
=== 使用所有可用工具查询 www.baidu.com (A) ===

--- nslookup ---
非权威应答: ...
--- Resolve-DnsName ---
Name      : www.baidu.com
QueryType : A
...
--- ping -a ---
正在 Ping www.a.shifen.com [2409:8c00:...] 具有 32 字节的数据:
...
```

### 5. 检查邮件服务器（MX）

```bash
$ ruby bin/dns-query qq.com -t MX
=== 使用 nslookup 查询 qq.com (MX) ===
非权威应答:
qq.com	MX preference = 30, mail exchanger = mx3.qq.com
...
```

---

## 五、代码级用法

脚本同时提供可复用的模块能力（`load` 后不自动执行 CLI；文件无 `.rb` 扩展名，需用 `load` 而非 `require`）：

```ruby
load File.expand_path("bin/dns-query", __dir__)

# 查询对象：自动判断 IP / 域名，IP 自动反查 PTR
query = DnsQuery::Query.new("www.baidu.com", qtype: "A", server: "8.8.8.8")

# 默认最佳工具查询 → [stdout, exit_code]
stdout, code = query.execute

# 全部工具交叉查询 → [汇总状态, exit_code]
DnsQuery::Query.new("8.8.8.8").execute_all

# 平台与工具检测
DnsQuery::Platform.os            # => :windows / :linux
DnsQuery::Platform.wsl?          # => true / false
DnsQuery::ToolDetector.detect    # => [{key:, name:, priority:}, ...]
```

**模块结构：**

| 模块 | 职责 |
|------|------|
| `DnsQuery::Platform` | 操作系统 / 发行版 / Windows 版本 / PowerShell 版本检测 |
| `DnsQuery::ToolDetector` | 运行时检测当前平台可用工具（`which`/`where` 按平台分流） |
| `DnsQuery::Executor` | 10 个工具的调用逻辑统一入口，PTR 自动转反向域名，Windows 输出自动转 UTF-8 |
| `DnsQuery::Query` | 查询编排：最佳工具单查 / 全部工具交叉查 |
| `DnsQuery::CLI` | 参数解析、校验、分发，返回进程退出码 |

---

## 六、注意事项

- Windows 下 `ver` / PowerShell 命令输出为 GBK 编码，脚本已统一转换为 UTF-8，无需手动设置代码页
- 指定 `-s` 服务器时接受 IP 或域名；非法格式会在查询前报错
- `ping -a` 会实际发起一次 ICMP 探测，离线环境 `--all` 模式会超时，可单独用 `--tools` 确认后避免使用该工具
- 输出重定向到文件时建议加 `--no-color`，避免 ANSI 转义码进入文件