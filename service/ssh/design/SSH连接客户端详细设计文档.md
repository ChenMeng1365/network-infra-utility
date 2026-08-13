
# SSH 连接客户端详细设计文档（LLD）

> **文档版本**：v1.0
> **编写日期**：2026-08-02
> **文档状态**：初稿
> **对应文档**：SSH连接客户端功能需求文档 v1.0、SSH连接客户端软件设计文档 v1.0
> **定位**：本文件是 HLD（软件设计文档）的细化与修正，目标是对每个模块给出可落地的接口契约、状态机、数据结构、并发约定与"完成判定标准"，使开发人员据此即可编码。

---

## 目录

- [1 文档定位与 HLD 的关系](#1-文档定位与-hld-的关系)
- [2 HLD 勘误与修正项](#2-hld-勘误与修正项)
- [3 模块全景与依赖图](#3-模块全景与依赖图)
- [4 全局不变量与 ID 规则](#4-全局不变量与-id-规则)
- [5 IPC 协议详细规范（v2）](#5-ipc-协议详细规范v2)
- [6 Erlang 核心引擎详细设计](#6-erlang-核心引擎详细设计)
- [7 Ruby 调度层详细设计](#7-ruby-调度层详细设计)
- [8 错误处理与级联策略](#8-错误处理与级联策略)
- [9 配置体系与数据一致性](#9-配置体系与数据一致性)
- [10 可观测性设计](#10-可观测性设计)
- [11 模块完成判定标准（Definition of Done）](#11-模块完成判定标准definition-of-done)
- [12 测试矩阵](#12-测试矩阵)

---

## 1 文档定位与 HLD 的关系

HLD 已确定：Erlang/OTP `ssh` 应用做协议核心、Ruby 做调度与终端、二者经 JSON-RPC 2.0 over Unix Socket/TCP 通信。本文件不推翻上述决策，只做三件事：

1. **修正**：HLD 中引用了 OTP ssh 应用中并不存在的 API，逐一替换为真实 API。
2. **细化**：HLD 中只给目录占位的模块，补全接口签名、状态、并发模型。
3. **补缺**：补 HLD 未覆盖的 IPC 生命周期/流控、全局不变量、错误级联、配置 schema、可观测性、完成判定。

本文件只覆盖 V1.0（P0）范围；V2.0/V3.0 模块列出接口预留位但不展开实现细节。

---

## 2 HLD 勘误与修正项

| # | HLD 位置 | 问题 | 修正 |
|---|---------|------|------|
| E1 | 4.2.4 `ssh:auth_user/3` | OTP ssh 无此函数，认证在 `ssh:connect` 选项中配置 | 改为在 `ssh:connect/2,3` 的 options 中传 `{user, User}`、`{password, Pwd}`、`{key_cb, ...}`、`{auth_method, ...}`，连接成功即认证完成 |
| E2 | 4.2.4 `ssh:load_host_key/2` | 无此函数 | 用 `public_key:read_keyfile/1,2` 或自定义 `key_cb` 回调返回 `{ok, Key, Algorithm}` |
| E3 | 4.2.2 `ssh:connect_via/2` | 无此函数，无法直接在已有通道上叠 SSH | 跳板改用 OpenSSH 语义：第一跳 `ssh:connect`；后续每跳在前一跳内开 `direct_tcpip` 通道拿到底层 socket，再对该 socket 跑 `ssh:connect` 的 connect 阶段（需自定义 transport，见 6.7） |
| E4 | 4.2.6 `ssh:tcpip_tunnel/...` | OTP ssh 无 `tcpip_tunnel` | 本地转发用 `ssh_connection:direct_tcpip` + 自建本地 listener；远程转发用 `ssh_connection:tcpip_forward` 注册远端端口 |
| E5 | 4.2.3 `gen_fsm` | OTP 26 起 `gen_fsm` 已弃用 | 全部改用 `gen_statem`（state_functions 模式） |
| E6 | 4.2.2 `tunneled_connect` | 直接 `ssh:connect` 无法复用底层通道 | 跳板链用 `ssh` 应用的 `connection callback` 或直接对裸 socket 执行握手；V1.0 简化为：每跳用 `ssh:connect`，跳板链通过 `proxy` 选项 + 自定义 `{sock_fun, Fun}` 实现 |
| E7 | 2.2 known_hosts 归属 | HLD 同时说 Erlang ETS 又说 Ruby `known_hosts.yml`，矛盾 | 统一：**Erlang 负责校验**（otp ssh 的 `key_cb`），**持久化由 Ruby 经 IPC 提供**；Erlang 不落盘 known_hosts |
| E8 | 5.2.2 `on_event` 永久回调 | 回调不清理，会内存泄漏且通道关闭后仍收到推送 | 引入 `channel_id` 维度的订阅注册/注销，`channel.close` 时清理 |
| E9 | 6 `channel.data` 无背压 | 高频小包冲爆 Ruby | Erlang 侧 coalesce + watermark；Ruby 侧批量消费，见 5.4 |
| E10 | 4.5 `conn_pool_sup` intensity=100 | 单连接崩溃即重启冲击 | `temporary`+simple_one_for_one 下 intensity 不影响单连接，但需把 ipc_gateway 与 keepalive 独立到不同 supervisor，避免连带 |

---

## 3 模块全景与依赖图

### 3.1 模块清单与职责边界

#### Erlang 侧（V1.0 必交付）

| 模块 | 类型 | 职责 | 不负责 |
|------|------|------|--------|
| `ssh_core_sup` | supervisor(顶层) | 拉起并监督三个子 supervisor/workers | 业务逻辑 |
| `ssh_infra_sup` | supervisor | 监督 ipc_gateway、keepalive_mgr、known_hosts_proxy | 连接进程 |
| `ssh_conn_sup` | supervisor(simple_one_for_one) | 动态拉起 conn_worker | 连接内部逻辑 |
| `ssh_sftp_sup` | supervisor(simple_one_for_one) | 动态拉起 sftp_session | SFTP 协议细节 |
| `ssh_ipc_gateway` | gen_server | 监听 IPC、路由 RPC、校验 token、coalesce 推送 | SSH 协议 |
| `ssh_ipc_proto` | module | JSON-RPC 编解码、分帧 | 网络 |
| `ssh_ipc_coalesce` | gen_server | 高频推送合并、背压 watermark | 路由 |
| `ssh_conn_worker` | gen_statem | 单条 SSH 连接生命周期 + 通道管理 | 多连接编排 |
| `ssh_channel_stm` | gen_statem | 单通道(shell/exec/sftp子系统)状态机 | 跨通道 |
| `ssh_auth_engine` | module | 认证链回退、key_cb 实现 | 凭据存储 |
| `ssh_jump_chain` | module | 跳板链顺序构建 + 自定义 sock_fun | 认证细节 |
| `ssh_port_fwd` | gen_server | 本地/远程/动态端口转发规则与 listener | 业务路由 |
| `ssh_sftp_session` | gen_server | 单 SFTP 会话操作 | 通道复用 |
| `ssh_keepalive_mgr` | gen_server | 周期巡检、连续失败计数、触发重连 | 重连执行 |
| `ssh_known_hosts_proxy` | gen_server | 经 IPC 向 Ruby 查询主机密钥裁决 | 落盘 |

#### Ruby 侧（V1.0 必交付）

| 模块 | 类型 | 职责 | 不负责 |
|------|------|------|--------|
| `SSH::Client` | class | 生命周期、引擎拉起、模块组合 | 协议细节 |
| `IPC::Transport` | class | socket 读写、分帧、重连 | 业务路由 |
| `IPC::Router` | class | 请求-响应配对、推送分发、订阅注册/注销 | socket |
| `IPC::Coalesce` | class(push消费) | 批量消费 channel.data，批量喂终端 | 协议 |
| `Session::Manager` | class | 会话集合、连接编排、树形分组、历史 | 单会话内部 |
| `Session::Session` | class | 单会话聚合终端/文件/转发 | 跨会话 |
| `Session::Tree` | class | 分组树(CRUD+折叠) | 持久化 |
| `Session::History` | class | 最近列表、置顶 | — |
| `Terminal::Emulator` | class | ANSI/xterm 转义解析、屏幕状态 | 渲染 I/O |
| `Terminal::Screen` | class | 屏幕行/光标/滚动区 | 转义语义 |
| `Terminal::Buffer` | class | 回滚区 + 搜索索引 | 渲染 |
| `Terminal::Theme` | class | 配色加载/查询 | — |
| `Terminal::Logger` | class | 会话日志、轮转 | 渲染 |
| `Security::Vault` | class | AES-256-GCM 凭据加解密 | 凭据引用解析 |
| `Security::HostKey` | class | known_hosts 落盘 + 裁决 | 校验调用 |
| `Automation::MacroEngine` | class | 登录宏步骤执行 | 命令产生 |
| `Config::Settings` | class | 全局设置加载、观察 | 业务数据 |
| `Config::Schema` | module | 配置校验、版本迁移 | 加载 |
| `Config::Store` | class | 会话/分组/片段的统一持久化 | schema |

#### V2.0/V3.0 预留位（仅接口位，不展开）

TUI(Curses)、ImportExport、Search、KeyManager、Proxy、Diagnostics、BatchExec、SnippetManager、Zmodem、Watcher、OTP、Stats、ScriptEngine、Recorder、Sync、TeamShare。每个在 HLD 的 9.1 已有映射，本文件第 7 章给出其与 V1.0 模块的对接点是哪个 method/class。

### 3.2 依赖图（编译期/运行期）

```
编译期依赖（仅向左依赖，禁止环）：
  ssh_ipc_proto ── ssh_codec
  ssh_auth_engine ── ssh_ipc_proto
  ssh_jump_chain ── ssh_codec
  ssh_channel_stm ── ssh_ipc_proto
  ssh_conn_worker ── {ssh_channel_stm, ssh_auth_engine, ssh_jump_chain, ssh_keepalive_mgr}
  ssh_conn_sup ── ssh_conn_worker
  ssh_keepalive_mgr ── ssh_conn_sup（仅查列表，不持引用）
  ssh_ipc_gateway ── {ssh_ipc_proto, ssh_ipc_coalesce, ssh_conn_sup, ssh_sftp_sup, ssh_known_hosts_proxy}
  ssh_core_sup ── {ssh_infra_sup, ssh_conn_sup, ssh_sftp_sup}
  ssh_infra_sup ── {ssh_ipc_gateway, ssh_keepalive_mgr, ssh_known_hosts_proxy}

运行期调用方向（RPC 入口在 gateway，向下分发）：
  Ruby IPC::Router
     │
     ▼ (Unix Socket/TCP)
  ssh_ipc_gateway ──dispatch──▶ {ssh_conn_worker, ssh_sftp_session, ssh_known_hosts_proxy, ssh_port_fwd}
                                    │
                                    ▼
                                 ssh_channel_stm ──push──▶ ssh_ipc_coalesce ──▶ ssh_ipc_gateway ──▶ Ruby

禁止反向调用：Erlang 模块不得直接调用 Ruby；Ruby 不可达时 push 丢弃并记日志。
```

---

## 4 全局不变量与 ID 规则

本节定义跨模块共享的契约。任何模块实现不得违反下列条款。

### 4.1 ID 规则

| 标识 | 格式 | 分配方 | 作用域 | 跨重启 |
|------|------|--------|--------|--------|
| `conn_id` | `conn_<unix_ms>_<8hex>` | Erlang `ssh_conn_worker:init` | 全局（单引擎进程内） | 不复用，新连接新 ID |
| `channel_id` | `ch_<conn_id_short>_<seq>` | Erlang `ssh_conn_worker`（连接内自增） | 连接内唯一 | 不复用 |
| `sftp_id` | `sftp_<conn_id_short>_<seq>` | Erlang `ssh_sftp_sup` | 连接内唯一 | 不复用 |
| `rule_id` | `fwd_<conn_id_short>_<seq>` | Erlang `ssh_port_fwd` | 连接内唯一 | 不复用 |
| `rpc_id` | 自增整数 | Ruby `IPC::Router` | 单条 IPC 连接内 | — |
| `session_id` | `sess_<uuid_v4>` | Ruby `Session::Manager` | 客户端进程内 | 不复用 |
| `group_id` | `grp_<8hex>` | Ruby `Session::Tree` | 配置文件内 | 持久化、跨重启复用 |

**关键不变量**：
- `channel_id` 是**连接内唯一**，非全局唯一。Ruby 侧用 `(conn_id, channel_id)` 复合键索引。
- `conn_id` 由 Erlang 分配并在 `conn.ready` 事件回传 Ruby；Ruby 的 `session_id` 与 `conn_id` 一对一映射，存于 `Session` 对象。
- 所有 ID 仅含 ASCII，可安全作为 JSON 字符串与文件名片段。

### 4.2 字符串编码

| 边界 | 编码 | 备注 |
|------|------|------|
| IPC 文本字段 | UTF-8 | JSON 字符串默认 |
| 终端数据 | 原始字节 → Base64 | 二进制安全，解码后按终端声明的 encoding 解释 |
| 文件路径 | UTF-8 字符串 | Erlang 侧 `unicode:characters_to_list/2` 处理 |
| 日志 | UTF-8 | 结构化字段见第 10 章 |

### 4.3 时钟与时间戳

- 所有 RPC 中的时间戳为 **Unix 毫秒整数**（Erlang 侧 `erlang:system_time(millisecond)`，Ruby 侧不使用 `Time.now.strftime`，而是用 `(Time.now.to_f*1000).to_i`）。
- 超时一律用毫秒在协议层表达；Ruby API 可暴露秒。
- 不依赖两端时钟同步；超时由发起方倒计时。

### 4.4 并发所有权

| 资源 | 拥有者 | 访问规则 |
|------|--------|---------|
| `conn_worker` 进程 | `ssh_conn_sup` | 通过 `{via, Registry, conn_id}` 注册表寻址；外部经 RPC 操作 |
| `channel_stm` 进程 | 父 `conn_worker` | 父进程 link，父退出则子终止 |
| `sftp_session` 进程 | `ssh_sftp_sup` | 经 `conn_id` 关联，conn_worker 不持有 pid |
| Ruby `Session` 对象 | `Session::Manager` 的数组/Ruby `Session` Hash | 主线程访问；event_loop 线程只读 `conn_id→session` 映射，经 `Queue` 投递到主线程处理 |
| Ruby `Vault` | 主线程 | 加解密仅主线程；`connect` 在主线程 |

---

## 5 IPC 协议详细规范（v2）

HLD 第 6 章定义了 JSON-RPC 2.0 消息格式与方法清单，但缺生命周期、分帧、流控。本节补齐。

### 5.1 分帧规则

- 每条 JSON-RPC 消息以单个 `\n`（0x0A）结尾。
- 消息内不得含裸 `\n`；JSON 序列化天然满足（字符串内 `\n` 被转义）。
- 接收方按 `\n` 切分，未遇 `\n` 前缓冲在接收 buffer，单消息上限 **2 MB**；超限即断连并记 `parse_error`。
- 终端/SFTP 原始字节经 Base64 编码后放入 `data` 字段，天然无裸 `\n`。

### 5.2 连接生命周期

```
Ruby                          Erlang ipc_gateway
  │                                 │
  │  TCP/Unix connect                │
  │────────────────────────────────▶│
  │                                 │
  │  rpc: hello {auth_token, ver}   │
  │────────────────────────────────▶│
  │                                 │ 校验 token + ver 兼容
  │  result: {server_ver, server_id}│
  │◀────────────────────────────────│
  │                                 │
  │  … 业务 RPC / 推送 …             │
  │                                 │
  │  rpc: bye                       │
  │────────────────────────────────▶│
  │  result: {ok}                   │
  │◀────────────────────────────────│
  │  close                           │
  │────────────────────────────────▶│
```

**hello**：
```json
// Ruby → Erlang
{"jsonrpc":"2.0","id":1,"method":"hello","params":{"auth_token":"<32hex>","ver":"1.0","client_id":"ruby-<pid>"}}
// Erlang → Ruby
{"jsonrpc":"2.0","id":1,"result":{"server_ver":"1.0.0","server_id":"beam-<node>","capabilities":["coalesce","batch_ack"]}}
```

未通过 hello 的后续请求一律返回 `-32000 Unauthorized`。hello 必须是第一条消息且 id 固定为 1。

**bye**：Ruby 退出前发送，Erlang 优雅清理该客户端的订阅；5 秒未收到 bye 直接断连也允许。

### 5.3 心跳

| 方向 | 方法 | 周期 | 超时判定 |
|------|------|------|---------|
| Ruby→Erlang | `engine.ping` | 15s | 连续 2 次无响应 → 判定引擎失联，Ruby 侧 `Client#stop` 并尝试重启 |

### 5.4 推送流控（背压）

**问题**：终端高频小包（`yes` 指令每秒数千包）逐条 push 会让 Ruby 线程饱和。

**机制**（Erlang 侧 `ssh_ipc_coalesce`）：
1. `channel_stm` 收到 SSH 数据后不入 gateway 队列，而是写入 per-channel 的 coalesce buffer。
2. `ssh_ipc_coalesce` 每 **8ms** 或 buffer 达到 **16 KB** 时的下一次 tick 合并为一帧：
   ```json
   {"jsonrpc":"2.0","method":"channel.data.batch","params":{"items":[{"id":"ch_..","data":".."},{"id":"ch_..","data":".."}]}}
   ```
3. watermark：当 Ruby 侧 socket send buffer 排队 > **512 KB**，gateway 暂停从 coalesce 取数据，并发 `channel.flow.pause`{conn_id, channel_id}；低于 128 KB 恢复并发 `channel.flow.resume`。
4. Ruby 侧 `IPC::Coalesce` 收到 batch 后按 channel 分发，避免每包一次回调。

**能力协商**：hello 结果里若 `capabilities` 含 `coalesce`，则 Ruby 启用 batch 消费路径；否则降级为逐条 `channel.data`（V1.0 必须支持降级，便于调试）。

### 5.5 请求-响应配对

- 每个请求带 `id`（Ruby 单调递增），Erlang 必须回相同 `id` 的 result/error。
- Erlang 推送（notification）**无 id**。
- 单请求默认超时 **30s**；`conn.connect` 默认 **60s**（含跳板链）；可在 params 中用 `timeout_ms` 覆盖。
- 超时后 Ruby 不重发；由业务层决定是否重连/重开通道。
- Erlang 不得对同一 id 重排：响应序与请求到达序一致（单连接内）。

### 5.6 错误码补充

HLD 已列 -32700~-32007。补充：

| 码 | 含义 | 触发 |
|----|------|------|
| -32000 | Unauthorized | hello 失败 / token 校验失败 |
| -32008 | Flow paused | channel 处于背压暂停时 send 被拒，Ruby 应缓存后重试 |
| -32009 | Not ready | 连接尚未 ready 时操作通道 |
| -32010 | Schema mismatch | 配置版本协议不兼容 |

---

## 6 Erlang 核心引擎详细设计

### 6.1 监督树（修正后）

```
ssh_core_sup (one_for_one, intensity 5/60s)
├── ssh_infra_sup (one_for_one, intensity 5/60s)
│   ├── ssh_known_hosts_proxy (permanent, gen_server)
│   ├── ssh_keepalive_mgr      (permanent, gen_server)
│   └── ssh_ipc_gateway        (permanent, gen_server)
│       └── (内部持有 ssh_ipc_coalesce 进程，dynamic)
├── ssh_conn_sup (simple_one_for_one, intensity 100/60s, temporary)
│   └── [ssh_conn_worker × N]
│         └── [ssh_channel_stm × M]  (conn_worker 直接 start_child 到独立临时 supervisor? 否——
│                                       channel 作为 conn_worker 的子进程，挂在 conn_worker 内部)
└── ssh_sftp_sup (simple_one_for_one, intensity 20/60s, temporary)
    └── [ssh_sftp_session × K]
```

修正要点：
- ipc_gateway、keepalive、known_hosts 移入 `ssh_infra_sup`，与 `ssh_conn_sup` 隔离，单连接崩溃不波及基础设施。
- `conn_worker` 内部直接 `proc_lib:spawn_link` 起 `channel_stm`，不走独立 supervisor；channel 生命周期严格随父连接，父亡子亡。
- `sftp_session` 独立于 conn_worker（可在同连接shell同时跑 SFTP），由 `ssh_sftp_sup` 管理，但保存 `conn_id` 关联；连接断开时 conn_worker 通知 sftp_sup 清理同 conn_id 的会话。

### 6.2 ssh_ipc_gateway

```erlang
-module(ssh_ipc_gateway).
-behaviour(gen_server).

-export([start_link/1, push_event/2, push_batch/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% 公共 API（其他 Erlang 模块调用）
%% push_event/2：单条推送，经 coalesce 缓冲
%% push_batch/1：直接发送已合并批量（coalesce tick 调用）

-include("ssh_ipc.hrl").

-record(client, {
    socket :: gen_tcp:socket() | port(),
    authed = false :: boolean(),
    pending = #{} :: #{rpc_id() => {erlang:timestamp(), From::term()}},
    send_q = queue:new() :: queue:queue(binary()),
    flow_blocked = false :: boolean()
}).

-record(state, {
    listen_sock,
    clients = #{} :: #{pid() | reference() => #client{}},
    auth_token :: binary(),
    routes :: #{binary() => {module(), atom()}},
    coalesce_ref :: pid() | undefined
}).
```

**关键函数**：

| 函数 | 签名 | 说明 |
|------|------|------|
| `start_link/1` | `(Opts) -> {ok, Pid}` | Opts 含 listen 端点、token、routes |
| `push_event/2` | `(Method, Params) -> ok` | 写入 coalesce buffer，由 coalesce tick 统一发送 |
| `handle_tcp_data/2` | (内部) | 解帧 → `ssh_ipc_proto:decode` → 路由 |
| `dispatch/3` | (内部) | spawn 执行 `{M,F}`，结果回写；崩溃包 error 响应 |
| `send_to_client/2` | (内部) | 发送编码后的 JSON；失败入 send_q；q 满（>1MB） 关闭该 client |

**路由表**（启动时注入，运行期不可变）：

```erlang
%% init 中构建
Routes = #{
    <<"hello">>           => {?MODULE, handle_hello},
    <<"bye">>             => {?MODULE, handle_bye},
    <<"engine.ping">>     => {?MODULE, handle_ping},
    <<"engine.stats">>    => {ssh_engine_stats, get_stats},
    <<"engine.shutdown">> => {?MODULE, handle_shutdown},
    <<"conn.connect">>    => {ssh_conn_sup, rpc_connect},     % 触发 start_child + do_connect
    <<"conn.disconnect">> => {ssh_conn_worker, rpc_disconnect},
    <<"conn.list">>       => {ssh_conn_sup, rpc_list},
    <<"conn.reconnect">>  => {ssh_conn_worker, rpc_reconnect},
    <<"channel.open">>    => {ssh_conn_worker, rpc_channel_open},
    <<"channel.send">>    => {ssh_channel_stm, rpc_send},
    <<"channel.close">>   => {ssh_channel_stm, rpc_close},
    <<"channel.window_change">> => {ssh_channel_stm, rpc_window_change},
    <<"sftp.open">>       => {ssh_sftp_sup, rpc_open},
    <<"sftp.list_dir">>   => {ssh_sftp_session, rpc_list_dir},
    <<"sftp.download">>   => {ssh_sftp_session, rpc_download},
    <<"sftp.upload">>     => {ssh_sftp_session, rpc_upload},
    <<"sftp.mkdir">>      => {ssh_sftp_session, rpc_mkdir},
    <<"sftp.remove">>     => {ssh_sftp_session, rpc_remove},
    <<"sftp.stat">>       => {ssh_sftp_session, rpc_stat},
    <<"portfwd.add">>     => {ssh_port_fwd, rpc_add},
    <<"portfwd.remove">>  => {ssh_port_fwd, rpc_remove},
    <<"portfwd.list">>    => {ssh_port_fwd, rpc_list},
    <<"hostkey.resolve">> => {ssh_known_hosts_proxy, rpc_resolve}  % Ruby→Erlang 不需要，这个方向是 Erlang→Ruby
}.
```

注意：`hostkey.resolve` 实际方向是 Erlang→Ruby（Erlang 主动发 notification 询问），不放 routes。Routes 仅处理 Ruby→Erlang 的同步 RPC。

### 6.3 ssh_conn_worker

```erlang
-module(ssh_conn_worker).
-behaviour(gen_statem).

%% 顶部 API
-export([start_link/1, rpc_disconnect/1, rpc_channel_open/2,
         rpc_reconnect/1, get_state/1, conn_id/1]).
%% gen_statem 回调
-export([callback_mode/0, init/1]).
-export([idle/3, connecting/3, authenticating/3, ready/3,
         reconnecting/3, closing/3, failed/3]).

-record(conn, {
    id :: binary(),
    spec :: map(),
    ssh_ref :: reference() | undefined,
    channels = #{} :: #{binary() => pid()},
    next_ch_seq = 1 :: pos_integer(),
    reconnect_count = 0 :: non_neg_integer(),
    options :: [proplists:property()],
    fail_reason :: term() | undefined,
    proxy_sock_fun :: function() | undefined
}).

callback_mode() -> state_functions.
```

**状态机（修正后）**：

```
            ┌────────┐
            │  idle  │
            └───┬────┘
   do_connect   │
   ┌────────────▼─────────────┐
   │ connecting               │   TCP/Unix 已连，等待 SSH banner+KEX
   │   ssh:connect 成功 → authenticating
   │   失败 → failed{reason}
   └────────────┬─────────────┘
                │ otp ssh 在 connect 阶段一并完成认证
   ┌────────────▼─────────────┐
   │ authenticating           │   (仅当 key_cb 需要 prompt 时短暂停留)
   │   auth 完成且 ok → ready
   │   auth 失败 → failed{auth}
   └────────────┬─────────────┘
                │
   ┌────────────▼─────────────┐
   │ ready                    │   可开通道
   │   网络断开/ssh 断开 → reconnecting
   │   disconnect → closing
   └─────┬───────────────┬────┘
         │ reconnect      │
   ┌─────▼─────┐     ┌────▼─────┐
   │reconnecting│    │ closing  │
   │ 成功→ready │     │ → closed │
   │ 最大→failed│     └──────────┘
   └───────────┘
```

**修正后的连接建立**（E1 修正）：

```erlang
%% connecting 状态
connecting(enter, _Old, Data) ->
    {keep_state, Data};
connecting({call, From}, do_connect, #conn{spec=Spec, id=Id} = Data) ->
    Host = binary_to_list(maps:get(<<"host">>, Spec)),
    Port = maps:get(<<"port">>, Spec, 22),
    User = binary_to_list(maps:get(<<"user">>, Spec)),
    Options = build_ssh_options(Spec),
    %% 关键修正：认证参数进 options，不存在 ssh:auth_user
    case ssh:connect(Host, Port, Options, ?CONNECT_TIMEOUT_MS) of
        {ok, SshRef} ->
            %% ssh:connect 成功即表示认证通过（otp ssh 把 auth 作为 connect 的一部分）
            Fingerprint = get_host_fingerprint(SshRef),
            push_conn_ready(Id, Fingerprint),
            {next_state, ready, Data#conn{ssh_ref=SshRef}, [{reply, From, {ok, Id}}]};
        {error, Reason} ->
            push_conn_failed(Id, Reason),
            {next_state, failed, Data#conn{fail_reason=Reason},
             [{reply, From, {error, Reason}}]}
    end.

build_ssh_options(Spec) ->
    [{user, binary_to_list(maps:get(<<"user">>, Spec))},
     {silently_accept_hosts, false},
     {key_cb, {ssh_auth_engine, maps:get(<<"auth">>, Spec, #{})}},
     {user_dir, binary_to_list(maps:get(<<"key_dir">>, Spec, <<"/tmp">>))},
     {preferred_algorithms, preferred_algs()},
     {connect_timeout, ?CONNECT_TIMEOUT_MS},
     {user_interaction, true}]
    ++ build_auth_options(Spec)
    ++ build_proxy_options(maps:get(<<"proxy">>, Spec, undefined))
    ++ build_jump_options(maps:get(<<"jumps">>, Spec, [])).
```

**认证选项构造**（E1/E2 修正）：

```erlang
build_auth_options(#{<<"auth">> := Auth} = _Spec) ->
    Type = maps:get(<<"type">>, Auth, password),
    case Type of
        password ->
            [{password, binary_to_list(maps:get(<<"password">>, Auth))}];
        publickey ->
            %% key_cb 回调负责 load + 依次尝试多密钥
            [];  % 实际密钥加载由 ssh_auth_engine:key_cb 处理
        keyboard_interactive ->
            [{keyboard_interactive, fun(Prompts, _Ssh) -> handle_prompts(Prompts) end}]
    end;
build_auth_options(_) -> [].
```

**跳板选项**（E3/E6 修正）：见 6.7。

### 6.4 ssh_auth_engine（key_cb 实现）

OTP ssh 通过 `key_cb` 回调完成公钥认证，而非 `ssh:auth_user`。

```erlang
-module(ssh_auth_engine).
-behaviour(ssh_client_key_api).     % OTP ssh 公钥回调 behaviour

-export([add_host_key/3, is_host_key/5,      % 主机密钥回调(key_cb)
         user_key/3]).                       % 用户私钥回调
-export([authenticate_chain/2]).             % 高层：认证回退链

%% @doc 添加主机密钥（首次连接）
%% OTP ssh 调用，要求我们裁决；不在此落盘
add_host_key(_Host, _Port, PublicKey) ->
    %% 统一交给 ssh_known_hosts_proxy 经 IPC 问 Ruby
    case ssh_known_hosts_proxy:verify(Host, Port, PublicKey) of
        accepted -> ok;
        rejected -> {error, host_key_rejected}
    end.

%% @doc 校验已有主机密钥
is_host_key(Key, _Host, _Port, _Algorithm, _) ->
    case ssh_known_hosts_proxy:verify(_Host, _Port, Key) of
        accepted -> true;
        rejected -> false
    end.

%% @doc 读取用户私钥，OTP ssh 调用此函数进行公钥认证
user_key(Algorithm, _Opts) ->
    %% Algorithm: 'ssh-rsa' | 'ssh-ed25519' | 'ecdsa-sha2-nistp256' ...
    %% 从 key_cb 初始化时传入的 Auth map 读取对应私钥路径
    KeyInfo = get(key_keyinfo),  % process dict，init 时设置
    Path = maps:get(path, KeyInfo),
    Passphrase = maps:get(passphrase, KeyInfo, undefined),
    read_private_key(Path, Algorithm, Passphrase).

read_private_key(Path, Algorithm, Passphrase) ->
    %% 使用 public_key:read_keyfile/2 读取 OpenSSH/PKCS8/SEC1
    case public_key:read_keyfile(Path, [{passphrase, Passphrase}, {algorithm, Algorithm}]) of
        {ok, Key} -> {ok, Key};
        {error, _} = E -> E
    end.

%% @doc 认证回退链：OTP ssh 单次 connect 只支持一种 auth_method，
%%       回退需多次 connect 或用 keyboard_interactive 多轮。
%%       V1.0 实现：按链顺序逐次 ssh:connect。
%%       返回 {ok, SshRef} | {error, Reason}
authenticate_chain(ConnectCtx, [Method | Rest]) ->
    Opts = build_opts_for_method(ConnectCtx, Method),
    case ssh:connect(host_of(ConnectCtx), port_of(ConnectCtx), Opts, ?T) of
        {ok, Ref} -> {ok, Ref};
        {error, _} -> authenticate_chain(ConnectCtx, Rest)
    end;
authenticate_chain(_, []) -> {error, all_auth_methods_failed}.
```

**关键修正**：OTP ssh 把认证和连接耦合在 `ssh:connect` 里，多方式回退需要多次 connect（或用 keyboard_interactive 的多轮 response）。V1.0 简化：支持单一方式 + 公钥优先失败回退密码，回退通过重新 `ssh:connect` 实现，代价是多一次握手。

### 6.5 ssh_channel_stm

```erlang
-module(ssh_channel_stm).
-behaviour(gen_statem).

-export([start_link/4, rpc_send/2, rpc_close/1, rpc_window_change/3,
         feed_data/2, notify_eof/2]).
-export([callback_mode/0, init/1]).
-export([opening/3, ready/3, flowing/3, eof/3, closed/3]).

-record(ch, {
    id :: binary(),
    conn_id :: binary(),
    ssh_ref :: reference(),
    ssh_chan_id :: integer(),        % otp ssh 内部通道号
    type :: shell | exec | subsystem,
    term_type :: binary() | undefined,
    cols :: pos_integer(),
    rows :: pos_integer(),
    coalesce_ref :: pid()
}).
```

**状态机**：

```
opening   ← start_link 后立即 ssh_connection:session_channel
   │ 成功 → ready
   │ 失败 → closed{reason}
ready     ← 通道建立，shell/exec 已发起
   │ {data, Data} → flowing + push
   │ close → closing
flowing   ← 持续数据流
   │ {data, Data} → push（滞留 flowing）
   │ eof → eof
   │ close → closing
eof       ← 收到 EOF，仍可发少量数据
   │ close → closed
closing → closed
closed    ← 通知 Ruby channel.eof，进程退出
```

**数据推送（E9 修正）**：

```erlang
%% flowing/3 收到 SSH 层数据
flowing(info, {ssh_cm, _Ref, {data, ChanId, _Type, Payload}}, #ch{} = D) ->
    %% 不直接 gateway:push_event，写入 coalesce buffer
    ssh_ipc_coalesce:enqueue(D#ch.coalesce_ref, D#ch.id, Payload),
    {next_state, flowing, D}.

%% rpc_send：Ruby 发数据到通道
rpc_send(ChId, Data) ->
    %% gen_statem:call 寻址
    case whereis({?MODULE, ChId}) of
        P when is_pid(P) -> gen_statem:call(P, {send, Data});
        undefined -> {error, not_found}
    end.
```

通道进程注册：`register({via, Registry, {?MODULE, ChId}}, Pid)`，Ruby 经 `(conn_id, ch_id)` 复合寻址。

### 6.6 ssh_sftp_session

```erlang
-module(ssh_sftp_session).
-behaviour(gen_server).

-export([start_link/2, rpc_list_dir/2, rpc_download/3, rpc_upload/3,
         rpc_mkdir/2, rpc_remove/2, rpc_stat/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-include_lib("kernel/include/file.hrl").

-record(sftp, {
    id :: binary(),
    conn_id :: binary(),
    ssh_ref :: reference(),
    sftp_pid :: pid()              % ssh_sftp:start_channel 返回的 pid
}).

%% open
start_link(ConnId, SshRef) ->
    %% ssh_sftp:start_channel/1,2 在已有 ssh_ref 上开 SFTP 通道
    {ok, SftpPid} = ssh_sftp:start_channel(SshRef, [{window, 10}, {packet, 32768}]),
    Id = gen_sftp_id(ConnId),
    gen_server:start_link({via, Registry, {?MODULE, Id}}, ?MODULE,
                          #{id=>Id, conn_id=>ConnId, ssh_ref=>SshRef, sftp_pid=>SftpPid}, []).

rpc_list_dir(Id, Path) ->
    gen_server:call(via(Id), {list_dir, Path}).

handle_call({list_dir, Path}, _From, #sftp{sftp_pid=P} = S) ->
    case ssh_sftp:read_file_info_all(P, Path) of
        {ok, Entries} -> {reply, {ok, format_entries(Entries)}, S};
        {error, E} -> {reply, {error, E}, S}
    end.
```

**并发**：单 SFTP 会话单进程串行执行操作，避免 ssh_sftp 通道内部状态竞争。批量传输通过开多个 sftp_session（同一 conn 下）实现并发。

### 6.7 ssh_jump_chain（跳板链，E3/E6 修正）

OTP ssh 没有"在已有通道上叠 SSH"的直接 API。V1.0 采用**自定义 sock_fun**方案：

```erlang
-module(ssh_jump_chain).

%% @doc 构建多级跳板连接
%% Jumps = [J1, J2, ...] 从近到远
%% 算法：
%%   1. J1 直接 ssh:connect，拿到 Ref1
%%   2. 对 J2..Jn，每次在前一跳上开 direct_tcpip 通道，把底层 socket "借出"，
%%      用 ssh:connect 的 {sock_fun, Fun} 选项让 otp ssh 在该 socket 上握手
%%   3. 最终在 Jn 上 direct_tcpip 到目标，再 ssh:connect 到目标
-spec build(connect_spec(), [connect_spec()]) -> {ok, reference()} | {error, term()}.
build(TargetSpec, []) ->
    %% 无跳板，直接连
    direct_connect(TargetSpec);
build(TargetSpec, Jumps) ->
    case lists:foldl(fun(Jump, {ok, PrevRef}) ->
                tunneled_connect(PrevRef, Jump);
           (_, {error,_}=E) -> E
        end, direct_connect(hd(Jumps)), tl(Jumps)) of
        {ok, LastJumpRef} -> tunneled_connect(LastJumpRef, TargetSpec);
        {error,_}=E -> E
    end.

%% 直接 SSH 连接
direct_connect(Spec) ->
    ssh:connect(host(Spec), port(Spec), build_ssh_options(Spec), ?T).

%% 在 PrevRef 的 SSH 隧道内连到下一跳的 TCP
tunneled_connect(PrevRef, Spec) ->
    Host = host(Spec), Port = port(Spec),
    %% otp ssh: ssh_connection:direct_tcpip(Conn, Host, Port, 0) 返回 channel
    {ok, Chan} = ssh_connection:direct_tcpip(PrevRef, Host, Port, "127.0.0.1", 0, ?T),
    %% 借出底层 socket：otp ssh 不直接暴露 socket，但提供 ssh_connection:channel_callback？
    %% —— 实际实现：用 ssh_connection:send/recv 在 channel 上跑 SSH 握手，
    %%    通过自定义 transport module 包装 channel 为 socket-like
    SockFun = make_sock_fun_from_channel(PrevRef, Chan),
    Opts = build_ssh_options(Spec) ++ [{sock_fun, SockFun}],
    ssh:connect(Host, Port, Opts, ?T).
```

**关键风险与降级**：
- `{sock_fun, Fun}` 在 OTP 26 仍是半官方选项，签名 `Fun(connect, Host, Port, Timeout) -> {ok, Sock} | {error,_}`，`Fun(close, Sock) -> ok`，`Fun(send, Sock, Data) -> ok | {error,_}`，`Fun(recv, Sock, Len, Timeout) -> {ok, Data} | {error,_}`。
- 由于 `direct_tcpip` 返回 channel 而非裸 socket，需把 channel 包装成上述 SockFun 语义。**这是 V1.0 最高风险点**，建议 V1.0 先实现单跳跳板（ProxyJump 1 级），多跳作为 V2.0 验证后的能力。
- 降级方案：客户端侧用本地端口转发链模拟跳板（在本地开 listener，经 ssh 本地转发到 J1，再连 listener），牺牲配置一致性换取实现可靠。

### 6.8 ssh_port_fwd（E4 修正）

| 类型 | OTP ssh API | 说明 |
|------|------------|------|
| Local | 自建 `gen_tcp:listen` + `ssh_connection:direct_tcpip` | `ssh_connection:direct_tcpip/6` 在 ssh 连接上开到目标的 channel |
| Remote | `ssh_connection:tcpip_forward/3` | 请求 sshd 监听远端端口，远端有连接时 sshd 回调 |
| Dynamic | Local + 自实现 SOCKS5 协商 | 读 SOCKS5 请求，解析目标后 `direct_tcpip` |

V1.0 必交付 Local + Remote，Dynamic 列为 V2.0。

### 6.9 ssh_keepalive_mgr

周期巡检所有 `ssh_conn_worker`，连续 3 次失败触发 reconnect。重连策略见 HLD（指数退避）。

**修正**：keepalive 不直接 `ssh_conn_worker:trigger_reconnect`，而是发 `conn.closed` 事件给 Ruby，由 Ruby 决定是否重连。Erlang 只负责"判定断开并通知"，重连由业务层触发 `conn.reconnect`。这避免 Erlang 自主重连冲击服务器且 Ruby 状态不同步。

### 6.10 ssh_known_hosts_proxy（E7 修正）

```erlang
-module(ssh_known_hosts_proxy).
-behaviour(gen_server).

%% OTP ssh key_cb 调用此模块裁决主机密钥
%% 本模块不落盘，经 IPC 向 Ruby 查询

-export([verify/3, start_link/0]).
-export([init/1, handle_call/3, handle_info/2]).

-record(st, {}).

%% @doc 由 ssh_auth_engine:add_host_key/is_host_key 调用
verify(Host, Port, Key) ->
    Fingerprint = pubkey_fingerprint(Key),
    %% 通过 gateway 向 Ruby 发起 notification（非 RPC，因 key_cb 可能同步等待）
    %% 这里用同步 IPC 请求-响应：发一个 method="hostkey.resolve" 的请求
    Req = #{method => <<"hostkey.resolve">>,
            params => #{host=>Host, port=>Port, fingerprint=>Fingerprint}},
    %% 注：此调用线程阻塞直到 Ruby 响应
    case ssh_ipc_gateway:synchronous_push(Req, 30000) of
        {ok, #{action := <<"accept">>}} -> accepted;
        {ok, #{action := <<"once">>}}   -> accepted_once;
        {ok, #{action := <<"reject">>}} -> rejected;
        {error, timeout}                -> rejected
    end.
```

**并发隐患**：`synchronous_push` 会阻塞 OTP ssh 的 connect 调用进程；若 Ruby 不响应，30s 后 reject。V1.0 接受这个延迟。Ruby 侧必须保证 `hostkey.resolve` 处理快速（通常是本地查 known_hosts + 可能弹窗，弹窗超时 30s 自动 reject）。

---

## 7 Ruby 调度层详细设计

### 7.1 线程模型（修正 E8）

```
Ruby 进程
├── main thread
│   └── 所有业务操作、Vault、Session::Manager
│       IPC::Router 持有 @pending 表（Mutex 保护）
├── reader thread (1 个)
│   └── 读 socket → 按 \n 切帧 → 解析 JSON
│       {id, result} → 推入对应 Queue
│       {method}     → 推入 event_queue
├── event dispatcher thread (1 个)
│   └── 从 event_queue 取推送
│       channel.data.batch → 拆 batch → 按 channel_id 路由到对应 Terminal
│       channel.eof / conn.closed → 推 main thread 的 pending actions 或回调
│       hostkey.resolve → 推 Security::HostKey 处理
└── (不创建其他常驻线程；BatchExec 临时线程在 V2.0 由 Celluloid/线程池替代)
```

**关键约定**：
- reader thread 只解析不回调，避免阻塞读取。
- event dispatcher 对每个 channel 的数据按序处理（`Channel#on_data` 加Mutex）。
- `IPC::Router#call` 在 main thread 调用，阻塞等待 reader thread 写入 Queue。

### 7.2 IPC::Router（取代 HLD 的 IPC::Client）

```ruby
module NetworkInfraUtility
  module SSH
    module IPC
      class Router
        def initialize(transport)
          @transport = transport
          @id_mutex = Mutex.new
          @next_id = 0
          @pending = {}            # id => [Queue, deadline]
          @pending_mutex = Mutex.new
          @subscriptions = {}      # method => [Proc]
          @subscriptions_mutex = Mutex.new
          @closed = false
        end

        # 同步调用
        def call(method, params = {}, timeout_ms: 30_000)
          id = next_id
          q = Queue.new
          register_pending(id, q, timeout_ms)
          send({jsonrpc: "2.0", id: id, method: method, params: params})
          msg = q.pop(timeout: timeout_ms / 1000.0)
          raise RPCTimeout, method unless msg
          raise RPCError.new(msg[:error]) if msg[:error]
          msg[:result]
        ensure
          unregister_pending(id)
        end

        # 订阅推送，返回 subscription_id 用于注销
        def subscribe(method, &block)
          sid = SecureRandom.hex(8)
          @subscriptions_mutex.synchronize do
            (@subscriptions[method] ||= {})[sid] = block
          end
          sid
        end

        def unsubscribe(method, sid)
          @subscriptions_mutex.synchronize do
            @subscriptions[method]&.delete(sid)
          end
        end

        # 由 reader thread 调用
        def on_message(msg)
          if msg[:id]
            # 响应
            q = pop_pending(msg[:id])
            q << msg if q
          elsif msg[:method]
            # 推送
            dispatch_push(msg[:method], msg[:params])
          end
        end

        private

        def dispatch_push(method, params)
          callbacks = @subscriptions_mutex.synchronize { @subscriptions[method]&.values&.dup }
          callbacks&.each { |cb| cb.call(params) }
        end
      end
    end
  end
end
```

**修正点**：
- 订阅返回 `sid`，可注销，解决 HLD 永久回调泄漏。
- `@pending` 用 Mutex 保护，reader thread 与 main thread 安全。
- 超时后主动 `unregister_pending`，reader 若晚到则丢弃。

### 7.3 IPC::Transport

```ruby
class Transport
  def initialize(endpoint)
    @socket = open_socket(endpoint)
    @write_mutex = Mutex.new
    @reader_t = nil
  end

  # 在 reader thread 中循环调用
  def each_frame
    buffer = +""
    loop do
      chunk = @socket.readpartial(65536)
      buffer << chunk
      while idx = buffer.index("\n")
        yield buffer[0...idx]
        buffer = buffer[(idx+1)..]
      end
    end
  rescue EOFError, SystemCallError
    @closed = true
  end

  def send(hash)
    data = JSON.generate(hash) + "\n"
    @write_mutex.synchronize { @socket.write(data) }
  end
end
```

注意：`@socket.readpartial` 遇到 EOF 抛 `EOFError`，需 rescue 后通知 Router 关闭。Ruby TCPSocket/UNIXSocket 都支持 `readpartial`。

### 7.4 IPC::Coalesce（push 消费端）

```ruby
class Coalesce
  def initialize(router)
    @router = router
    @terminals = {}              # (conn_id, ch_id) => Terminal::Emulator
    @terminals_mutex = Mutex.new
    @default_q = Queue.new       # 非 batch 的单条 channel.data
    setup_subscriptions
  end

  def register_channel(conn_id, ch_id, terminal)
    @terminals_mutex.synchronize { @terminals[[conn_id, ch_id]] = terminal }
    terminal.coalesce_sid = @router.subscribe("channel.data") do |p|
      handler_single(p)
    end
  end

  def unregister_channel(conn_id, ch_id)
    @terminals_mutex.synchronize { @terminals.delete([conn_id, ch_id]) }
    # 注销单个 subscription 由 terminal 持有 sid 自行 unsubscribe
  end

  private

  def setup_subscriptions
    @router.subscribe("channel.data.batch") do |p|
      items = p[:items] || []
      items.each do |item|
        dispatch_data(item[:id], item[:data])
      end
    end
  end

  def dispatch_data(ch_id, b64)
    data = Base64.decode64(b64)
    term = @terminals_mutex.synchronize { @terminals.values.find { |t| t.channel_id == ch_id } }
    # 注：匹配规则用 (conn_id, ch_id)，上面简化
    term&.feed(data)
  end
end
```

### 7.5 Session::Session（修正）

```ruby
class Session
  attr_reader :session_id, :conn_id, :name, :terminal, :file_manager

  def initialize(client, session_id, conn_id, spec)
    @client = client
    @session_id = session_id
    @conn_id = conn_id
    @spec = spec
    @terminal = nil
    @file_manager = nil
    @status = :connected
    @coalesce = client.coalesce
  end

  def open_terminal(term_type: "xterm-256color", cols: 80, rows: 24)
    raise AlreadyOpen if @terminal
    resp = @client.ipc.call("channel.open",
      {conn_id: @conn_id, type: "shell", term: term_type, cols: cols, rows: rows})
    ch_id = resp[:channel_id]
    @terminal = Terminal::Emulator.new(@client, @conn_id, ch_id, cols, rows, theme: @spec[:theme])
    @coalesce.register_channel(@conn_id, ch_id, @terminal)
    @terminal
  end

  def close_terminal
    return unless @terminal
    @client.ipc.call("channel.close", {id: @terminal.channel_id})
    @coalesce.unregister_channel(@conn_id, @terminal.channel_id)
    @terminal = nil
  end

  def disconnect
    @client.ipc.call("conn.disconnect", {id: @conn_id})
    @terminal = nil
    @file_manager = nil
    @status = :disconnected
  end
end
```

### 7.6 Terminal::Emulator / Screen / Buffer

三层分离，避免 HLD 把所有塞进 Emulator：

- `Emulator`：ANSI/xterm 解析器，喂入字节，调用 `Screen` 的方法。
- `Screen`：屏幕状态（行数组 + 光标 + 滚动区 + alt buffer + 字符属性），可被 Renderer 读取。
- `Buffer`：回滚区 + 当前屏幕的快照，提供 search/export，写入由 `Screen` 触发。

```ruby
class Emulator
  def initialize(client, conn_id, ch_id, cols, rows, theme:)
    @client = client
    @conn_id = conn_id
    @channel_id = ch_id
    @screen = Screen.new(cols, rows)
    @buffer = Buffer.new(max_lines: 10_000)
    @buffer.attach_screen(@screen)
    @theme = Theme.load(theme)
    @parser = AnsiParser.new(self)
    @logger = nil
  end

  attr_reader :channel_id, :screen, :buffer

  def feed(data)
    @parser.feed(data)
    @logger&.write(data)
  end

  def send(data)
    @client.ipc.call("channel.send", {id: @channel_id, data: Base64.encode64(data)})
  end

  def resize(cols, rows)
    @screen.resize(cols, rows)
    @client.ipc.call("channel.window_change", {id: @channel_id, cols: cols, rows: rows})
  end

  # 由 AnsiParser 回调
  def put_char(ch, x, y, style); @screen.put_char(ch, x, y, style); end
  def cursor_to(x, y); @screen.cursor_to(x, y); end
  def newline; @screen.newline; end
  # ... 其余 CSI/SGR 回调
end
```

`AnsiParser` 是纯解析器，无状态副作用，只调 `Emulator` 回调。这是 V1.0 工作量较大的模块，建议参考 `vte`/`tty`/`ruby-vte` 的转义表，覆盖 ≥ 95% ANSI（FR-TERM-001 ④）。

### 7.7 Security::Vault（修正并发）

HLD 的 Vault 实现基本可用，修正：
- `@cache` 不在多线程访问（V1.0 主线程唯一），但为 V2.0 batch 预留 `@cache_mutex`。
- `resolve_credentials` 不就地修改 spec（mutation），返回新 hash，避免调用方副作用。

### 7.8 Security::HostKey

```ruby
module Security
  class HostKey
    def initialize(store_path)
      @path = store_path
      @entries = load
      @save_mutex = Mutex.new
    end

    # 由 IPC 推送 hostkey.resolve 触发
    def resolve(host, port, fingerprint)
      key = entry_key(host, port)
      if @entries[key].nil?
        action = prompt_user(host, port, fingerprint)
        if action == :accept
          @save_mutex.synchronize { @entries[key] = fingerprint; save }
        end
        {action: action.to_s}
      elsif @entries[key] == fingerprint
        {action: "accept"}
      else
        warn_host_key_changed(host, port, @entries[key], fingerprint)
        {action: "reject"}
      end
    end

    private

    def prompt_user(host, port, fp)
      # V1.0 CLI：STDIN 询问；V2.0 TUI 弹窗，超时 30s 默认 reject
      puts "首次连接 #{host}:#{port}，指纹 #{fp}，是否信任？(y/N)"
      STDIN.gets&.chomp =~ /^y/i ? :accept : :reject
    end
  end
end
```

注册到 Router：
```ruby
router.subscribe("hostkey.resolve") do |p|
  result = host_key.resolve(p[:host], p[:port], p[:fingerprint])
  # 这是 Erlang→Ruby 的同步请求（带 id），需回响应
  router.reply_push(p[:id], result)   # Router 需支持 reply_push 给带 id 的推送回响应
end
```

注意：`hostkey.resolve` 是双向的——Erlang 发来时带 `id`，Ruby 必须回一个同 `id` 的 result。这是 JSON-RPC 反向调用的一种变体。Router 需扩展支持。

### 7.9 Automation::MacroEngine

HLD 实现基本可用。修正：
- `wait_for` 不轮询 `buffer.last_line`，改为订阅 `channel.data`，在事件到达时匹配，避免空转。
- `on_fail: :ask` 通过外部传入的 `on_ask` 回调处理，不依赖 block_given。

### 7.10 Config::Schema / Store

```ruby
module Config
  module Schema
    SCHEMA_VERSION = 1

    SESSION = {
      id: String, name: String, group: String, host: String, port: Integer,
      user: String, tags: Array, auth: Hash, terminal: Hash,
      keepalive: Hash, proxy: Hash, jumps: Array, port_forwards: Array,
      macro: Hash, log: Hash
    }.freeze

    def self.validate(sessions_doc)
      raise SchemaError, "version mismatch" unless sessions_doc[:version] == SCHEMA_VERSION
      sessions_doc[:sessions].each { |s| validate_session(s) }
      sessions_doc[:groups]&.each { |g| validate_group(g) }
      :ok
    end

    # 迁移：旧版本 → 当前版本
    def self.migrate(doc)
      # V1.0 仅 v1，预留
      doc
    end
  end

  class Store
    def initialize(path)
      @path = path
      @doc = load
    end

    def sessions; @doc[:sessions]; end
    def groups;   @doc[:groups]; end
    def find_session(id); sessions.find { |s| s[:id] == id }; end

    def save
      tmp = "#{@path}.tmp"
      File.write(tmp, YAML.dump(@doc))
      File.rename(tmp, @path)
    end
  end
end
```

**原子写**：先写 `.tmp` 再 `rename`，防止崩溃导致配置损坏。

### 7.11 SSH::Client（修正生命周期）

```ruby
class Client
  attr_reader :ipc, :sessions, :vault, :settings, :coalesce

  def initialize
    @settings = Config::Settings.new
    @vault = Security::Vault.new(@settings.master_password)
    @ipc = IPC::Router.new(IPC::Transport.new(nil))  # endpoint 占位，start_engine 后再连
    @sessions = Session::Manager.new(self)
    @coalesce = IPC::Coalesce.new(@ipc)
    @engine_pid = nil
    @engine_mutex = Mutex.new
    @started = false
  end

  def start_engine
    @engine_mutex.synchronize do
      raise AlreadyStarted if @started
      @engine_pid = spawn_engine
      endpoint = wait_for_endpoint
      @ipc.connect(endpoint)
      @ipc.call("hello", {auth_token: read_token, ver: Protocol::VER, client_id: "ruby-#{Process.pid}"})
      @started = true
    end
    self
  end

  def connect(spec)
    ensure_started
    spec = @vault.resolve_credentials(spec)  # 返回新 hash，不改入参
    conn_id = @ipc.call("conn.connect", spec, timeout_ms: 60_000)[:conn_id]
    @sessions.create(conn_id, spec)
  rescue RPCError => e
    raise ConnectionError, e.message
  end

  def stop
    @engine_mutex.synchronize do
      @ipc.call("bye", {}) rescue nil
      @ipc.close
      Process.kill("TERM", @engine_pid) if @engine_pid
      @engine_pid = nil
      @started = false
    end
  end

  private

  def ensure_started
    start_engine unless @started
  end
end
```

---

## 8 错误处理与级联策略

### 8.1 错误分级

| 级别 | 示例 | 策略 |
|------|------|------|
| 一次性操作失败 | `channel.send` 失败、`sftp.stat` 文件不存在 | 返回错误给调用方，不改变系统状态 |
| 通道级故障 | channel EOF、exec 退出 | 关闭该通道，清理订阅，通知业务层；连接保持 |
| 连接级故障 | 网络断开、SSH 协议错误 | worker 转入 reconnecting/failed；推 `conn.closed`；所有 channel 自动 eof |
| 引擎级故障 | ipc_gateway 崩溃 | supervisor 重启 gateway；客户端重连 IPC；已建立的 ssh 连接不受影响（数据暂存） |

### 8.2 级联隔离

```
ssh_conn_sup   (simple_one_for_one, temporary)
   │ 单个 conn_worker 崩溃
   ▼
   不触发 supervisor 重启策略（temporary + simple_one_for_one 崩溃即删，不重试）
   不波及 ssh_infra_sup 下的 gateway/keepalive/known_hosts
```

- conn_worker 崩溃 → 其下所有 channel_stm 因 link 随之退出 → 状态在 Registry 中清除 → 推 `conn.closed`。
- IPC gateway 崩溃重启 → TCP/Unix listener 重建 → 现有 ssh 连接的 ssh_ref 仍有效，但 push 通道中断 → Ruby 侧 `engine.ping` 失败 → Ruby 触发 `engine.restart` 或退出。
- keepalive 崩溃 → rediscovery 阶段漏检；重启后重新扫描，可容忍。

### 8.3 重连规则（Erlang 不自主重连）

1. `conn.closed` 推送到达 Ruby。
2. Ruby `Session::Manager` 检查该会话的 `auto_reconnect` 配置。
3. 若开启，按指数退避调度 `conn.reconnect` RPC（不是重新 `conn.connect`，以复用原 conn_id 与配置）。
4. `conn.reconnect` 成功 → 推 `conn.ready`；失败 → 继续退避直到最大次数 → `Session.status = :error`。

**防冲击**：全局重连令牌桶，最多每秒发起 5 次 `conn.reconnect`，避免 50 个连接同时断网后瞬时打满服务器。

### 8.4 Ruby 侧异常隔离

- reader thread 任何异常 → log + 通知 main → `Client#on_ipc_lost` 回调。
- event dispatcher 异常 → 单条推送丢弃 + log，线程存活。
- batch 解码失败 → 丢弃该 batch + log，不影响其他通道。
- `hostkey.resolve` 处理超时 30s → 自动 reject。

---

## 9 配置体系与数据一致性

### 9.1 文件布局（沿用 HLD 7.3）

```
~/.network-infra-utility/
├── settings.yml
├── sessions.yml
├── vault.yml          (权限 600/ACL)
├── known_hosts.yml
├── snippets/  themes/  macros/  logs/
```

### 9.2 sessions.yml schema（形式化）

```yaml
version: 1
groups:
  - id: <grp_8hex>
    name: <string>
    parent: <grp_id | null>
    collapsed: <bool>           # UI 折叠态
sessions:
  - id: <sess_uuid>
    name: <string>
    group: <grp_id | null>
    host: <string>
    port: <int 1-65535>         # default 22
    user: <string>
    tags: [<string>...]
    auth:
      type: password | publickey | keyboard_interactive
      key_path: <string>?       # publickey
      password_ref: <~vault:key>?  # password
      passphrase_ref: <~vault:key>?
      chain: [password, publickey]?  # 回退顺序
    terminal:
      type: xterm-256color | vt100 | vt220
      theme: <string>
      font: <string>
      font_size: <int 8-32>
      scrollback: <int 1000-100000>
      encoding: utf-8 | gbk
    keepalive:
      interval: <int 5-300>     # 秒
      count_max: <int 1-10>
    proxy:
      type: socks5 | http
      host: <string>
      port: <int>
      auth: {user, password_ref}?
    jumps:
      - host, port, user, auth  # 同 auth 结构
    port_forwards:
      - {type: local|remote|dynamic, local_port, remote_host?, remote_port?, enabled}
    macro:
      enabled: <bool>
      steps: [{action, wait_pattern, delay, on_fail}]
    log:
      enabled: <bool>
      path: <string>
      max_size: <int MB>
      rotate: <int>
    auto_reconnect:
      enabled: <bool>
      max_attempts: <int 1-10>
      base_interval: <int 1-60>
```

### 9.3 一致性规则

- 写入采用 **read-modify-write + 原子 rename**（9.10 已示）。
- 运行期 hot-reload：V1.0 不支持热加载；修改配置需重连会话。V2.0 引入 `config.reload` RPC。
- `version` 字段强制；不匹配时 `Schema.migrate` 尝试迁移，失败则拒绝加载并报错。

### 9.4 凭据引用解析时机

```
sessions.yml 中 password_ref: "~vault:sess_001_pass"
       │
       ▼ Session::Manager#connect
Vault.resolve_credentials(spec)  →  spec[:auth][:password] = "明文"
       │
       ▼ IPC conn.connect
包含明文密码的 JSON-RPC（本地 IPC）
       │
       ▼ Erlang conn_worker
ssh:connect options 中 {password, Pwd}
       │
       ▼ 连接建立后
Erlang 进程字典中清除 Pwd（显式 erase），仅保留 ssh_ref
Ruby 侧 spec 副本在 connect 返回后由 GC 回收
```

---

## 10 可观测性设计

### 10.1 日志架构

| 组件 | 目标 | 格式 | rotation |
|------|------|------|----------|
| Erlang 引擎 | `~/.network-infra-utility/logs/engine-<date>.log` | 每行一个 JSON 对象（structured） | 按日 + 单文件 100MB |
| Ruby 客户端 | `~/.network-infra-utility/logs/client-<date>.log` | 文本，`[ISO8601] [LEVEL] [module] msg` | 同上 |
| 会话日志 | `logs/<sess_id>/<ts>.log` | 纯文本带时间戳；可选 HTML | 单文件 100MB / 保留 10 |

### 10.2 结构化日志字段（Erlang）

```erlang
%% logger 配置（sys.config）
{logger, [
    {handler, default, logger_std_h, #{
        config => #{file => "logs/engine.log", max_no_files => 10, max_no_bytes => 104857600},
        formatter => {logger_json_formatter, #{}}
    }}
]}.
```

每条日志字段：

| 字段 | 说明 |
|------|------|
| ts | ISO8601 |
| level | debug/info/warning/error |
| module | 模块名 |
| conn_id | 关联连接（若有） |
| channel_id | 关联通道（若有） |
| event | 事件名 |
| msg | 人类可读描述 |
| fields | 任意结构化附加 |

### 10.3 关键事件清单

| event | level | 触发 |
|-------|-------|------|
| ipc.client_connected | info | Ruby 客户端 hello 成功 |
| ipc.client_disconnected | info | 断开/超时 |
| conn.connect_start | debug | 开始 ssh:connect |
| conn.connect_ok | info | 连接成功 |
| conn.connect_failed | warning | 失败含 reason |
| conn.reconnect_try | info | 重连尝试含序号 |
| conn.closed | info | 连接关闭 |
| channel.open_ok | debug | 通道就绪 |
| channel.eof | info | 通道 EOF |
| hostkey.prompt | info | 请求 Ruby 裁决 |
| hostkey.changed | warning | 主机密钥变更 |
| auth.method | debug | 认证方式尝试 |
| auth.failed | warning | 认证失败 |
| flow.pause | info | 背压暂停 |
| flow.resume | info | 背压恢复 |
| sftp.transfer_ok | info | 传输完成含字节数/耗时 |
| engine.shutdown | info | 引擎关闭 |

### 10.4 engine.stats

```json
{"method":"engine.stats","params":{}}
→
{"result":{
  "uptime_ms": 1234567,
  "connections": {"total": 5, "ready": 4, "reconnecting": 1, "failed": 0},
  "channels": 12,
  "sftp_sessions": 2,
  "memory_kb": {"total": 51200, "processes": 10240, "binary": 30720},
  "ipc": {"clients": 1, "push_q_depth": 0, "push_dropped": 0},
  "coalesce": {"batches_sent": 1024, "items_total": 8192}
}}
```

---

## 11 模块完成判定标准（Definition of Done）

每个模块满足下列条件即为 V1.0 done。

### 11.1 Erlang 侧

| 模块 | DoD |
|------|-----|
| ssh_ipc_gateway | hello/bye 握手通过；所有路由方法可达；token 校验生效；单 client 1000 RPC/s 稳定 1min 无丢消息 |
| ssh_ipc_coalesce | batch 合并生效；watermark 触发 flow.pause/resume；`yes` 指令 60s 无 Ruby 侧丢包 |
| ssh_conn_worker | 密码/公钥/keyboard_interactive 三种方式分别连 OpenSSH 成功；跳板单级成功；状态机各分支覆盖 |
| ssh_channel_stm | shell 通道交互 ≥ 10000 行输出无错乱；window_change 生效；eof 正确通知 |
| ssh_auth_engine | key_cb 成功加载 OpenSSH/PKCS8/SEC1 三种私钥格式；认证回退链生效 |
| ssh_jump_chain | 单级跳板连通目标；多级标记为 V2.0 但接口齐备 |
| ssh_port_fwd | Local + Remote 转发各通过 curl 验证；Dynamic 接口齐备 |
| ssh_sftp_session | list/download/upload/mkdir/remove/stat 全通过；1GB 文件上传校验一致 |
| ssh_keepalive_mgr | 心跳间隔可配；连续 3 次失败触发 conn.closed |
| ssh_known_hosts_proxy | 首次连接触发 Ruby 裁决；变更触发 reject；超时 reject |

### 11.2 Ruby 侧

| 模块 | DoD |
|------|-----|
| SSH::Client | start/stop 生命周期稳定；引擎异常能感知并报错 |
| IPC::Transport | 分帧正确；EOF 优雅关闭 |
| IPC::Router | 1000 次并发 call 全部正确配对；订阅注册/注销无泄漏 |
| IPC::Coalesce | batch 消费正确；注销后不再收到数据 |
| Session::Manager | connect/disconnect/search/broadcast 语义正确；50 并发会话无死锁 |
| Session::Session | open_terminal/close_terminal/disconnect 正确清理订阅 |
| Terminal::Emulator | ANSI 覆盖率 ≥ 95%（用 vttest 子集验证）；URL/IP 识别可点 |
| Terminal::Screen | 80x24 标准 vt100 行为；alt buffer；滚动区 |
| Terminal::Buffer | 10000 行回滚；search ≤ 200ms |
| Terminal::Theme | ≥ 10 套内置；导入 iTerm2 配色通过 |
| Terminal::Logger | 自动轮转；HTML 格式带颜色还原 |
| Security::Vault | AES-256-GCM 加解密一致；文件权限 600/ACL；空主密码拒绝 |
| Security::HostKey | 首次/匹配/变更三种裁决路径通过；30s 超时 reject |
| Automation::MacroEngine | 50 步宏执行；wait_pattern 匹配；on_fail 三分支 |
| Config::Schema | v1 schema 校验；非法配置明确报错 |
| Config::Store | 原子写；崩溃后文件不损坏 |

---

## 12 测试矩阵

### 12.1 Erlang Common Test 套件

| 套件 | 覆盖 |
|------|------|
| ssh_ipc_gateway_SUITE | hello/bye/ping、token、路由、coalesce、背压 |
| ssh_conn_worker_SUITE | 三种认证、状态机、超时 |
| ssh_channel_stm_SUITE | shell/exec、window_change、eof、大批量数据 |
| ssh_auth_engine_SUITE | key_cb 各格式、回退链 |
| ssh_jump_chain_SUITE | 单级、多级(可 skip V1.0) |
| ssh_port_fwd_SUITE | Local/Remote、规则增删 |
| ssh_sftp_session_SUITE | 全操作、大文件、并发会话 |
| ssh_keepalive_mgr_SUITE | 心跳、失败计数、conn.closed |
| ssh_known_hosts_proxy_SUITE | 三种裁决 + 超时 |

### 12.2 Ruby RSpec

| spec | 覆盖 |
|------|------|
| ipc/transport_spec | 分帧、EOF |
| ipc/router_spec | 并发 call、订阅、超时 |
| ipc/coalesce_spec | batch、注销 |
| session/manager_spec | CRUD、search、broadcast |
| session/session_spec | 生命周期 |
| terminal/emulator_spec | ANSI 解析（用固定向量） |
| terminal/buffer_spec | 回滚、search 性能 |
| security/vault_spec | 加解密、权限 |
| security/host_key_spec | 裁决路径 |
| automation/macro_engine_spec | 步骤、wait、on_fail |
| config/schema_spec | 校验、迁移 |

### 12.3 端到端集成

| 场景 | 步骤 | 通过标准 |
|------|------|---------|
| 基本连接 | 启动引擎 → connect OpenSSH → 交互 `ls` → 断开 | 输出正确，无残留进程 |
| 公钥认证 | 用 ed25519 key 连接 | 成功，日志显示 publickey |
| 单级跳板 | 经 J1 连目标 | 目标 shell 可用 |
| SFTP 上传 | 1GB 文件上传 | 校验一致，耗时记录 |
| 端口转发 | Local 8080→远端 80 | curl 本地 8080 返回远端页面 |
| 保活断连 | 拔网 5s 恢复 | conn.closed → reconnect → ready |
| 50 并发 | 50 会话同时 `ls` | 全部成功，内存 ≤ 500MB |
| 主机密钥变更 | 换主机 key 再连 | 高亮告警，连接拒绝 |
| 登录宏 | Cisco 设备登录宏 | 按步执行到 `#` prompt |

---

## 附录 A：V1.0 风险登记

| 风险 | 等级 | 缓解 |
|------|------|------|
| `{sock_fun}` 跳板不稳 | 高 | V1.0 仅单级；多跳用本地端口转发链降级 |
| ANSI 覆盖率 95% 工作量大 | 高 | 借用 tty/vte 转义表，先覆盖 xterm 常用子集 |
| otp ssh key_cb 与 known_hosts 交互复杂 | 中 | known_hosts 走 Ruby 落盘，Erlang 仅裁决 |
| Ruby 单线程 event loop 在高频数据下饱和 | 中 | coalesce + batch；V2.0 评估 Celluloid |
| 跨平台 Erlang release 体积大 | 中 | strip + 压缩；Windows ERTS 约 40MB |
| vault.yml 主密码丢失不可恢复 | 中 | 文档提示 + V2.0 考虑恢复码 |

## 附录 B：与 HLD 章节对照

| 本文档章节 | 对应 HLD 章节 | 关系 |
|------------|---------------|------|
| 2 勘误 | HLD 4.2 | 修正 |
| 3 模块全景 | HLD 4.1 / 5.1 | 细化 |
| 4 不变量 | HLD 无 | 新增 |
| 5 IPC v2 | HLD 6 | 细化+补缺 |
| 6 Erlang 详细 | HLD 4.2 | 细化+修正 |
| 7 Ruby 详细 | HLD 5.2 | 细化 |
| 8 错误级联 | HLD 无 | 新增 |
| 9 配置 | HLD 7 | 形式化 |
| 10 可观测性 | HLD 无 | 新增 |
| 11 DoD | HLD 无 | 新增 |
| 12 测试矩阵 | HLD 10.4 | 细化 |
