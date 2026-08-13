---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: '327b0e14-d4aa-4064-bd5a-c596fad52e74'
  PropagateID: '327b0e14-d4aa-4064-bd5a-c596fad52e74'
  ReservedCode1: 'c77ee856-ff93-4d59-bbda-652be5dd5d7b'
  ReservedCode2: 'c77ee856-ff93-4d59-bbda-652be5dd5d7b'
---

# SSH 连接客户端

版本 1.0.0

Ruby + 双引擎架构的 SSH 连接客户端。SSH 协议核心由**可插拔双引擎**提供：默认 **Rust 引擎**（`ssh_core_rs`，基于 russh），可选 **Erlang 引擎**（`ssh_core`，基于 OTP ssh）；Ruby 负责调度、终端渲染、配置与自动化，与引擎通过本地 socket 上的 JSON-RPC 2.0 通信，两端 IPC 协议完全一致，切换引擎无需改动 Ruby 代码。

---

## 目录

- [环境要求](#环境要求)
- [安装与编译](#安装与编译)
- [快速开始](#快速开始)
- [CLI 命令参考](#cli-命令参考)
  - [connect — 连接服务器](#connect--连接服务器)
  - [batch — 批量执行命令](#batch--批量执行命令)
  - [themes — 列出配色主题](#themes--列出配色主题)
  - [version — 显示版本](#version--显示版本)
- [连接参数详解](#连接参数详解)
- [配置文件](#配置文件)
  - [settings.yml](#settingsyml)
  - [sessions.yml](#sessionsyml)
  - [known\_hosts.yml](#known_hostsyml)
- [凭据加密（Vault）](#凭据加密vault)
- [终端配色主题](#终端配色主题)
- [编程 API 使用](#编程-api-使用)
  - [Client — 生命周期管理](#client--生命周期管理)
  - [Session — 会话操作](#session--会话操作)
  - [Terminal::Emulator — 终端交互](#terminalemulator--终端交互)
  - [Automation::MacroEngine — 登录宏](#automationmacroengine--登录宏)
  - [Security::HostKey — 主机密钥管理](#securityhostkey--主机密钥管理)
- [RPC 方法列表](#rpc-方法列表)
- [架构说明](#架构说明)
  - [启动流程](#启动流程)
  - [分工](#分工)
  - [关键模块在运行时的角色](#关键模块在运行时的角色)
- [项目结构](#项目结构)

---

## 环境要求

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| **Ruby** | >= 3.0 | 运行 CLI 和 Ruby 端逻辑 |
| **Rust** | rustc/cargo（稳定版） | 编译和运行默认 SSH 核心引擎（`ssh_core_rs`） |
| **Erlang/OTP** | >= 26 | 编译和运行可选 Erlang 引擎（`ssh_core`） |
| **rebar3** | 任意版本 | 编译 Erlang 引擎 |
| **OpenSSL** | 系统自带 | Vault 加密 |

> **说明**：默认引擎为 Rust（`ssh_core_rs`），仅使用 Rust 即可运行全部功能；Erlang 引擎作为可插拔备选，需要时再安装 Erlang/OTP 与 rebar3。

### Ruby 依赖

以下 gem 在运行时需要（均为标准库或常见 gem）：

- `thor` — CLI 框架
- `openssl` — Vault 加密（AES-256-GCM）
- `yaml` — 配置文件解析
- `base64` — 数据编码

---

## 安装与编译

### 1. 编译 Rust 核心引擎（默认）

```bash
cd service/ssh/ext/ssh_core_rs
cargo build --release
```

编译成功后，二进制输出到 `target/release/ssh_core_rs`（Windows 为 `ssh_core_rs.exe`）。

> **注意**：`bin/ssh_core_rs`（Linux/macOS）与 `bin/ssh_core_rs.cmd`（Windows）启动脚本会在首次启动时自动编译；也可按上述命令预先编译。

### 2. 编译 Erlang 核心引擎（可选备选）

```bash
cd service/ssh/ext/ssh_core
rebar3 compile
```

编译成功后，beam 文件输出到 `_build/default/lib/ssh_core/ebin/`。

> **注意**：jsx 依赖已内嵌为本地源码（`local_deps/jsx/src/src/`），通过 `src_dirs` 直接编译，无需从 hex.pm 拉取。

### 3. 验证引擎可启动

**Rust 引擎：**

```bash
cd service/ssh/ext/ssh_core_rs
bin/ssh_core_rs   # Linux/macOS；Windows 为 bin\ssh_core_rs.cmd
```

**Erlang 引擎：**

**Linux/macOS:**

```bash
cd service/ssh/ext/ssh_core
erl -noshell -noinput -pa _build/default/lib/ssh_core/ebin \
  -eval "application:ensure_all_started(ssh_core), io:format(\"ok~n\"), timer:sleep(1000), halt()."
```

**Windows:**

```cmd
cd service\ssh\ext\ssh_core
bin\ssh_core.cmd
```

引擎启动后会生成端点文件（`%TEMP%\ssh_core_<username>.endpoint`），包含 IPC 监听地址和认证 Token。

### 4. 验证 Ruby 端

```bash
cd service/ssh
ruby bin/ssh-client version
# 输出: 1.0.0

ruby bin/ssh-client themes
# 输出所有内置主题名称
```

---

## 快速开始

### 连接到服务器

```bash
# 密钥认证
ruby bin/ssh-client connect 10.0.0.1 -u admin -i ~/.ssh/id_ed25519

# 密码认证（交互输入）
ruby bin/ssh-client connect 10.0.0.1 -u admin --password

# 跳板机连接（语法示例；CLI 默认 Rust 引擎不支持 jumps，见下方注意）
ruby bin/ssh-client connect 192.168.1.100 -u deploy -J jumpuser@10.0.0.1:22

# 指定端口和配色主题
ruby bin/ssh-client connect 10.0.0.1 -u admin -p 2222 --theme dracula
```

连接成功后进入交互模式，输入命令回车发送，输入 `exit` 或 `quit` 断开。

> **注意**：`-J` 跳板机参数依赖引擎对 `jumps` 的支持，目前仅 **Erlang 引擎**实现，而 CLI 默认使用 Rust 引擎，且 CLI 层暂未提供后端切换选项，因此 CLI 的 `-J` 在默认配置下不会生效；如需使用跳板机，请通过编程 API 创建 `Client.new(backend: :erlang)` 并传入 `jumps` 参数。

### 编程方式使用

```ruby
require_relative "service/ssh/lib/network_infra_utility/ssh"

client = NetworkInfraUtility::SSH::Client.new
client.start_engine

session = client.connect(
  host: "10.0.0.1",
  port: 22,
  user: "admin",
  key_path: "/home/user/.ssh/id_ed25519"
)

terminal = session.open_terminal
terminal.puts("show version")
# ... 读取输出 ...

session.disconnect
client.stop
```

---

## CLI 命令参考

CLI 入口为 `bin/ssh-client`，基于 [Thor](https://github.com/rails/thor) 框架。

### connect — 连接服务器

```
ssh-client connect HOST [options]
```

连接到指定 SSH 服务器并进入交互终端。

| 选项 | 简写 | 类型 | 默认值 | 说明 |
|------|------|------|--------|------|
| `--user` | `-u` | String | **必填** | SSH 用户名 |
| `--port` | `-p` | Integer | 22 | SSH 端口 |
| `--key` | `-i` | String | — | 私钥文件路径 |
| `--jump` | `-J` | String | — | 跳板机，格式 `user@host:port`，多个用逗号分隔（**仅 Erlang 引擎支持**，CLI 默认 Rust 引擎下不生效） |
| `--name` | — | String | — | 会话名称 |
| `--password` | — | Boolean | false | 使用密码认证（交互式输入，不回显） |
| `--theme` | — | String | default | 终端配色主题，见[主题列表](#终端配色主题) |

**示例：**

```bash
# 基本连接
ssh-client connect 10.0.0.1 -u admin

# 密钥 + 跳板机 + 自定义端口（-J 仅 Erlang 引擎支持，CLI 默认 Rust 引擎下不生效）
ssh-client connect 192.168.1.100 -u deploy -p 2222 -i ~/.ssh/deploy_key -J jump@10.0.0.1:22 --theme nord

# 密码认证
ssh-client connect 10.0.0.1 -u admin --password
# 将提示: Password: （输入不回显）
```

**交互模式：** 连接后进入读-发-收循环。输入命令回车发送到远端，输入 `exit` 或 `quit` 断开连接，`Ctrl+C` 退出。

### batch — 批量执行命令

```
ssh-client batch FILE [options]
```

从 YAML 文件加载多个会话定义，并行或串行在所有会话上执行同一条命令。

| 选项 | 简写 | 类型 | 默认值 | 说明 |
|------|------|------|--------|------|
| `--command` | `-c` | String | **必填** | 要执行的命令 |
| `--serial` | — | Boolean | false | 串行执行（默认并行） |

**会话文件格式（YAML）：**

```yaml
# 单条会话（Hash）
host: 10.0.0.1
user: admin
port: 22
key_path: /home/user/.ssh/id_ed25519

# 多条会话（Array）
- host: 10.0.0.1
  user: admin
  key_path: /home/user/.ssh/id_ed25519
- host: 10.0.0.2
  user: root
  password: secret
- host: 10.0.0.3
  user: deploy
  port: 2222
  key_path: /home/user/.ssh/deploy_key
```

**示例：**

```bash
# 并行执行（默认）
ssh-client batch servers.yml -c "uptime"

# 串行执行
ssh-client batch servers.yml -c "show version" --serial
```

### themes — 列出配色主题

```
ssh-client themes
```

列出所有内置配色主题名称。

```bash
$ ssh-client themes
  default
  solarized-dark
  solarized-light
  dracula
  monokai
  nord
  gruvbox-dark
  one-dark
  tokyo-night
  catppuccin-mocha
  github-dark
```

### version — 显示版本

```
ssh-client version
```

输出版本号。

---

## 连接参数详解

连接参数（`spec`）是一个 Hash，以下字段被引擎识别：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `host` | String | 是 | 目标主机 IP 或域名 |
| `user` | String | 是 | SSH 用户名 |
| `port` | Integer | 否 | SSH 端口，默认 22 |
| `name` | String | 否 | 会话显示名称 |
| `key_path` | String | 否 | 私钥文件路径 |
| `key_dir` | String | 否 | 密钥搜索目录（默认 `.`，即引擎工作目录） |
| `auth` | Hash | 否 | 认证配置，见下表 |
| `jumps` | Array | 否 | 跳板机链（仅 Erlang 引擎），见下表 |
| `terminal` | Hash | 否 | 终端配置，如 `{ theme: "dracula" }` |
| `proxy` | Hash | 否 | 代理配置（仅 Erlang 引擎，SOCKS5 / HTTP CONNECT） |
| `connect_timeout_ms` | Integer | 否 | 连接超时（毫秒），默认 60000 |
| `inactivity_timeout_s` | Integer | 否 | 空闲断开时间（秒），默认不因空闲断开（由 keepalive 管理） |
| `algorithms` | Hash | 否 | 自定义算法列表，如 `{ kex: [...], cipher: [...] }` |

> **引擎支持差异**：`jumps`（跳板机链）与 `proxy`（代理）目前仅 **Erlang 引擎**实现（OTP ssh 原生支持 + 自研 SOCKS5/HTTP CONNECT 握手）；**Rust 引擎暂未实现**，传入会被忽略。若需使用跳板机/代理，请用 `Client.new(backend: :erlang)` 切换后端。

### auth 字段

| 认证类型 | auth 值 | 说明 |
|---------|---------|------|
| 密钥认证 | `{ type: "publickey" }` | 私钥路径通过 `key_path` 指定 |
| 密码认证 | `{ type: "password", password: "..." }` | 密码明文或 Vault 引用 |
| 键盘交互 | `{ type: "keyboard_interactive", responses: ["..."] }` | 交互式认证 |

密码字段支持 [Vault 引用](#凭据加密vault)，格式为 `~vault:<key>`。连接前由 Ruby 端自动解密替换。

### jumps 字段

跳板机链，数组形式，连接顺序从前到后（**仅 Erlang 引擎**）：

```ruby
jumps: [
  { user: "jump", host: "10.0.0.1", port: 22 },
  { user: "bastion", host: "192.168.1.1", port: 2222 }
]
```

### proxy 字段（仅 Erlang 引擎）

SOCKS5（默认）或 HTTP CONNECT 代理：

```ruby
proxy: {
  type: "socks5",        # 或 "http"，默认 "socks5"
  host: "127.0.0.1",
  port: 1080,
  username: "proxy_user",   # 可选
  password: "proxy_pass"    # 可选
}
```

---

## 配置文件

所有配置文件默认存放在 `~/.network-infra-utility/` 目录下。

### settings.yml

全局设置文件。

```yaml
# 主密码（用于 Vault 加解密，请妥善保管）
master_password: "your-master-password"

# 日志目录（不设则默认 ~/.network-infra-utility/logs/）
log_dir: ~/.network-infra-utility/logs

# 配置目录
config_dir: ~/.network-infra-utility

# 默认终端类型
default_terminal: xterm-256color

# 默认回滚行数
default_scrollback: 10000

# 默认心跳间隔（秒）
default_keepalive_interval: 30

# 默认配色主题
default_theme: dark
```

### sessions.yml

会话列表持久化文件。由 `Config::Store` 管理，支持原子写入（先写 `.tmp` 再 rename）。

```yaml
version: 1
groups:
  - id: prod
    name: 生产环境
    parent: ~
    collapsed: false
sessions:
  - id: sess_001
    name: web-server-1
    group: prod
    host: 10.0.0.1
    port: 22
    user: admin
    tags: [web, production]
    auth:
      type: publickey
    terminal:
      theme: dracula
    macro:
      enabled: true
      steps:
        - action: "enable\n"
          wait_pattern: "#"
          delay: 0.5
          on_fail: continue
        - action: "terminal monitor\n"
          wait_pattern: "#"
          delay: 0.3
          on_fail: abort
```

**会话字段定义（Schema v1）：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `host` | String | 是 | 主机地址 |
| `user` | String | 是 | 用户名 |
| `port` | Integer | 否 | 端口 |
| `name` | String | 否 | 会话名称 |
| `group` | String | 否 | 所属分组 ID |
| `tags` | Array | 否 | 标签列表 |
| `auth` | Hash | 否 | 认证配置 |
| `terminal` | Hash | 否 | 终端配置 |
| `jumps` | Array | 否 | 跳板机链 |
| `port_forwards` | Array | 否 | 端口转发规则 |
| `macro` | Hash | 否 | 登录宏配置 |
| `keepalive` | Hash | 否 | 心跳配置 |
| `auto_reconnect` | Hash | 否 | 自动重连配置 |

### known_hosts.yml

主机密钥指纹存储。首次连接时提示用户确认，确认后自动保存。

```yaml
"10.0.0.1:22":
  :fingerprint: "SHA256:abc123..."
  :added_at: "2026-01-15T10:30:00+08:00"
"192.168.1.100:2222":
  :fingerprint: "SHA256:def456..."
  :added_at: "2026-01-16T14:00:00+08:00"
```

**裁决逻辑：**

| 场景 | 行为 |
|------|------|
| 首次连接 | 提示用户确认（`y/N`），确认后保存指纹 |
| 指纹匹配 | 自动通过，无交互 |
| 指纹变更 | 拒绝连接并告警，需手动删除条目后重连 |

---

## 凭据加密（Vault）

Vault 使用 **AES-256-GCM** 加密算法保护敏感凭据（如 SSH 密码），加密参数：

| 参数 | 值 |
|------|-----|
| 算法 | AES-256-GCM |
| KDF | PBKDF2-HMAC-SHA256 |
| 迭代次数 | 100,000 |
| Salt 长度 | 32 字节（每条独立随机） |
| Key 长度 | 32 字节 |
| Nonce 长度 | 12 字节 |

### 加密存储

```ruby
client = NetworkInfraUtility::SSH::Client.new
# client.vault 是 Vault 实例

# 存储密码
client.vault.store("web_server_pass", "MySecret123!")

# 在连接参数中引用
session = client.connect(
  host: "10.0.0.1",
  user: "admin",
  auth: { type: "password", password: "~vault:web_server_pass" }
)
# Vault 会自动将 ~vault:web_server_pass 解密为明文密码
```

### vault.yml 格式

```yaml
web_server_pass:
  :salt: <Base64>
  :nonce: <Base64>
  :tag: <Base64>
  :data: <Base64>
```

文件权限：Linux 下 `chmod 600`，Windows 下通过 `icacls` 限制为当前用户。

---

## 终端配色主题

内置 11 套配色方案：

| 主题名 | 风格 | 背景色 |
|--------|------|--------|
| `default` | VS Code Dark | #1e1e1e |
| `solarized-dark` | Solarized Dark | #002b36 |
| `solarized-light` | Solarized Light | #fdf6e3 |
| `dracula` | Dracula | #282a36 |
| `monokai` | Monokai | #272822 |
| `nord` | Nord | #2e3440 |
| `gruvbox-dark` | Gruvbox Dark | #282828 |
| `one-dark` | One Dark | #282c34 |
| `tokyo-night` | Tokyo Night | #1a1b26 |
| `catppuccin-mocha` | Catppuccin Mocha | #1e1e2e |
| `github-dark` | GitHub Dark | #0d1117 |

每个主题包含：背景色 `bg`、前景色 `fg`、光标色 `cursor`、16 色调色板 `palette`。

### 自定义主题

在 `~/.network-infra-utility/themes/<name>.yml` 创建自定义主题：

```yaml
bg: "#1a1b26"
fg: "#a9b1d6"
cursor: "#c0caf5"
palette:
  - "#15161e"  # 0  黑
  - "#f7768e"  # 1  红
  - "#9ece6a"  # 2  绿
  - "#e0af68"  # 3  黄
  - "#7aa2f7"  # 4  蓝
  - "#bb9af7"  # 5  洋红
  - "#7dcfff"  # 6  青
  - "#a9b1d6"  # 7  白
  - "#414868"  # 8  亮黑
  - "#f7768e"  # 9  亮红
  - "#9ece6a"  # 10 亮绿
  - "#e0af68"  # 11 亮黄
  - "#7aa2f7"  # 12 亮蓝
  - "#bb9af7"  # 13 亮洋红
  - "#7dcfff"  # 14 亮青
  - "#c0caf5"  # 15 亮白
```

---

## 编程 API 使用

### Client — 生命周期管理

`SSH::Client` 是主入口，管理引擎生命周期和子系统协调。默认后端为 **Rust**（`ssh_core_rs`），可指定 `backend: :erlang` 切换到 Erlang 引擎。

```ruby
client = NetworkInfraUtility::SSH::Client.new                          # 默认 Rust 引擎
client_erl = NetworkInfraUtility::SSH::Client.new(backend: :erlang)    # 切换 Erlang 引擎
```

| 方法 | 说明 |
|------|------|
| `start_engine` | 启动引擎子进程（按 `backend` 选择 Rust/Erlang），建立 IPC 连接，注册反向 RPC |
| `connect(spec)` | 发起 SSH 连接，返回 `Session::Session` 对象 |
| `stop` | 停止引擎，断开所有连接，清理资源 |
| `started?` | 引擎是否已启动 |
| `ipc` | `IPC::Router` 实例，用于底层 RPC 调用 |
| `sessions` | `Session::Manager` 实例，管理所有会话 |
| `vault` | `Security::Vault` 实例，凭据加密 |
| `host_key` | `Security::HostKey` 实例，主机密钥管理 |
| `settings` | `Config::Settings` 实例，全局配置 |
| `backend` | 当前引擎后端（`:rust` 或 `:erlang`） |
| `on_engine_exit(&block)` | 设置引擎异常退出回调（`:crashed` / `:disconnected`） |

**基本用法：**

```ruby
client = NetworkInfraUtility::SSH::Client.new
client.start_engine

begin
  # 终端主题通过 spec[:terminal][:theme] 传递（也可不传，用默认主题）
  session = client.connect(
    host: "10.0.0.1", user: "admin",
    key_path: "~/.ssh/id_ed25519",
    terminal: { theme: "dracula" }
  )
  terminal = session.open_terminal
  
  terminal.puts("show version")
  # ... 读取终端输出 ...
  
  session.disconnect
ensure
  client.stop
end
```

### Session — 会话操作

`SSH::Session::Session` 封装单个 SSH 会话。

| 方法 | 说明 |
|------|------|
| `open_terminal(term_type:, cols:, rows:)` | 打开终端通道，返回 `Terminal::Emulator` |
| `close_terminal` | 关闭终端通道 |
| `add_port_forward(type, local_port, remote_host, remote_port)` | 添加端口转发，返回 `rule_id` |
| `remove_port_forward(rule_id)` | 移除端口转发规则 |
| `disconnect` | 断开 SSH 连接 |
| `connected?` | 是否已连接 |
| `on_closed(reason)` | 连接被远端关闭时的回调 |

**属性：** `session_id`, `conn_id`, `spec`, `name`, `host`, `port`, `user`, `fingerprint`, `terminal`, `file_manager`, `port_forwards`, `tags`, `group`, `status`

**端口转发示例：**

```ruby
session = client.connect(host: "10.0.0.1", user: "admin", key_path: "~/.ssh/id_ed25519")

# 本地端口转发：将本地 8080 转发到远程 80
rule_id = session.add_port_forward(:local, 8080, "127.0.0.1", 80)

# ... 使用本地 8080 端口 ...

# 移除转发
session.remove_port_forward(rule_id)
```

### Terminal::Emulator — 终端交互

`SSH::Terminal::Emulator` 提供终端模拟和数据收发。

| 方法 | 说明 |
|------|------|
| `send(data)` | 发送原始数据到 SSH 通道 |
| `puts(text)` | 发送一行（自动追加 `\r`） |
| `feed(data)` | 输入从 SSH 收到的原始字节（内部解析 ANSI 转义） |
| `resize(cols, rows)` | 变更窗口大小 |
| `theme=` | 设置配色主题（名称） |
| `search(pattern)` | 搜索回滚缓冲区内容 |
| `export(path)` | 导出回滚缓冲区为文本 |
| `start_logging(path, max_size:, rotate:)` | 启动会话日志轮转 |
| `stop_logging` | 停止日志记录 |

**属性：** `conn_id`, `channel_id`, `screen`, `buffer`, `theme`, `logger`

**会话日志示例：**

```ruby
terminal = session.open_terminal
terminal.start_logging("session_20260115.log", max_size: 100 * 1024 * 1024, rotate: 10)

# ... 交互过程中自动记录 ...
# 文件达到 max_size 时自动轮转，保留最近 rotate 个文件

terminal.stop_logging
```

### Automation::MacroEngine — 登录宏

连接后自动执行预设命令序列，支持等待匹配和失败处理。最多 50 步。

```ruby
session = client.connect(host: "10.0.0.1", user: "admin", key_path: "~/.ssh/id_ed25519")
terminal = session.open_terminal

macro = NetworkInfraUtility::SSH::Automation::MacroEngine.new(session)

# 添加步骤
macro.add_step(action: "enable\n", wait_pattern: "Password:", delay: 0.5)
macro.add_step(action: "admin123\n", wait_pattern: "#", on_fail: :abort)
macro.add_step(action: "terminal monitor\n", wait_pattern: "#", delay: 0.3)

# 设置失败时的交互回调（on_fail: :ask 时触发）
macro.on_ask do |step, index|
  puts "Step #{index} timeout: #{step.action}"
  puts "Continue? (y/n)"
  STDIN.gets.chomp =~ /^y/i ? :continue : :abort
end

# 执行宏
result = macro.run do |step, index, total|
  puts "[#{index}/#{total}] #{step.action.strip}"
end
# result => :completed 或 : aborted
```

**Step 参数：**

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `action` | String | — | 要发送的命令 |
| `wait_pattern` | String/Regexp/nil | nil | 等待匹配的输出，nil 不等待 |
| `delay` | Float | 0 | 发送前延迟（秒） |
| `on_fail` | Symbol | :continue | 超时行为：`:continue` / `:abort` / `:ask` |

**从配置文件加载（sessions.yml 中的 macro 字段）：**

```ruby
macro.load_from_config({
  enabled: true,
  steps: [
    { action: "enable\n", wait_pattern: "Password:", delay: 0.5 },
    { action: "admin123\n", wait_pattern: "#", on_fail: "abort" }
  ]
})
macro.run
```

### Security::HostKey — 主机密钥管理

```ruby
host_key = client.host_key

# 手动添加信任条目
host_key.add("10.0.0.1", 22, "SHA256:abc123...")

# 查询
entry = host_key.get("10.0.0.1", 22)
# => { fingerprint: "SHA256:abc123...", added_at: "2026-01-15T..." }

# 删除
host_key.remove("10.0.0.1", 22)

# 列出全部
host_key.list.each do |entry|
  puts "#{entry[:host]}:#{entry[:port]} - #{entry[:fingerprint]}"
end
```

**自定义交互回调：**

```ruby
host_key.on_prompt do |host, port, fingerprint|
  puts "首次连接 #{host}:#{port}"
  puts "指纹: #{fingerprint}"
  print "信任? (y/N) "
  STDIN.gets.chomp =~ /^y/i ? :accept : :reject
end

host_key.on_key_changed do |host, port, old_fp, new_fp|
  warn "警告: #{host}:#{port} 主机密钥变更!"
  warn "  旧: #{old_fp}"
  warn "  新: #{new_fp}"
end
```

---

## RPC 方法列表

Ruby 端通过 `IPC::Router` 向引擎发起 JSON-RPC 2.0 请求。Rust 与 Erlang 引擎实现同一套协议，方法列表完全一致。以下是全部已注册的 RPC 方法：

### 连接管理

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `conn.connect` | 连接 spec（host, user, port, auth, jumps 等） | `{ conn_id, fingerprint }` | 发起 SSH 连接 |
| `conn.disconnect` | `{ id }` | `{ ok: true }` | 断开指定连接 |
| `conn.list` | `{}` | 连接列表 | 列出所有活动连接 |
| `conn.reconnect` | `{ id }` | — | 重连指定连接 |

### 通道管理

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `channel.open` | `{ conn_id, type, term, cols, rows }` | `{ channel_id }` | 打开通道（shell/exec） |
| `channel.send` | `{ id, data }` | — | 发送数据（Base64 编码） |
| `channel.close` | `{ id }` | — | 关闭通道 |
| `channel.window_change` | `{ id, cols, rows }` | — | 变更窗口大小 |

### SFTP 文件传输

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `sftp.open` | `{ conn_id }` | `{ sftp_id }` | 打开 SFTP 会话 |
| `sftp.list_dir` | `{ sftp_id, path }` | 目录列表 | 列出远程目录 |
| `sftp.download` | `{ sftp_id, remote, local }` | — | 下载文件 |
| `sftp.upload` | `{ sftp_id, local, remote }` | — | 上传文件 |
| `sftp.mkdir` | `{ sftp_id, path }` | — | 创建远程目录 |
| `sftp.remove` | `{ sftp_id, path }` | — | 删除远程文件 |
| `sftp.stat` | `{ sftp_id, path }` | 文件信息 | 查询文件属性 |

### 端口转发

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `portfwd.add` | `{ conn_id, type, local_port, remote_host, remote_port }` | `{ rule_id }` | 添加转发规则 |
| `portfwd.remove` | `{ conn_id, rule_id }` | — | 移除转发规则 |
| `portfwd.list` | `{ conn_id }` | 规则列表 | 列出转发规则 |

### 引擎管理

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `engine.ping` | `{}` | `{ ok: true }` | 心跳检测 |
| `engine.stats` | `{}` | 运行时统计 | 引擎统计信息 |
| `engine.shutdown` | `{}` | — | 关闭引擎 |
| `bye` | `{}` | — | 断开 IPC 连接 |

### 保活管理

| 方法 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `keepalive.set_interval` | `{ interval_ms }` | — | 设置心跳间隔（设为 0 禁用） |
| `keepalive.get_interval` | `{}` | 当前间隔 | 查询心跳间隔 |
| `keepalive.get_status` | `{}` | 连接保活状态 | 查询各连接保活状态 |

### 反向 RPC（引擎 → Ruby）

| 方法 | 触发时机 | 说明 |
|------|---------|------|
| `hostkey.resolve` | 引擎连接前校验主机密钥 | Ruby 返回 `accept` / `reject` / `once` |

### 推送事件（引擎 → Ruby，notification）

| 方法 | 说明 |
|------|------|
| `channel.data` | 通道收到远端数据 |
| `channel.eof` | 通道收到 EOF |
| `channel.extended_data` | 通道收到扩展数据（如 stderr） |
| `conn.ready` | 连接已就绪 |
| `conn.failed` | 连接失败 |
| `conn.closed` | 连接被远端关闭 |

---

## 架构说明

### 启动流程

```
用户执行                          Ruby 进程                         引擎进程（Rust / Erlang）
────────                      ──────────                       ──────────
ssh-client connect 10.0.0.1
  -u admin
       │                           │                                │
       ▼                           ▼                                │
   ┌──────────┐            ┌──────────────┐                        │
   │ Thor CLI │──调用──▶   │ SSH::Client  │                        │
   │ 参数解析  │            │  .new        │                        │
   └──────────┘            └──────┬───────┘                        │
                                   │                                │
                          start_engine()                           │
                                   │                                │
                          ┌────────┴────────┐                      │
                          │ Process.spawn   │────拉起子进程────────▶│ ssh_core_rs（Rust）
                          │ 按 backend 选择  │                     │ 或 ssh_core（Erlang）
                          │ 引擎二进制      │                      │ 写入端点文件
                          └────────┬────────┘                      │
                                   │                                │
                          读取端点文件，建立 IPC 连接（JSON-RPC）    │
                                   │◀════════socket════════════════▶│
                                   │                                │
                          vault.resolve_credentials(密码解密)       │
                                   │                                │
                          IPC call "conn.connect" ────────────────▶│ ssh:connect() / russh
                                   │                                │ 建立SSH连接
                                   │◀────返回 conn_id ──────────────│
                                   │                                │
                          session.open_terminal                     │
                          IPC call "channel.open" ───────────────▶│ 打开shell通道
                                   │◀────返回 channel_id ───────────│
                                   │                                │
                          进入交互循环                               │
                          ┌──────────────┐                         │
                          │ 用户输入命令  │──IPC──▶ channel.send ──▶│ 发往远程服务器
                          │ 终端输出显示  │◀─IPC─── channel.data ───│ 收到服务器响应
                          └──────────────┘                         │
                                   │                                │
                          输入 exit → 关闭连接 → 停止引擎进程         │
```

### 分工

| | Ruby | Rust / Erlang 引擎 |
|---|---|---|
| **职责** | 调度、配置、终端渲染、加密 | SSH 协议、连接管理、通道复用 |
| **进程** | 主进程 | 子进程（引擎与 Ruby 隔离，崩溃不影响 Ruby） |
| **通信** | 发 JSON-RPC 请求，收推送事件 | 响应请求，推送 channel.data 等事件 |

### 关键模块在运行时的角色

- **`bin/ssh-client`** — 入口，Thor 解析参数后调 `Client`
- **`SSH::Client`** — 总指挥，按 `backend` 拉起对应引擎、建立 IPC、组合各子系统
- **`IPC::Router`** — 管所有 JSON-RPC 往来，含订阅/反向 RPC
- **`Security::Vault`** — 连接前把 `~vault:xxx` 凭据引用解密成明文
- **`Security::HostKey`** — 引擎连接时反问 Ruby"这主机密钥信不信"（双向 RPC）
- **`Terminal::Emulator`** — 收到远端字节后输入给 `AnsiParser`，解析 ANSI 转义、驱动 `Screen` 渲染

简单说就是：**Ruby 是大脑（管配置/界面/自动化），引擎是手脚（Rust/Erlang 二选一，管 SSH 协议执行），两者通过本地 socket 上的 JSON-RPC 协作。Rust 引擎默认启用；Erlang 引擎与 Rust 引擎 IPC 协议完全一致，`Client.new(backend: :erlang)` 一行切换，Ruby 其余代码零改动。**

---

## 项目结构

```
service/ssh/
├── bin/                    # CLI 入口
│   └── ssh-client          # Thor 命令行脚本
├── design/                 # 设计文档
│   ├── SSH连接客户端功能需求文档.md
│   ├── SSH连接客户端软件设计文档.md      # HLD
│   └── SSH连接客户端详细设计文档.md      # LLD
├── ext/ssh_core_rs/        # Rust 核心引擎（默认）
│   ├── src/                #   Rust 源码（conn/channel/sftp/portfwd/keepalive 等）
│   ├── bin/                #   启动脚本（ssh_core_rs / ssh_core_rs.cmd）
│   ├── Cargo.toml
│   └── target/             #   编译输出
├── ext/ssh_core/           # Erlang 核心引擎（可选备选）
│   ├── src/                #   Erlang 源码（18 模块）
│   ├── local_deps/jsx/     #   jsx JSON 库（本地源码）
│   ├── config/             #   sys.config / vm.args
│   ├── bin/                #   启动脚本（ssh_core / ssh_core.cmd）
│   └── test/               #   Common Test 套件（占位）
├── lib/network_infra_utility/
│   └── ssh.rb              # Ruby 统一入口
│   └── ssh/                # Ruby 源码
│       ├── client.rb       #   主入口，生命周期管理（backend 选择）
│       ├── version.rb
│       ├── ipc/            #   JSON-RPC 通信层
│       ├── session/        #   会话管理
│       ├── terminal/       #   终端模拟（ANSI 解析 + 屏幕渲染）
│       ├── security/       #   凭据加密（Vault）+ 主机密钥校验
│       ├── automation/     #   登录宏引擎
│       └── config/         #   全局设置
└── spec/                   # RSpec 测试（占位）
```