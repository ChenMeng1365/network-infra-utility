
# SSH 连接客户端软件设计文档

> **文档版本**：v1.0  
> **编写日期**：2026-08-02  
> **文档状态**：初稿  
> **对应需求**：SSH连接客户端功能需求文档 v1.0

---

## 目录

- [1 设计概述](#1-设计概述)
- [2 系统架构](#2-系统架构)
- [3 技术选型](#3-技术选型)
- [4 Erlang SSH 核心引擎设计](#4-erlang-ssh-核心引擎设计)
- [5 Ruby 调度界面设计](#5-ruby-调度界面设计)
- [6 通信协议设计](#6-通信协议设计)
- [7 数据模型设计](#7-数据模型设计)
- [8 安全设计](#8-安全设计)
- [9 需求映射矩阵](#9-需求映射矩阵)
- [10 部署与打包](#10-部署与打包)
- [11 三期迭代设计](#11-三期迭代设计)

---

## 1 设计概述

### 1.1 编写目的

本文档基于《SSH 连接客户端功能需求文档》的全部 51 条功能需求与 20 条非功能需求，定义系统的架构分层、模块划分、接口协议、数据模型和安全机制，为开发团队提供可落地的工程蓝图。

### 1.2 设计目标

| 目标 | 量化指标 | 对应需求 |
|------|----------|----------|
| 高并发连接 | 单实例 ≥ 50 个活跃 SSH 会话 | NFR-PERF-006 |
| 低延迟交互 | 按键到屏幕回显 ≤ 50ms | NFR-PERF-003 |
| 高可靠运行 | 连续运行 72h 无崩溃 | NFR-REL-001 |
| 跨平台一致 | Windows/macOS/Linux 功能一致度 ≥ 95% | FR-COLLAB-001 |
| 低资源占用 | 10 个活跃会话内存 ≤ 500MB | NFR-PERF-005 |

### 1.3 架构决策摘要

| 决策点 | 选择 | 理由 |
|--------|------|------|
| SSH 协议栈语言 | Erlang/OTP | OTP 的 ssh 应用提供成熟 SSH2 协议栈，轻量进程模型天然适配高并发连接管理 |
| 调度与 UI 层语言 | Ruby | 与 network-infra-utility 项目主语言统一，gem 生态丰富，开发效率高 |
| 进程间通信 | JSON-RPC 2.0 over Unix Socket / TCP | 语言无关、调试友好、Unix Socket 零拷贝低延迟 |
| UI 渲染方案 | 分阶段：CLI → TUI(ruby-curses) → GUI(可选) | 降低首版复杂度，先交付可交互 CLI，逐步增强 |
| 配置存储格式 | YAML + 加密字段（AES-256-GCM） | YAML 可读性好，敏感字段单独加密 |
| 终端仿真 | Ruby 侧 VT100/xterm 转义解析 + Erlang 侧透传 | 转义解析近 UI 层，协议层保持透传 |

### 1.4 设计约束

- Erlang 侧不引入第三方 SSH 库，直接基于 OTP `ssh` 应用（Erlang/OTP 26+ 内置）。
- Ruby 侧不直接处理任何 TCP/SSH 协议细节，所有网络连接由 Erlang 层代理。
- 跨平台编译：Windows 使用 Rebar3 + MSVC，macOS/Linux 使用 Rebar3 + GCC/Clang。
- 最终产物为单一守护进程（Erlang）+ Ruby gem 前端，二者通过本地 IPC 耦合。

---

## 2 系统架构

### 2.1 总体架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                    Ruby 调度界面层 (Frontend)                     │
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐│
│  │ 会话管理  │ │ 终端仿真  │ │ 文件管理  │ │ 自动化    │ │ 安全   ││
│  │ SessMgr  │ │ Terminal │ │ FileMgr  │ │ Engine   │ │ Vault  ││
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └───┬────┘│
│       │            │            │             │           │      │
│  ┌────┴────────────┴────────────┴─────────────┴───────────┴────┐ │
│  │              IPC Client (JSON-RPC 2.0 Adapter)               │ │
│  └────────────────────────┬─────────────────────────────────────┘ │
└───────────────────────────┼───────────────────────────────────────┘
                            │  Unix Socket / 127.0.0.1:TCP
                            │  JSON-RPC 2.0
┌───────────────────────────┼───────────────────────────────────────┐
│              Erlang SSH 核心引擎层 (Backend)                       │
│  ┌────────────────────────┴─────────────────────────────────────┐ │
│  │              IPC Gateway (JSON-RPC Dispatcher)                │ │
│  └────┬────────────┬─────────────┬────────────┬──────────────────┘ │
│       │            │             │            │                     │
│  ┌────┴────┐ ┌─────┴─────┐ ┌─────┴────┐ ┌─────┴─────┐ ┌──────────┐│
│  │ 连接池   │ │ 认证引擎   │ │ 端口转发  │ │ SFTP 引擎  │ │ 跳板链   ││
│  │ConnPool │ │AuthEngine│ │PortFwd  │ │SftpEngine│ │JumpChain ││
│  └────┬────┘ └──────────┘ └──────────┘ └───────────┘ └──────────┘│
│       │                                                           │
│  ┌────┴──────────────────────────────────────────────────────────┐│
│  │              Erlang/OTP ssh 应用 (SSH2 协议栈)                 ││
│  │   密钥交换 │ 对称加密 │ MAC │ 压缩 │ 通道复用                    ││
│  └───────────────────────────────────────────────────────────────┘│
│                              │                                     │
│  ┌───────────────────────────┴───────────────────────────────────┐│
│  │              TCP / 网络 I/O                                     ││
│  └───────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 分层职责

| 层           | 语言   | 核心职责 | 不负责 |
|-------------|--------|---------|--------|
| Ruby 调度层  | Ruby   | 会话编排、配置管理、终端渲染、自动化脚本、凭据加解密、用户交互 | 不直接建立 TCP 连接、不处理 SSH 二进制协议 |
| IPC 通道     | 双端   | JSON-RPC 2.0 消息封装与路由 | 不包含业务逻辑 |
| Erlang 核心层 | Erlang | SSH 握手、认证、加密通道管理、端口转发、SFTP 子系统、连接池、跳板链 | 不做 UI 渲染、不做配置持久化 |
| OTP ssh 应用 | Erlang | SSH2 协议实现（RFC 4250-4256） | 由 OTP 维护 |

### 2.3 数据流举例：用户连接一台服务器

```
用户点击"连接"
    │
    ▼
Ruby SessMgr.build_connect_spec(session)
    │ 构建 JSON-RPC 请求: {"method":"conn.connect","params":{...}}
    ▼
IPC Client ──Unix Socket──▶ Erlang IPC Gateway
    │
    ▼
Erlang ConnPool.spawn_connection(spec)
    │ 调用 ssh:connect/3 建立 TCP + SSH 握手
    │ 执行认证（密码/公钥/keyboard-interactive）
    ▼
Erlang 返回: {"result":{"channel_id":"ch_001","fingerprint":"SHA256:..."}}
    │
    ▼
Ruby Terminal.create(channel_id)
    │ 后续终端数据双向流:
    │   Ruby → Erlang: {"method":"channel.send","params":{"id":"ch_001","data":"ls\n"}}
    │   Erlang → Ruby: 推送 (push) {"method":"channel.data","params":{"id":"ch_001","data":"..."}}
```

### 2.4 进程模型

```
Erlang VM (beam)
├── ssh_core_sup (顶层 supervisor)
│   ├── ipc_gateway      (gen_server, 1个, 监听 Unix Socket)
│   ├── conn_pool_sup    (simple_one_for_one, N个连接)
│   │   ├── conn_worker_1  (gen_server, 1个SSH连接)
│   │   │   ├── channel_1  (gen_fsm, shell通道)
│   │   │   ├── channel_2  (gen_fsm, sftp通道)
│   │   │   └── portfwd_1  (gen_server, 端口转发)
│   │   ├── conn_worker_2
│   │   └── ...
│   ├── auth_engine      (gen_server, 认证状态机)
│   ├── sftp_engine_sup  (supervisor, SFTP子池)
│   └── keepalive_mgr    (gen_server, 心跳巡检)
│
Ruby Process
├── main thread
│   ├── SessMgr          (会话调度)
│   ├── TerminalRouter   (终端数据分发)
│   └── IPC::Client      (JSON-RPC 客户端, 1个连接)
├── event_loop thread     (监听 Erlang push 消息)
└── vault_worker thread   (凭据加解密)
```

---

## 3 技术选型

### 3.1 Erlang 侧

| 组件 | 选择 | 版本要求 | 说明 |
|------|------|----------|------|
| 运行时 | Erlang/OTP | 26+ | 内置 ssh 应用，支持 curve25519-sha256 |
| 构建工具 | Rebar3 | 3.20+ | OTP 标准构建工具 |
| SSH 协议栈 | OTP ssh | 随 OTP | 无第三方依赖 |
| JSON 解析 | jsx | 3.1+ | 纯 Erlang JSON 库，编译进 release |
| 日志 | logger | OTP 内置 | 结构化日志 |
| 加密 | crypto | OTP 内置 | 底层调用 OpenSSL |
| 测试框架 | Common Test | OTP 内置 | OTP 标准测试框架 |

### 3.2 Ruby 侧

| 组件 | 选择 | 版本要求 | 说明 |
|------|------|----------|------|
| 运行时 | Ruby | 3.1+ | 项目已在用 |
| 终端渲染 | curses / reline | 标准库 | V1.0 CLI 渲染 |
| JSON | json | 标准库 | JSON-RPC 通信 |
| 加密 | openssl | 标准库 | AES-256-GCM 凭据加密 |
| 配置 | yaml | 标准库 | 会话与设置持久化 |
| 测试框架 | RSpec | 3.12+ | 与项目现有 spec 一致 |
| CLI 框架 | thor | 1.2+ | 命令行参数解析 |
| 终端 TUI | curses | 标准库 | V2.0 多面板 TUI |

### 3.3 选型对比记录

#### SSH 协议语言对比

| 方案 | 优势 | 劣势 | 结论 |
|------|------|------|------|
| **Erlang/OTP ssh** | 协议栈成熟，进程模型天然适配高并发，容错监督树 | 生态偏后端，UI 无原生支持 | **采用**——协议核心放 Erlang |
| Ruby net/ssh | 与前端同语言，调用简单 | 单线程连接管理受限，协议实现不如官方，高并发性能差 | 否决——无法满足 50 并发 |
| Rust russh | 性能最优，内存安全 | 生态不如 OTP 成熟，开发周期长 | 否决——ROI 不够 |
| Go x/crypto/ssh | 编译单二进制，并发好 | GC 暂停影响终端低延迟，ssh 库功能覆盖中等 | 备选——V2.0 评估 |

#### 前端语言对比

| 方案 | 优势 | 劣势 | 结论 |
|------|------|------|------|
| **Ruby** | 与 network-infra-utility 统一，gem 生态丰富，开发效率高 | GUI 生态弱，性能不如编译型语言 | **采用**——CLI/TUI 先行 |
| Electron/TS | 跨平台 GUI 生态最成熟 | 引入 JS 生态，内存占用大，偏离项目技术栈 | 否决 |
| Qt/C++ | GUI 性能最优 | 开发效率低，编译复杂 | 备选——V3.0 差异化评估 |

---

## 4 Erlang SSH 核心引擎设计

### 4.1 应用结构

```
ssh_core/
├── src/
│   ├── ssh_core.app.src          % OTP application 资源文件
│   ├── ssh_core_sup.erl          % 顶层 supervisor
│   ├── ssh_core_app.erl          % application 回调
│   ├── ssh_ipc_gateway.erl       % IPC 网关 (gen_server)
│   ├── ssh_ipc_proto.erl         % JSON-RPC 协议编解码
│   ├── ssh_conn_pool_sup.erl     % 连接池 supervisor
│   ├── ssh_conn_worker.erl       % 单连接工作进程 (gen_server)
│   ├── ssh_channel_fsm.erl       % SSH 通道状态机 (gen_fsm)
│   ├── ssh_auth_engine.erl       % 认证引擎
│   ├── ssh_jump_chain.erl        % 跳板链构建器
│   ├── ssh_port_fwd.erl          % 端口转发管理器
│   ├── ssh_sftp_engine.erl       % SFTP 引擎
│   ├── ssh_keepalive_mgr.erl     % 保活巡检器
│   ├── ssh_known_hosts.erl       % 已知主机管理
│   └── ssh_codec.erl             % 共用编解码工具
├── rebar.config
├── test/
│   ├── ssh_ipc_gateway_SUITE.erl
│   ├── ssh_conn_worker_SUITE.erl
│   └── ...
└── Makefile
```

### 4.2 模块详细设计

#### 4.2.1 ssh_ipc_gateway — IPC 网关

**职责**：监听本地 Unix Socket（Windows 用 127.0.0.1 TCP），接受 Ruby 端连接，将 JSON-RPC 请求分发到对应模块，异步事件推送给 Ruby。

```erlang
%% ssh_ipc_gateway.erl 核心接口
-module(ssh_ipc_gateway).
-behaviour(gen_server).

%% API
-export([start_link/1, push_event/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% 状态
-record(state, {
    listen_socket :: gen_tcp:socket() | undefined,  % 监听 socket
    clients = #{} :: #{pid() => #client{}},          % 已连接的 Ruby 客户端
    rpc_routes :: #{binary() => {module(), atom()}}  % 方法路由表
}).
```

**监听策略**：

| 平台 | 传输方式 | 地址 |
|------|----------|------|
| macOS/Linux | Unix Socket | `/tmp/ssh_core_<user>.sock` |
| Windows | TCP | `127.0.0.1:随机高端口`（写入临时文件供 Ruby 读取） |

**认证机制**：Ruby 启动时从临时文件读取端口号和随机令牌，首次 JSON-RPC 请求带 `auth_token` 字段，网关校验后绑定会话。

**请求分发**：

```erlang
%% 分发逻辑
handle_info({tcp, Socket, Data}, State) ->
    case ssh_ipc_proto:decode(Data) of
        {ok, #{<<"id">> := Id, <<"method">> := Method, <<"params">> := Params}} ->
            {Module, Fun} = maps:get(Method, State#state.rpc_routes),
            spawn(fun() ->
                Result = try
                    {ok, Module:Fun(Params)}
                catch
                    Class:Reason -> {error, #{class => Class, reason => Reason}}
                end,
                Response = ssh_ipc_proto:encode_response(Id, Result),
                gen_tcp:send(Socket, Response)
            end),
            {noreply, State};
        {ok, #{<<"method">> := Method, <<"params">> := Params}} ->
            %% push notification, 不需要回复
            handle_push(Method, Params),
            {noreply, State}
    end.
```

#### 4.2.2 ssh_conn_worker — 连接工作进程

**职责**：管理一条完整的 SSH 连接，包括握手、认证、通道管理和连接生命周期。

**状态机**：

```
                ┌──────────┐
                │  idle    │
                └────┬─────┘
                     │ connect/2
                     ▼
                ┌──────────┐    失败    ┌──────────┐
                │connecting│───────────▶│  failed  │
                └────┬─────┘            └──────────┘
                     │ TCP connected
                     ▼
                ┌──────────┐    失败    ┌──────────┐
                │handshaking│──────────▶│  failed  │
                └────┬─────┘            └──────────┘
                     │ SSH banner + KEX
                     ▼
                ┌──────────┐    失败    ┌──────────┐
                │authenticating│───────▶│  failed  │
                └────┬─────┘            └──────────┘
                     │ auth success
                     ▼
                ┌──────────┐
                │  ready   │◀─── 重连成功
                └────┬─────┘
                     │ disconnect / 网络断开
                     ▼
                ┌──────────┐    重试    ┌──────────┐
                │reconnect │───────────▶│  ready   │
                └────┬─────┘   超时       └──────────┘
                     │ max retries
                     ▼
                ┌──────────┐
                │  closed  │
                └──────────┘
```

```erlang
%% ssh_conn_worker.erl
-module(ssh_conn_worker).
-behaviour(gen_server).

-record(conn, {
    id                :: binary(),          % 连接唯一 ID
    spec              :: map(),             % 连接参数
    ssh_ref           :: reference() | undefined,  % ssh:connect 返回的句柄
    channels = #{}    :: #{binary() => pid()},     % 通道 Pid 映射
    state = idle      :: idle|connecting|handshaking|authenticating|ready|reconnect|closed|failed,
    reconnect_count = 0 :: non_neg_integer(),
    options           :: [{atom(), term()}]        % ssh:connect 选项
}).

%% 核心操作
-export([connect/1, disconnect/1, open_channel/2, open_sftp/1]).
```

**连接建立流程**：

```erlang
%% @doc 建立完整 SSH 连接
connect(Spec) ->
    {ok, Pid} = ssh_conn_pool_sup:start_child(Spec),
    ssh_conn_worker:do_connect(Pid).

%% @doc 内部连接实现
do_connect(Pid) ->
    gen_server:call(Pid, do_connect, infinity).

handle_call(do_connect, _From, #conn{spec = Spec} = State) ->
    Options = build_ssh_options(Spec),
    Host = maps:get(<<"host">>, Spec),
    Port = maps:get(<<"port">>, Spec, 22),
    case ssh:connect(binary_to_list(Host), Port, Options, infinity) of
        {ok, SshRef} ->
            NewState = State#conn{ssh_ref = SshRef, state = ready},
            %% 通知 IPC 网关推送连接就绪事件
            ssh_ipc_gateway:push_event(<<"conn.ready">>, #{id => State#conn.id}),
            {reply, {ok, State#conn.id}, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State#conn{state = failed}}
    end.
```

**跳板链处理** — FR-CONN-003：

```erlang
%% @doc 构建多级跳板连接
%% 算法：从最后一级跳板开始反向递归，每级用 ssh:connect + ssh_connection:session_channel
build_jump_chain(TargetSpec, Jumps) ->
    %% Jumps = [Jump1, Jump2, ...]（从近到远）
    %% 1. 连第一级跳板（直接 TCP）
    {ok, Ref1} = direct_connect(hd(Jumps)),
    %% 2. 逐级在上一级 SSH 通道内建立到下一级的 TCP 转发
    Refs = lists:foldl(fun(Jump, Acc) ->
        [ParentRef | _] = Acc,
        {ok, NextRef} = tunneled_connect(ParentRef, Jump),
        [NextRef | Acc]
    end, [Ref1], tl(Jumps)),
    %% 3. 在最后一级跳板上建立到最终目标的 SSH 连接
    {ok, FinalRef} = tunneled_connect(hd(Refs), TargetSpec),
    {ok, FinalRef}.

%% @doc 通过已有 SSH 通道建立到目标的 TCP 连接
tunneled_connect(SshRef, Spec) ->
    Host = binary_to_list(maps:get(<<"host">>, Spec)),
    Port = maps:get(<<"port">>, Spec, 22),
    %% 使用 ssh_connection:direct_tcpip 建立端口转发
    {ok, ChanId} = ssh_connection:direct_tcpip(SshRef, Host, Port, "127.0.0.1", 0, infinity),
    %% 在这个通道上发起新的 SSH 握手
    {ok, NewRef} = ssh:connect_via(ChanId, build_ssh_options(Spec)),
    {ok, NewRef}.
```

#### 4.2.3 ssh_channel_fsm — 通道状态机

**职责**：管理单个 SSH 通道（shell/exec/sftp/subsystem）的生命周期与数据流。

```erlang
-module(ssh_channel_fsm).
-behaviour(gen_fsm).

%% 状态
%% open    → 通道已打开，正在协商
%% ready   → 通道就绪，可收发数据
%% flowing → 数据流动中
%% closed  → 通道关闭

%% 事件
%% {data, Data}      → 从 SSH 层收到数据
%% {send, Data}      → Ruby 端要发送数据
%% close             → 关闭通道
%% {eof, Reason}     → 收到 EOF
```

**终端通道数据流**：

```erlang
%% ready 状态下收到 SSH 数据
ready({data, Data}, State) ->
    %% 推送到 Ruby 端
    ssh_ipc_gateway:push_event(<<"channel.data">>, #{
        id => State#channel.id,
        data => base64:encode(Data)
    }),
    {next_state, flowing, State};

%% flowing 状态下继续推送
flowing({data, Data}, State) ->
    ssh_ipc_gateway:push_event(<<"channel.data">>, #{
        id => State#channel.id,
        data => base64:encode(Data)
    }),
    {next_state, flowing, State};

%% Ruby 端发送数据
flowing({send, Data}, State) ->
    ssh_connection:send(State#channel.ssh_ref, State#channel.chan_id, Data),
    {next_state, flowing, State}.
```

#### 4.2.4 ssh_auth_engine — 认证引擎

**职责**：管理 SSH 认证流程，支持多种认证方式和回退链。对应 FR-CONN-002。

```erlang
-module(ssh_auth_engine).

%% 认证方式类型
-type auth_method() :: password | publickey | keyboard_interactive.
-type auth_result() :: {ok, connected} | {error, term()} | {next_method, auth_method()}.

%% @doc 按认证链依次尝试
%% AuthChain = [publickey, password, keyboard_interactive]
-spec authenticate(ssh:connection_ref(), [auth_method()], map()) -> auth_result().
authenticate(Ref, [], _Creds) ->
    {error, all_methods_failed};
authenticate(Ref, [Method | Rest], Creds) ->
    case do_auth(Ref, Method, Creds) of
        {ok, connected} ->
            {ok, connected};
        {next_method, _} ->
            authenticate(Ref, Rest, Creds);
        {error, _Reason} ->
            authenticate(Ref, Rest, Creds)
    end.

%% 公钥认证
do_auth(Ref, publickey, #{key_path := Path, passphrase := Pass}) ->
    case ssh:load_host_key(Path, Pass) of
        {ok, Key} ->
            ssh:auth_user(Ref, publickey, Key);
        Error ->
            Error
    end;

%% 密码认证
do_auth(Ref, password, #{password := Pass}) ->
    ssh:auth_user(Ref, password, Pass);

%% 键盘交互（用于 2FA / OTP 场景）
do_auth(Ref, keyboard_interactive, #{handler := Handler}) ->
    ssh:auth_user(Ref, keyboard_interactive, #{
        prompt_fun => fun(Prompts) -> Handler(Prompts) end
    }).
```

#### 4.2.5 ssh_keepalive_mgr — 保活与重连

**对应需求**：FR-CONN-004（保活）和 FR-CONN-005（自动重连）。

```erlang
-module(ssh_keepalive_mgr).
-behaviour(gen_server).

%% 周期巡检所有活跃连接
handle_info(tick, State) ->
    lists:foreach(fun(Conn) ->
        case ssh_conn_worker:get_state(Conn) of
            ready ->
                case send_keepalive(Conn) of
                    ok -> ok;
                    {error, _} ->
                        %% 连续失败计数
                        increment_fail_count(Conn),
                        case get_fail_count(Conn) >= 3 of
                            true ->
                                ssh_conn_worker:trigger_reconnect(Conn);
                            false ->
                                ok
                        end
                end;
            _ -> ok
        end
    end, ssh_conn_pool_sup:all_workers()),
    erlang:send_after(State#state.interval, self(), tick),
    {noreply, State}.
```

**重连策略（指数退避）**：

```
重连间隔 = base_interval * 2 ^ min(attempt, 6), 上限 60s
attempt 0: 5s    attempt 1: 10s   attempt 2: 20s
attempt 3: 40s   attempt 4: 60s   attempt 5: 60s ...
最大尝试 = 配置值（1-10），默认 5
```

#### 4.2.6 ssh_port_fwd — 端口转发

**对应需求**：FR-NET-001。

```erlang
-module(ssh_port_fwd).

%% 三种转发类型
-type fwd_type() :: local | remote | dynamic.

%% 本地转发：本地端口 → SSH隧道 → 远程目标
setup_local(SshRef, LocalPort, RemoteHost, RemotePort) ->
    ssh:tcpip_tunnel(SshRef, {0,0,0,0}, LocalPort, RemoteHost, RemotePort, []).

%% 远程转发：远程端口 → SSH隧道 → 本地目标
setup_remote(SshRef, RemotePort, LocalHost, LocalPort) ->
    ssh:tcpip_tunnel(SshRef, {0,0,0,0}, RemotePort, LocalHost, LocalPort, [{remote, true}]).

%% 动态转发（SOCKS5）：本地端口 → SSH隧道 → 动态目标
setup_dynamic(SshRef, LocalPort) ->
    %% 需要自行实现 SOCKS5 协商 + direct_tcpip
    ssh_dyn_fwd:start(SshRef, LocalPort).
```

#### 4.2.7 ssh_known_hosts — 已知主机管理

**对应需求**：FR-SEC-002。

```erlang
-module(ssh_known_hosts).

%% 存储格式：~/.ssh/known_hosts 兼容，额外维护指纹索引
%% 文件路径可配置，V1.0 使用本地文件，V2.0+ 可选 Ruby 侧加密存储

%% @doc 首次连接时验证主机密钥
verify_host(Host, Port, Key) ->
    case lookup(Host, Port) of
        {ok, StoredKey} when StoredKey == Key ->
            ok;
        {ok, StoredKey} when StoredKey /= Key ->
            {error, host_key_changed};
        not_found ->
            {prompt, Key}  %% 通知 Ruby 弹窗确认
    end.
```

#### 4.2.8 ssh_sftp_engine — SFTP 引擎

**对应需求**：FR-FILE-001、FR-FILE-002、FR-FILE-005。

```erlang
-module(ssh_sftp_engine).

%% 基于 OTP ssh_sftp 通道
-include_lib("kernel/include/file.hrl").

%% 可视化浏览器操作
open_dir(SshRef, Path) ->
    {ok, Handle} = ssh_sftp: opendir(SshRef, Path),
    {ok, list_dir_entries(SshRef, Handle)}.

read_file(SshRef, RemotePath, LocalPath, ProgressFun) ->
    {ok, Handle} = ssh_sftp:open(SshRef, RemotePath, [read, binary]),
    {ok, FileInfo} = ssh_sftp:read_file_info(SshRef, RemotePath),
    transfer(SshRef, Handle, LocalPath, FileInfo#file_info.size, ProgressFun, read).

%% 批量传输
batch_transfer(SshRef, Files, Direction, Concurrency) ->
    %% Concurrency 个并发 channel
    Pool = [open_sftp_channel(SshRef) || _ <- lists:seq(1, Concurrency)],
    Tasks = [{Chan, File, Direction} || File <- Files, Chan <- Pool],
    poolboy:transaction(Tasks, fun(Task) -> do_transfer(Task) end).
```

### 4.3 SSH 算法配置

对照 FR-CONN-001 量化指标：

| 类别 | Erlang 算法配置 |
|------|----------------|
| **密钥交换** | `curve25519-sha256@libssh.org`, `curve25519-sha256`, `ecdh-sha2-nistp256`, `ecdh-sha2-nistp384`, `ecdh-sha2-nistp521`, `diffie-hellman-group16-sha512`, `diffie-hellman-group14-sha256`（≥ 7 种） |
| **公钥** | `ssh-ed25519`, `rsa-sha2-512`, `rsa-sha2-256`, `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521`（≥ 6 种） |
| **对称加密** | `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`, `chacha20-poly1305@openssh.com`, `aes256-ctr`, `aes192-ctr`, `aes128-ctr`（≥ 6 种） |
| **MAC** | `hmac-sha2-256`, `hmac-sha2-512`, `hmac-sha2-256-etm@openssh.com`, `hmac-sha2-512-etm@openssh.com`（≥ 4 种） |

```erlang
%% build_ssh_options/1 生成的算法选项
build_ssh_options(Spec) ->
    [
        {preferred_algorithms, #{
            kex => ['curve25519-sha256@libssh.org',
                    'curve25519-sha256',
                    'ecdh-sha2-nistp256',
                    'ecdh-sha2-nistp384',
                    'ecdh-sha2-nistp521',
                    'diffie-hellman-group16-sha512',
                    'diffie-hellman-group14-sha256'],
            public_key => ['ssh-ed25519',
                           'rsa-sha2-512',
                           'rsa-sha2-256',
                           'ecdsa-sha2-nistp256',
                           'ecdsa-sha2-nistp384',
                           'ecdsa-sha2-nistp521'],
            cipher => ['aes256-gcm@openssh.com',
                       'aes128-gcm@openssh.com',
                       'chacha20-poly1305@openssh.com',
                       'aes256-ctr','aes192-ctr','aes128-ctr'],
            mac => ['hmac-sha2-256',
                    'hmac-sha2-512',
                    'hmac-sha2-256-etm@openssh.com',
                    'hmac-sha2-512-etm@openssh.com']
        }},
        {user, binary_to_list(maps:get(<<"user">>, Spec))},
        {silently_accept_hosts, false},
        {user_dir, binary_to_list(maps:get(<<"key_dir">>, Spec, <<"/tmp">>))}
    ] ++ build_auth_options(Spec).
```

### 4.4 连接池管理

#### 4.4.1 ssh_conn_pool_sup — 连接池 Supervisor

```erlang
-module(ssh_conn_pool_sup).
-behaviour(supervisor).

%% simple_one_for_one 策略，按需创建连接进程
init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 100,
                 period => 60},
    ChildSpec = #{id => ssh_conn_worker,
                  start => {ssh_conn_worker, start_link, []},
                  restart => temporary,
                  shutdown => 10000,
                  type => worker,
                  modules => [ssh_conn_worker]},
    {ok, {SupFlags, [ChildSpec]}}.

%% 获取所有活跃连接
all_workers() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE)].
```

#### 4.4.2 连接 ID 分配

```erlang
%% 短 ID + UUID 后缀，方便调试同时全局唯一
gen_conn_id() ->
    iolist_to_binary(["conn_", integer_to_list(unix_ts()), "_",
                      binary:part(uuid:get_v4(), {0, 8})]).
```

### 4.5 监督树设计

```erlang
%% ssh_core_sup.erl 顶层监督树
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 60},
    Children = [
        #{
            id => ssh_known_hosts,
            start => {ssh_known_hosts, start_link, []},
            restart => permanent,
            type => worker
        },
        #{
            id => ssh_ipc_gateway,
            start => {ssh_ipc_gateway, start_link, [ListenOpts]},
            restart => permanent,
            type => worker
        },
        #{
            id => ssh_conn_pool_sup,
            start => {ssh_conn_pool_sup, start_link, []},
            restart => permanent,
            type => supervisor
        },
        #{
            id => ssh_sftp_engine_sup,
            start => {ssh_sftp_engine_sup, start_link, []},
            restart => permanent,
            type => supervisor
        },
        #{
            id => ssh_keepalive_mgr,
            start => {ssh_keepalive_mgr, start_link, [#{interval => 30000}]},
            restart => permanent,
            type => worker
        }
    ],
    {ok, {SupFlags, Children}}.
```

监督树结构：

```
ssh_core_sup (one_for_one, intensity 10/60s)
├── ssh_known_hosts          (permanent worker)
├── ssh_ipc_gateway          (permanent worker)
├── ssh_conn_pool_sup        (permanent supervisor)
│   └── [动态] ssh_conn_worker × N  (temporary, simple_one_for_one)
│       └── [动态] ssh_channel_fsm  (temporary, 子进程)
├── ssh_sftp_engine_sup      (permanent supervisor)
│   └── [动态] ssh_sftp_session × M (temporary)
└── ssh_keepalive_mgr        (permanent worker)
```

设计要点：
- 连接工作进程设为 `temporary`，进程退出不自动重启，由 Ruby 端决定是否重连——避免反复冲击目标服务器。
- IPC 网关设为 `permanent`，崩溃自动重启不影响已有连接。
- 保活管理器设为 `permanent`，崩溃后重新初始化，重新扫描所有连接。

### 4.6 Erlang Release 打包

使用 Rebar3 release 打包独立可运行的 Erlang 运行时，跨平台预编译。

```
ssh_core/
├── rebar.config
├── apps/
│   └── ssh_core/
│       └── src/  (上述所有 .erl)
└── config/
    ├── vm.args               % VM 启动参数
    └── sys.config            % 应用配置
```

```erlang
%% rebar.config 核心配置
{erl_opts, [debug_info]}.
{deps, [
    {jsx, "3.1.0"}      % JSON 解析
]}.

{relx, [
    {release, {ssh_core, "1.0.0"}, [ssh_core, jsx, runtime_tools]},
    {mode, dev},
    {include_erts, true},   % 打包 ERTS，目标机无需装 Erlang
    {include_src, false},
    {overlay, [
        {mkdir, "{{output_dir}}/logs"},
        {copy, "config/vm.args", "{{output_dir}}/releases/1.0.0/vm.args"},
        {copy, "config/sys.config", "{{output_dir}}/releases/1.0.0/sys.config"}
    ]}
]}.
```

跨平台编译矩阵：

| 平台 | 编译环境 | 产物 |
|------|----------|------|
| Windows x64 | Windows + MSVC + Rebar3 | `ssh_core_1.0.0_windows_x64.zip` |
| macOS x64/ARM64 | macOS + Clang + Rebar3 | `ssh_core_1.0.0_macos_universal.tar.gz` |
| Linux x64 | Ubuntu 20.04 + GCC + Rebar3 | `ssh_core_1.0.0_linux_x64.tar.gz` |

---

## 5 Ruby 调度界面设计

### 5.1 模块结构

Ruby 侧作为 network-infra-utility gem 的一部分，放在 `service/ssh/` 目录。

```
service/ssh/
├── design/
│   ├── SSH连接客户端功能需求文档.md
│   └── 软件设计文档.md              ← 本文档
├── lib/
│   └── network_infra_utility/
│       └── ssh/
│           ├── version.rb            # 版本号
│           ├── client.rb             # 主入口，生命周期管理
│           ├── ipc/
│           │   ├── client.rb         # JSON-RPC 客户端
│           │   ├── protocol.rb       # JSON-RPC 协议封装
│           │   └── event_listener.rb # 异步事件监听
│           ├── session/
│           │   ├── manager.rb        # 会话管理器
│           │   ├── session.rb        # 单个会话对象
│           │   ├── tree.rb           # 会话树形分组
│           │   └── history.rb        # 最近连接与历史
│           ├── terminal/
│           │   ├── emulator.rb       # ANSI/xterm 转义解析
│           │   ├── renderer.rb       # 屏幕渲染
│           │   ├── buffer.rb         # 回滚缓冲区
│           │   ├── theme.rb          # 配色方案
│           │   └── input.rb          # 输入处理
│           ├── file/
│           │   ├── sftp_browser.rb   # SFTP 浏览器
│           │   ├── transfer.rb       # 文件传输管理
│           │   └── watcher.rb        # 远程文件编辑监听
│           ├── security/
│           │   ├── vault.rb          # 凭据加密存储
│           │   ├── key_manager.rb    # 密钥管理
│           │   └── host_key.rb       # 主机密钥校验
│           ├── automation/
│           │   ├── macro_engine.rb   # 登录宏引擎
│           │   ├── batch_exec.rb     # 批量执行
│           │   └── snippet_manager.rb# 代码片段管理
│           ├── network/
│           │   ├── port_forward.rb   # 端口转发规则
│           │   ├── proxy.rb          # 代理配置
│           │   └── diagnostics.rb    # 连接诊断
│           └── config/
│               ├── settings.rb       # 全局设置
│               ├── import_export.rb  # 会话导入导出
│               └── schema.rb         # 配置数据模型
├── bin/
│   └── ssh-client                    # CLI 入口脚本
├── spec/
│   ├── ipc/                          # IPC 通信测试
│   ├── session/                      # 会话管理测试
│   ├── terminal/                     # 终端仿真测试
│   └── ...
└── ssh_client.gemspec
```

### 5.2 核心模块设计

#### 5.2.1 SSH::Client — 主入口

```ruby
# frozen_string_literal: true

require_relative "ipc/client"
require_relative "session/manager"
require_relative "terminal/emulator"
require_relative "security/vault"
require_relative "config/settings"

module NetworkInfraUtility
  module SSH
    # SSH 客户端主入口，管理 Erlang 引擎生命周期与模块协调。
    #
    # 用法：
    #   client = SSH::Client.new
    #   client.start_engine           # 启动 Erlang 后端
    #   session = client.connect(host: "10.0.0.1", user: "admin")
    #   session.terminal.puts("show version")
    class Client
      attr_reader :ipc, :sessions, :vault, :settings

      ENGINE_BINARY = File.expand_path("../ext/ssh_core/bin/ssh_core", __dir__)
      ENGINE_STARTUP_TIMEOUT = 10 # 秒

      def initialize
        @settings = Config::Settings.new
        @vault = Security::Vault.new(@settings.master_password)
        @sessions = Session::Manager.new(self)
        @ipc = IPC::Client.new
        @engine_pid = nil
      end

      # 启动 Erlang SSH 核心引擎，建立 IPC 连接。
      def start_engine
        @engine_pid = spawn_engine
        wait_for_ipcReady(ENGINE_STARTUP_TIMEOUT)
        @ipc.connect(read_ipc_endpoint)
      end

      # 发起 SSH 连接。
      # @param spec [Hash] 连接参数 {host, port, user, auth, jumps, ...}
      # @return [Session] 会话对象
      def connect(spec)
        spec = @vault.resolve_credentials(spec)
        conn_id = @ipc.call("conn.connect", spec)
        @sessions.create(conn_id, spec)
      end

      def stop
        @sessions.disconnect_all
        @ipc.close
        Process.kill("TERM", @engine_pid) if @engine_pid
      end

      private

      def spawn_engine
        log_dir = @settings.log_dir
        FileUtils.mkdir_p(log_dir)
        Process.spawn(
          ENGINE_BINARY, "foreground",
          "--config", @settings.config_path,
          out: File.join(log_dir, "engine.log"),
          err: File.join(log_dir, "engine.err")
        )
      end

      # Erlang 引擎启动时将 IPC 端口写入临时文件，Ruby 读取。
      def read_ipc_endpoint
        endpoint_file = File.join(Dir.tmpdir, "ssh_core_#{Process.uid}.endpoint")
        deadline = Time.now + ENGINE_STARTUP_TIMEOUT
        loop do
          return File.read(endpoint_file).strip if File.exist?(endpoint_file)
          raise "Erlang engine startup timeout" if Time.now > deadline
          sleep 0.1
        end
      end

      def wait_for_ipc_ready(timeout)
        deadline = Time.now + timeout
        loop do
          return if @ipc.connected?
          raise "IPC connection timeout" if Time.now > deadline
          sleep 0.1
        end
      end
    end
  end
end
```

#### 5.2.2 IPC::Client — JSON-RPC 客户端

```ruby
# frozen_string_literal: true

require "json"
require "socket"

module NetworkInfraUtility
  module SSH
    module IPC
      # JSON-RPC 2.0 客户端，与 Erlang SSH 核心引擎通信。
      #
      # 同步调用用 #call，异步事件推送通过 #on_event 注册回调。
      class Client
        attr_reader :connected

        def initialize
          @socket = nil
          @request_id = 0
          @pending = {}        # id => Queue
          @callbacks = {}      # event_name => [Proc]
          @listener_thread = nil
          @connected = false
        end

        # 连接到 Erlang IPC 网关。
        # @param endpoint [String] "unix:/path/to/sock" 或 "tcp://127.0.0.1:port"
        def connect(endpoint)
          @socket = open_socket(endpoint)
          @connected = true
          start_event_listener
        end

        # 同步 RPC 调用。
        # @param method [String] 方法名，如 "conn.connect"
        # @param params [Hash] 参数
        # @param timeout [Integer] 超时秒数
        # @return 调用结果
        # @raise [RPCError] 远程返回错误
        def call(method, params = {}, timeout = 30)
          id = next_request_id
          request = {jsonrpc: "2.0", id: id, method: method, params: params}
          queue = Queue.new
          @pending[id] = queue
          @socket.puts(JSON.generate(request))
          result = queue.pop(timeout: timeout)
          raise RPCError, result[:error] if result[:error]
          result[:result]
        ensure
          @pending.delete(id)
        end

        # 注册异步事件回调。
        # @param event [String] 事件名，如 "channel.data"
        # @param block [Proc] 回调
        def on_event(event, &block)
          (@callbacks[event] ||= []) << block
        end

        def close
          @connected = false
          @listener_thread&.kill
          @socket&.close
        end

        private

        def open_socket(endpoint)
          if endpoint.start_with?("unix:")
            UNIXSocket.new(endpoint.sub("unix:", ""))
          elsif endpoint.start_with?("tcp://")
            uri = URI(endpoint)
            TCPSocket.new(uri.host, uri.port)
          else
            raise ArgumentError, "Unknown endpoint format: #{endpoint}"
          end
        end

        def start_event_listener
          @listener_thread = Thread.new do
            loop do
              line = @socket.gets
              break unless line
              msg = JSON.parse(line, symbolize_names: true)
              handle_message(msg)
            end
          end
        end

        def handle_message(msg)
          if msg[:id] && @pending[msg[:id]]
            # 同步响应
            @pending[msg[:id]] << msg
          elsif msg[:method]
            # 异步推送
            callbacks = @callbacks[msg[:method]]
            callbacks&.each { |cb| cb.call(msg[:params]) }
          end
        end

        def next_request_id
          @request_id += 1
        end
      end

      class RPCError < StandardError; end
    end
  end
end
```

#### 5.2.3 Session::Manager — 会话管理器

```ruby
# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Session
      # 会话管理器，维护全部活跃会话的生命周期。
      # 对应需求 FR-SESS-001 ~ FR-SESS-006。
      class Manager
        include Enumerable

        def initialize(client)
          @client = client
          @sessions = {}        # conn_id => Session
          @tree = Tree.new      # 分组树
          @history = History.new
        end

        # 发起连接并创建会话。
        def connect(spec)
          conn_id = @client.ipc.call("conn.connect", build_connect_spec(spec))
          create(conn_id, spec)
        end

        # 从已有连接 ID 创建会话对象。
        def create(conn_id, spec)
          session = Session.new(@client, conn_id, spec)
          @sessions[conn_id] = session
          @history.record(session)
          session
        end

        def get(conn_id)
          @sessions[conn_id]
        end

        def disconnect(conn_id)
          @sessions[conn_id]&.disconnect
          @sessions.delete(conn_id)
        end

        def disconnect_all
          @sessions.each_value(&:disconnect)
          @sessions.clear
        end

        def each(&block)
          @sessions.each_value(&block)
        end

        # 搜索会话。对应 FR-SESS-004。
        # @param query [String] 搜索关键词
        # @param fields [Array<Symbol>] 搜索字段，默认 :name, :host, :ip, :tags
        def search(query, fields = %i[name host ip tags])
          query_lower = query.downcase
          select do |s|
            fields.any? do |f|
              val = s.send(f)
              val.is_a?(Array) ? val.any? { |v| v.downcase.include?(query_lower) }
                               : val.to_s.downcase.include?(query_lower)
            end
          end
        end

        # 广播输入到多个会话。对应 FR-TERM-008。
        # @param conn_ids [Array<String>] 目标连接 ID
        # @param text [String] 要发送的文本
        def broadcast(conn_ids, text)
          conn_ids.each { |id| @sessions[id]&.terminal&.send(text) }
        end

        attr_reader :tree, :history
      end
    end
  end
end
```

#### 5.2.4 Session — 会话对象

```ruby
# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Session
      # 单个 SSH 会话，封装终端、文件、端口转发等子能力。
      class Session
        attr_reader :conn_id, :spec, :name, :host, :port, :user
        attr_reader :terminal, :file_manager, :port_forward
        attr_accessor :tags, :group

        # 会话状态
        STATUSES = %i[connecting authenticating connected disconnected error].freeze

        def initialize(client, conn_id, spec)
          @client = client
          @conn_id = conn_id
          @spec = spec
          @name = spec[:name] || "#{spec[:user]}@#{spec[:host]}"
          @host = spec[:host]
          @port = spec[:port] || 22
          @user = spec[:user]
          @tags = spec[:tags] || []
          @group = spec[:group]
          @status = :connected
          @terminal = nil
          @file_manager = nil
          @port_forward = nil
        end

        # 打开终端通道。
        def open_terminal(term_type = "xterm-256color", cols = 80, rows = 24)
          channel_id = @client.ipc.call("channel.open", {
            conn_id: @conn_id,
            type: "shell",
            term: term_type,
            cols: cols,
            rows: rows
          })
          @terminal = Terminal::Emulator.new(@client, @conn_id, channel_id, cols, rows)
          @terminal
        end

        # 打开 SFTP 文件管理器。对应 FR-FILE-001。
        def open_file_manager
          sftp_id = @client.ipc.call("sftp.open", {conn_id: @conn_id})
          @file_manager = File::SftpBrowser.new(@client, sftp_id)
          @file_manager
        end

        # 添加端口转发规则。对应 FR-NET-001。
        def add_port_forward(type, local_port, remote_host, remote_port)
          rule_id = @client.ipc.call("portfwd.add", {
            conn_id: @conn_id,
            type: type.to_s,
            local_port: local_port,
            remote_host: remote_host,
            remote_port: remote_port
          })
          (@port_forward ||= []) << {id: rule_id, type: type, local_port: local_port,
                                      remote_host: remote_host, remote_port: remote_port}
          rule_id
        end

        def disconnect
          @client.ipc.call("conn.disconnect", {id: @conn_id})
          @status = :disconnected
        end

        def connected?
          @status == :connected
        end
      end
    end
  end
end
```

#### 5.2.5 Terminal::Emulator — 终端仿真器

```ruby
# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Terminal
      # ANSI/xterm 转义序列解析与终端状态维护。
      # 对应需求 FR-TERM-001、FR-TERM-002、FR-TERM-007、FR-TERM-010。
      class Emulator
        attr_reader :cols, :rows, :cursor_x, :cursor_y, :buffer, :theme

        # 终端类型映射
        TERM_TYPES = {
          "xterm-256color" => {colors: 256, truecolor: true},
          "vt100"          => {colors: 16, truecolor: false},
          "vt220"          => {colors: 16, truecolor: false}
        }.freeze

        def initialize(client, conn_id, channel_id, cols, rows)
          @client = client
          @conn_id = conn_id
          @channel_id = channel_id
          @cols = cols
          @rows = rows
          @cursor_x = 0
          @cursor_y = 0
          @buffer = Buffer.new(rows, max_lines: 10000)   # FR-TERM-007
          @theme = Theme.default
          @parser = AnsiParser.new(@buffer, @theme)

          # 注册 SSH 数据推送回调
          @client.ipc.on_event("channel.data") do |params|
            next unless params[:id] == @channel_id
            data = Base64.decode64(params[:data])
            @parser.feed(data)
          end
        end

        # 发送数据到 SSH 通道。
        def send(data)
          @client.ipc.call("channel.send", {
            id: @channel_id,
            data: Base64.encode64(data)
          })
        end

        # 发送一行（带换行）。
        def puts(text)
          send("#{text}\r")
        end

        # 窗口大小变更。
        def resize(cols, rows)
          @cols = cols
          @rows = rows
          @buffer.resize(cols, rows)
          @client.ipc.call("channel.window_change", {
            id: @channel_id, cols: cols, rows: rows
          })
        end

        # 设置配色主题。对应 FR-TERM-002。
        def theme=(theme_name)
          @theme = Theme.load(theme_name)
        end

        # 搜索缓冲区内容。对应 FR-TERM-005、FR-TERM-007。
        # @param pattern [String] 正则或关键词
        # @return [Array<Match>] 匹配结果
        def search(pattern)
          @buffer.search(pattern)
        end

        # 导出缓冲区内容为文本。
        def export(path = nil)
          text = @buffer.to_text
          File.write(path, text) if path
          text
        end
      end
    end
  end
end
```

#### 5.2.6 Terminal::Buffer — 回滚缓冲区

```ruby
# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Terminal
      # 终端回滚缓冲区，支持大容量历史和快速搜索。
      # 对应需求 FR-TERM-007：默认 ≥ 10000 行，可配置 1000–100000。
      class Buffer
        attr_reader :rows, :cols, :scrollback_lines

        def initialize(rows, max_lines: 10000)
          @rows = rows
          @cols = cols || 80
          @scrollback_lines = max_lines
          @lines = []           # 回滚行（已滚出屏幕）
          @screen = []          # 当前屏幕行
          @rows.times { @screen << Line.new(@cols) }
        end

        # 写入字符到当前光标位置（由 AnsiParser 调用）。
        def write_char(char, x, y, style = {})
          line = @screen[y] || (@screen[y] = Line.new(@cols))
          line.write_char(char, x, style)
        end

        # 换行——将屏幕首行移入回滚区。
        def newline
          @lines << @screen.shift
          @screen << Line.new(@cols)
          trim_scrollback
        end

        # 回滚行数 + 屏幕行数。
        def total_lines
          @lines.size + @screen.size
        end

        # 搜索全部内容（回滚 + 屏幕）。
        # @param pattern [String] 正则表达式
        # @return [Array<Match>]
        def search(pattern)
          regex = Regexp.new(pattern)
          matches = []
          all_lines.each_with_index do |line, idx|
            line.to_s.scan(regex) do
              m = Regexp.last_match
              matches << Match.new(line: idx, start: m.begin(0), end: m.end(0), text: m[0])
            end
          end
          matches
        end

        # 导出纯文本。
        def to_text
          all_lines.map(&:to_s).join("\n")
        end

        def resize(cols, rows)
          @cols = cols
          if rows > @rows
            (rows - @rows).times { @screen << Line.new(@cols) }
          elsif rows < @rows
            (@rows - rows).times { @lines << @screen.shift }
            trim_scrollback
          end
          @rows = rows
        end

        private

        def trim_scrollback
          while @lines.size > @scrollback_lines
            @lines.shift
          end
        end

        def all_lines
          @lines + @screen
        end
      end

      # 一行字符，每个字符附带样式信息。
      class Line
        attr_reader :cells

        def initialize(cols)
          @cells = Array.new(cols) { Cell.new }
        end

        def write_char(char, x, style = {})
          @cells[x] = Cell.new(char, style) if x < @cells.size
        end

        def to_s
          @cells.map(&:char).join.rstrip
        end
      end

      # 单个字符单元。
      Cell = Struct.new(:char, :style) do
        def initialize(char = " ", style = {})
          super
        end
      end

      # 搜索匹配结果。
      Match = Struct.new(:line, :start, :end, :text)
    end
  end
end
```

#### 5.2.7 Security::Vault — 凭据加密存储

```ruby
# frozen_string_literal: true

require "openssl"
require "yaml"
require "securerandom"

module NetworkInfraUtility
  module SSH
    module Security
      # 凭据加密存储，AES-256-GCM。
      # 对应需求 FR-SEC-001。
      class Vault
        PBKDF2_ITERATIONS = 100_000
        SALT_LENGTH       = 32
        KEY_LENGTH        = 32    # AES-256
        NONCE_LENGTH      = 12    # GCM nonce

        def initialize(master_password)
          @master_password = master_password
          @cache = {}  # 解密后的凭据缓存
        end

        # 加密凭据并存储到配置文件。
        # @param key [String] 凭据标识，如 "session_001_password"
        # @param value [String] 明文凭据
        def store(key, value)
          salt = SecureRandom.random_bytes(SALT_LENGTH)
          derived_key = derive_key(@master_password, salt)
          nonce = SecureRandom.random_bytes(NONCE_LENGTH)
          cipher = OpenSSL::Cipher::AES.new(256, :GCM)
          cipher.encrypt
          cipher.key = derived_key
          cipher.iv = nonce
          encrypted = cipher.update(value) + cipher.final
          tag = cipher.auth_tag

          entry = {
            salt: Base64.encode64(salt),
            nonce: Base64.encode64(nonce),
            tag: Base64.encode64(tag),
            data: Base64.encode64(encrypted)
          }
          write_to_store(key, entry)
        end

        # 读取并解密凭据。
        # @param key [String] 凭据标识
        # @return [String] 明文凭据
        def load(key)
          return @cache[key] if @cache[key]

          entry = read_from_store(key)
          return nil unless entry

          salt = Base64.decode64(entry[:salt])
          derived_key = derive_key(@master_password, salt)
          nonce = Base64.decode64(entry[:nonce])
          tag = Base64.decode64(entry[:tag])
          encrypted = Base64.decode64(entry[:data])

          cipher = OpenSSL::Cipher::AES.new(256, :GCM)
          cipher.decrypt
          cipher.key = derived_key
          cipher.iv = nonce
          cipher.auth_tag = tag

          plaintext = cipher.update(encrypted) + cipher.final
          @cache[key] = plaintext
          plaintext
        end

        # 在连接规格中解析凭据引用。
        # spec 中 password 可能是 "~vault:session_001_password"
        def resolve_credentials(spec)
          spec.each do |k, v|
            if v.is_a?(String) && v.start_with?("~vault:")
              spec[k] = load(v.sub("~vault:", ""))
            end
          end
          spec
        end

        private

        def derive_key(password, salt)
          OpenSSL::PKCS5.pbkdf2_hmac(password, salt, PBKDF2_ITERATIONS, KEY_LENGTH, "sha256")
        end

        def write_to_store(key, entry)
          store = load_store
          store[key] = entry
          File.write(store_path, YAML.dump(store))
          set_file_permissions
        end

        def read_from_store(key)
          load_store[key]
        end

        def load_store
          return {} unless File.exist?(store_path)
          YAML.load_file(store_path)
        end

        def store_path
          File.join(Dir.home, ".network-infra-utility", "vault.yml")
        end

        def set_file_permissions
          path = store_path
          if RUBY_PLATFORM.include?("mswin") || RUBY_PLATFORM.include?("mingw")
            # Windows: ACL 限制当前用户
            system("icacls \"#{path}\" /inheritance:r /grant:r \"#{ENV['USERNAME']}:R\"")
          else
            File.chmod(0o600, path)
          end
        end
      end
    end
  end
end
```

#### 5.2.8 Automation::MacroEngine — 登录宏引擎

```ruby
# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Automation
      # 登录宏引擎，连接后自动执行预设命令序列。
      # 对应需求 FR-AUTO-001。
      class MacroEngine
        # 单步定义
        Step = Struct.new(:action, :wait_pattern, :delay, :on_fail, keyword_init: true)

        def initialize(session)
          @session = session
          @steps = []
          @running = false
          @abort = false
        end

        # 添加一步。
        # @param action [String] 要发送的命令
        # @param wait_pattern [String, Regexp] 等待匹配的文本/正则
        # @param delay [Float] 发送前延迟（秒）
        # @param on_fail [:continue, :abort, :ask] 失败时行为
        def add_step(action:, wait_pattern: nil, delay: 0, on_fail: :continue)
          raise "Too many steps (max 50)" if @steps.size >= 50
          @steps << Step.new(action: action, wait_pattern: wait_pattern,
                             delay: delay, on_fail: on_fail)
        end

        # 执行宏。
        def run(on_progress: nil)
          @running = true
          @steps.each_with_index do |step, i|
            break if @abort
            on_progress&.call(step, i + 1, @steps.size)
            sleep step.delay if step.delay > 0
            @session.terminal.send(step.action)
            if step.wait_pattern
              result = wait_for(step.wait_pattern, timeout: 30)
              handle_step_result(step, result)
            end
          end
        ensure
          @running = false
        end

        def abort
          @abort = true
        end

        private

        def wait_for(pattern, timeout:)
          regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern))
          deadline = Time.now + timeout
          accumulated = ""
          loop do
            return :matched if accumulated.match?(regex)
            return :timeout if Time.now > deadline
            line = @session.terminal.buffer.last_line&.to_s || ""
            accumulated << line + "\n"
            sleep 0.1
          end
        end

        def handle_step_result(step, result)
          case [result, step.on_fail]
          when [:matched, any], [:timeout, :continue]
            # 继续
          when [:timeout, :abort]
            @abort = true
          when [:timeout, :ask]
            # 询问用户——CLI 版输出提示，TUI 版弹窗
            yield(:ask, step) if block_given?
          end
        end
      end
    end
  end
end
```

#### 5.2.9 Automation::BatchExec — 批量执行

```ruby
# frozen_string_literal: true

module NetworkInfraUtility
  module SSH
    module Automation
      # 批量命令执行，多会话同时下发。
      # 对应需求 FR-AUTO-003。
      class BatchExec
        # 执行模式
        PARALLEL = :parallel
        SERIAL   = :serial

        def initialize(client)
          @client = client
        end

        # 批量执行命令。
        # @param sessions [Array<Session>] 目标会话列表
        # @param command [String] 要执行的命令
        # @param mode [:parallel, :serial] 执行模式
        # @param timeout [Integer] 单会话超时秒数
        # @return [Hash<conn_id => Result>]
        def execute(sessions, command, mode: PARALLEL, timeout: 30)
          if mode == PARALLEL
            execute_parallel(sessions, command, timeout)
          else
            execute_serial(sessions, command, timeout)
          end
        end

        private

        def execute_parallel(sessions, command, timeout)
          threads = sessions.map do |s|
            Thread.new { [s.conn_id, run_on_session(s, command, timeout)] }
          end
          results = threads.map(&:value)
          results.to_h
        end

        def execute_serial(sessions, command, timeout)
          sessions.map do |s|
            [s.conn_id, run_on_session(s, command, timeout)]
          end.to_h
        end

        def run_on_session(session, command, timeout)
          chan_id = @client.ipc.call("channel.open", {
            conn_id: session.conn_id, type: "exec", command: command
          })
          collector = ResultCollector.new
          @client.ipc.on_event("channel.data") do |params|
            next unless params[:id] == chan_id
            collector << Base64.decode64(params[:data])
          end
          collector.wait(timeout)
        end
      end

      # 结果收集器，收集单个会话的命令输出。
      ResultCollector = Struct.new(:output, :done) do
        def initialize
          self.output = +""
          self.done = false
          @mutex = Mutex.new
          @cv = ConditionVariable.new
        end

        def <<(data)
          @mutex.synchronize { output << data }
        end

        def wait(timeout)
          deadline = Time.now + timeout
          @mutex.synchronize do
            @cv.wait(@mutex, [deadline - Time.now, 0].max) until done || Time.now >= deadline
          end
          output.to_s
        end

        def finish!
          @mutex.synchronize do
            self.done = true
            @cv.broadcast
          end
        end
      end
    end
  end
end
```

### 5.3 CLI 入口设计

V1.0 先交付交互式 CLI，后续升级为 TUI 多面板。

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "thor"
require_relative "../lib/network_infra_utility/ssh/client"

module NetworkInfraUtility
  module SSH
    class CLI < Thor
      desc "connect HOST", "连接到 SSH 服务器"
      option :user, aliases: "-u", required: true
      option :port, aliases: "-p", type: :numeric, default: 22
      option :key,  aliases: "-i", desc: "私钥文件路径"
      option :jump, aliases: "-J", desc: "跳板机 (user@host:port)"
      option :name, desc: "会话名称"

      def connect(host)
        client = Client.new
        client.start_engine

        spec = {
          host: host, port: options[:port], user: options[:user],
          name: options[:name]
        }
        spec[:key_path] = options[:key] if options[:key]
        spec[:jumps] = parse_jumps(options[:jump]) if options[:jump]

        session = client.connect(spec)
        terminal = session.open_terminal

        # 进入交互模式
        start_interactive(session, terminal)
      rescue => e
        STDERR.puts "Error: #{e.message}"
        exit 1
      ensure
        client&.stop
      end

      desc "batch FILE", "批量在多个会话上执行命令"
      option :command, aliases: "-c", required: true
      option :serial, type: :boolean, default: false

      def batch(file)
        # 从文件读取会话列表，批量执行
        sessions = load_sessions_from_file(file)
        client = Client.new
        client.start_engine
        sessions.map! { |spec| client.connect(spec).open_terminal }

        batch = Automation::BatchExec.new(client)
        results = batch.execute(sessions, options[:command],
                                mode: options[:serial] ? :serial : :parallel)
        print_results(results)
      end

      private

      def start_interactive(session, terminal)
        # V1.0: 简单的读-发-收循环
        # V2.0: 升级为 curses 多面板 TUI
        loop do
          line = STDIN.gets
          break if line.nil? || line.chomp == "exit"
          terminal.puts(line.chomp)
        end
      end

      def parse_jumps(jump_str)
        jump_str.split(",").map do |j|
          if j =~ /\A([^@]+)@([^:]+):(\d+)\z/
            {user: $1, host: $2, port: $3.to_i}
          else
            raise "Invalid jump format: #{j} (expected user@host:port)"
          end
        end
      end
    end
  end
end

NetworkInfraUtility::SSH::CLI.start(ARGV)
```

---

## 6 通信协议设计

### 6.1 JSON-RPC 2.0 消息格式

Erlang 与 Ruby 之间所有通信均使用 JSON-RPC 2.0，每条消息以换行符 `\n` 分隔。

#### 6.1.1 请求

```json
{"jsonrpc":"2.0","id":1,"method":"conn.connect","params":{"host":"10.0.0.1","port":22,"user":"admin","auth":{"type":"password","value":"~vault:sec_001"}}}
```

#### 6.1.2 响应

```json
{"jsonrpc":"2.0","id":1,"result":{"conn_id":"conn_1691000000_a1b2c3d4","fingerprint":"SHA256:AbC..."}}
```

#### 6.1.3 错误响应

```json
{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Authentication failed","data":{"reason":"publickey rejected"}}}
```

#### 6.1.4 异步推送（无 id）

```json
{"jsonrpc":"2.0","method":"channel.data","params":{"id":"ch_001","data":"dGVzdA=="}}
```

### 6.2 错误码定义

| 错误码 | 含义 | 说明 |
|--------|------|------|
| -32700 | Parse error | JSON 解析失败 |
| -32600 | Invalid Request | 请求格式不合法 |
| -32601 | Method not found | 方法未注册 |
| -32602 | Invalid params | 参数校验失败 |
| -32603 | Internal error | Erlang 内部异常 |
| -32001 | Connection error | SSH 连接失败 |
| -32002 | Authentication error | 认证失败 |
| -32003 | Channel error | 通道操作失败 |
| -32004 | Host key error | 主机密钥校验失败 |
| -32005 | Timeout | 操作超时 |
| -32006 | SFTP error | SFTP 操作失败 |
| -32007 | Port forward error | 端口转发失败 |

### 6.3 RPC 方法清单

#### 6.3.1 连接管理

| 方法 | 方向 | 参数 | 返回 | 对应需求 |
|------|------|------|------|----------|
| `conn.connect` | Ruby→Erlang | `{host, port, user, auth, jumps?, proxy?, keepalive?}` | `{conn_id, fingerprint}` | FR-CONN-001/002/003/004 |
| `conn.disconnect` | Ruby→Erlang | `{id}` | `{ok}` | — |
| `conn.list` | Ruby→Erlang | `{}` | `[{conn_id, host, state}]` | — |
| `conn.reconnect` | Ruby→Erlang | `{id}` | `{conn_id}` | FR-CONN-005 |
| `conn.ready` | Erlang→Ruby | `{conn_id}` | — | 连接就绪通知 |
| `conn.closed` | Erlang→Ruby | `{conn_id, reason}` | — | 连接断开通知 |

#### 6.3.2 通道管理

| 方法 | 方向 | 参数 | 返回 | 对应需求 |
|------|------|------|------|----------|
| `channel.open` | Ruby→Erlang | `{conn_id, type, term?, cols?, rows?, command?}` | `{channel_id}` | — |
| `channel.send` | Ruby→Erlang | `{id, data}` | `{ok}` | — |
| `channel.close` | Ruby→Erlang | `{id}` | `{ok}` | — |
| `channel.window_change` | Ruby→Erlang | `{id, cols, rows}` | `{ok}` | FR-TERM-001 |
| `channel.data` | Erlang→Ruby | `{id, data}` | — | 终端数据推送 |
| `channel.eof` | Erlang→Ruby | `{id, reason}` | — | 通道关闭通知 |

#### 6.3.3 认证

| 方法 | 方向 | 参数 | 返回 | 对应需求 |
|------|------|------|------|----------|
| `auth.prompt` | Erlang→Ruby | `{conn_id, prompts[]}` | `{responses[]}` | FR-CONN-002 键盘交互 |
| `hostkey.verify` | Erlang→Ruby | `{conn_id, host, port, fingerprint, key_type}` | `{accept/once/reject}` | FR-SEC-002 |

#### 6.3.4 端口转发

| 方法 | 方向 | 参数 | 返回 | 对应需求 |
|------|------|------|------|----------|
| `portfwd.add` | Ruby→Erlang | `{conn_id, type, local_port, remote_host, remote_port}` | `{rule_id}` | FR-NET-001 |
| `portfwd.remove` | Ruby→Erlang | `{conn_id, rule_id}` | `{ok}` | FR-NET-001 |
| `portfwd.list` | Ruby→Erlang | `{conn_id}` | `[{rule_id, type, ...}]` | FR-NET-001 |

#### 6.3.5 SFTP

| 方法 | 方向 | 参数 | 返回 | 对应需求 |
|------|------|------|------|----------|
| `sftp.open` | Ruby→Erlang | `{conn_id}` | `{sftp_id}` | FR-FILE-001 |
| `sftp.list_dir` | Ruby→Erlang | `{sftp_id, path}` | `{entries[{name, type, size, mtime, perms}]}` | FR-FILE-001 |
| `sftp.download` | Ruby→Erlang | `{sftp_id, remote, local}` | `{ok, transferred}` | FR-FILE-001 |
| `sftp.upload` | Ruby→Erlang | `{sftp_id, local, remote}` | `{ok, transferred}` | FR-FILE-001 |
| `sftp.mkdir` | Ruby→Erlang | `{sftp_id, path}` | `{ok}` | FR-FILE-001 |
| `sftp.remove` | Ruby→Erlang | `{sftp_id, path}` | `{ok}` | FR-FILE-001 |
| `sftp.stat` | Ruby→Erlang | `{sftp_id, path}` | `{size, mtime, perms, type}` | FR-FILE-001 |
| `sftp.progress` | Erlang→Ruby | `{sftp_id, transferred, total, speed}` | — | 传输进度推送 |

#### 6.3.6 管理与诊断

| 方法 | 方向 | 参数 | 返回 | 对应需求 |
|------|------|------|------|----------|
| `engine.ping` | Ruby→Erlang | `{}` | `{ok, timestamp}` | 心跳检测 |
| `engine.stats` | Ruby→Erlang | `{}` | `{connections, channels, uptime, memory}` | NFR-PERF-005/006 |
| `engine.shutdown` | Ruby→Erlang | `{}` | `{ok}` | 优雅关闭 |

### 6.4 数据编码约定

| 数据类型 | 编码方式 | 说明 |
|----------|----------|------|
| 终端原始字节 | Base64 | 二进制安全，跨语言无坑 |
| 文件路径 | UTF-8 字符串 | 直接传递 |
| 时间戳 | Unix 毫秒整数 | 避免时区问题 |
| 密钥指纹 | 字符串 `SHA256:base64` | 与 OpenSSH 一致 |
| 认证凭据 | `~vault:<key>` 引用 | Ruby 解析后替换为明文，仅在 IPC 中短暂传输 |

### 6.5 IPC 性能保障

| 指标 | 目标 | 措施 |
|------|------|------|
| 单次 RPC 往返延迟 | ≤ 1ms（Unix Socket） | 本地 IPC，无网络开销 |
| 终端数据推送延迟 | ≤ 5ms | base64 编解码 + JSON 序列化约 0.2ms |
| 消息吞吐 | ≥ 10000 msg/s | Erlang 端无需序列化整行，直接 `jsx:encode` |
| 大数据流传输 | 不阻塞小消息 | SFTP 数据使用独立 channel，不与终端复用 |

---

## 7 数据模型设计

### 7.1 会话配置模型

```yaml
# ~/.network-infra-utility/sessions.yml
version: 1
groups:
  - id: grp_datacenter_a
    name: "A机房"
    parent: null
    groups:
      - id: grp_datacenter_a_core
        name: "核心交换"
        parent: grp_datacenter_a
sessions:
  - id: sess_001
    name: "核心交换机-01"
    group: grp_datacenter_a_core
    host: "10.0.0.1"
    port: 22
    user: "admin"
    auth:
      type: publickey
      key_path: "~/.ssh/id_ed25519"
      passphrase_ref: "~vault:sess_001_key_pass"
    tags: ["core", "cisco"]
    terminal:
      type: "xterm-256color"
      theme: "solarized-dark"
      font: "JetBrains Mono"
      font_size: 14
      scrollback: 10000
      encoding: "utf-8"
    keepalive:
      interval: 30
      count_max: 3
    proxy:
      type: "socks5"
      host: "127.0.0.1"
      port: 1080
    jumps:
      - host: "172.16.0.1"
        port: 22
        user: "jump"
        auth:
          type: password
          password_ref: "~vault:jump_001_pass"
    port_forwards:
      - type: local
        local_port: 8080
        remote_host: "127.0.0.1"
        remote_port: 80
        enabled: true
    macro:
      enabled: true
      steps:
        - action: "terminal length 0"
          wait_pattern: "#"
          delay: 1
        - action: "show version"
          wait_pattern: "#"
          delay: 0
    log:
      enabled: true
      path: "~/ssh-logs/sess_001"
      max_size: 100MB
      rotate: 10
```

### 7.2 Erlang 内部状态模型

```erlang
%% 连接规格映射
-type connect_spec() :: #{
    host => binary(),
    port => pos_integer(),
    user => binary(),
    auth => #{
        type => password | publickey | keyboard_interactive,
        password => binary() | undefined,
        key_path => binary() | undefined,
        passphrase => binary() | undefined,
        chain => [atom()]  %% 认证回退链
    },
    jumps => [connect_spec()] | undefined,
    proxy => #{
        type => http | socks5,
        host => binary(),
        port => pos_integer(),
        auth => map() | undefined
    } | undefined,
    keepalive => #{
        interval => pos_integer(),
        count_max => pos_integer()
    },
    algorithms => map() | undefined   %% 可选自定义算法列表
}.
```

### 7.3 配置文件布局

```
~/.network-infra-utility/
├── settings.yml          # 全局设置（主题、快捷键、默认终端参数）
├── sessions.yml          # 会话与分组配置
├── vault.yml             # 加密凭据存储（权限 600）
├── known_hosts.yml       # 已知主机密钥
├── snippets/             # 代码片段库
│   ├── network.yml
│   └── linux.yml
├── themes/               # 自定义主题
│   └── custom.yml
├── macros/               # 宏脚本
│   └── cisco_login.yml
└── logs/                 # 会话日志
    ├── sess_001/
    │   ├── 20260802_153000.log
    │   └── 20260802_160000.log
    └── ...
```

### 7.4 关键数据结构对比

| 数据 | Ruby 侧表示 | Erlang 侧表示 | 持久化位置 |
|------|------------|---------------|-----------|
| 会话配置 | `Session` 对象 | 不持久化（每次 connect 传入） | `sessions.yml` |
| 凭据 | Vault 引用 `~vault:key` | 运行时明文（仅 IPC 传输） | `vault.yml`（加密） |
| 已知主机 | `Hash<host, key>` | ETS 表 | `known_hosts.yml` |
| 代码片段 | `Array<Snippet>` | 不管理 | `snippets/*.yml` |
| 会话日志 | 文件句柄 | 不持久化 | `logs/` 目录 |
| 终端缓冲 | `Buffer` 对象 | 不持久化 | 内存中 |

---

## 8 安全设计

### 8.1 安全架构总览

```
┌─ 用户 ────────────────────────────────────────┐
│  主密码（不存储，仅内存）                         │
└──────┬────────────────────────────────────────┘
       │ PBKDF2/Argon2 派生
       ▼
┌─ Ruby Vault 层 ───────────────────────────────┐
│  AES-256-GCM 加密存储 vault.yml                 │
│  凭据仅在 connect 时解密，经 IPC 传入 Erlang     │
└──────┬────────────────────────────────────────┘
       │ JSON-RPC (本地 IPC, 不经网络)
       ▼
┌─ Erlang 引擎层 ───────────────────────────────┐
│  认证凭据仅在 ssh:connect 调用期间存活           │
│  连接建立后凭据从内存清除                         │
│  SSH 加密由 OTP ssh 应用保证                     │
└──────┬────────────────────────────────────────┘
       │ SSH 加密通道
       ▼
┌─ 远程 SSH 服务器 ─────────────────────────────┐
└────────────────────────────────────────────────┘
```

### 8.2 凭据安全 — FR-SEC-001

| 环节 | 措施 | 验收标准 |
|------|------|----------|
| 主密码存储 | PBKDF2-SHA256 迭代 ≥ 100000 次，仅存哈希 | NFR-SEC-002 |
| 凭据存储 | AES-256-GCM 加密，随机 salt + nonce + auth_tag | FR-SEC-001 ①② |
| 配置文件 | vault.yml 权限 600（Unix）/ ACL 限制（Windows） | FR-SEC-001 ④ |
| 内存安全 | 凭据解密后仅存在连接建立期间，连接成功后 GC 清除 | NFR-SEC-001 |
| 日志安全 | 日志中不记录明文凭据，配置中用 `~vault:` 引用替代替 | NFR-SEC-001 |
| IPC 传输 | Unix Socket 本地通信，不经网络；Windows TCP 仅绑定 127.0.0.1 | — |

### 8.3 主机密钥验证 — FR-SEC-002

```erlang
%% 首次连接流程
1. Erlang 连接时获取服务器公钥指纹
2. 调用 hostkey.verify 推送到 Ruby
3. Ruby 查询 known_hosts:
   a. 已知且匹配 → 自动接受
   b. 已知但不匹配 → 弹窗告警 "主机密钥变更！可能存在中间人攻击"
   c. 未知 → 弹窗确认 "首次连接，指纹 SHA256:xxx，是否信任？"
4. 用户确认后 Ruby 回复 accept/reject
5. accept 后 Ruby 将指纹写入 known_hosts.yml
```

### 8.4 IPC 认证

| 步骤 | 机制 |
|------|------|
| 1. Erlang 引擎启动 | 生成随机 32 字节令牌，与监听端点一起写入临时文件 |
| 2. 文件权限 | 临时文件权限设为 600，路径包含 UID 防止其他用户读取 |
| 3. Ruby 读取 | 读取端点和令牌 |
| 4. 首次 RPC | Ruby 在 params 中携带 `auth_token` |
| 5. Erlang 校验 | 匹配后绑定 TCP 连接，后续请求无需再传 |
| 6. 连接关闭 | 令牌失效，防止重放 |

### 8.5 依赖安全 — NFR-SEC-003

| 依赖 | 来源 | 安全策略 |
|------|------|----------|
| Erlang/OTP ssh | OTP 内置 | 跟随 OTP 安全更新 |
| jsx | hex.pm | 发布前 `rebar3 audit` 检查 CVE |
| Ruby stdlib | 内置 | 跟随 Ruby 安全更新 |
| thor | RubyGems | `bundle audit` 检查 |

---

## 9 需求映射矩阵

### 9.1 功能需求映射

下表将每条功能需求映射到实现层和核心模块：

| 需求编号 | 功能名称 | Erlang 模块 | Ruby 模块 | 优先级 | 版本 |
|----------|----------|-------------|-----------|--------|------|
| FR-CONN-001 | SSH2 协议支持 | ssh_conn_worker + OTP ssh | IPC::Client | P0 | V1.0 |
| FR-CONN-002 | 多认证方式 | ssh_auth_engine | Security::Vault | P0 | V1.0 |
| FR-CONN-003 | 跳板机跳转 | ssh_jump_chain | Session::Manager | P0 | V1.0 |
| FR-CONN-004 | 连接保活 | ssh_keepalive_mgr | Config::Settings | P0 | V1.0 |
| FR-CONN-005 | 自动重连 | ssh_conn_worker | Session::Manager | P1 | V2.0 |
| FR-CONN-006 | 多协议支持 | 扩展 conn_worker | Session::Manager | P1 | V2.0 |
| FR-CONN-007 | MOSH 支持 | 新 mosh_engine | — | P2 | V3.0 |
| FR-SESS-001 | 标签页与窗口拆分 | — | Session::Manager + TUI | P0 | V1.0 |
| FR-SESS-002 | 会话分组与树形管理 | — | Session::Tree | P0 | V1.0 |
| FR-SESS-003 | 会话导入导出 | — | Config::ImportExport | P1 | V2.0 |
| FR-SESS-004 | 会话搜索 | — | Session::Manager#search | P1 | V2.0 |
| FR-SESS-005 | 最近连接列表 | — | Session::History | P1 | V2.0 |
| FR-SESS-006 | 会话锁屏 | — | TUI 层 | P2 | V3.0 |
| FR-FILE-001 | SFTP 可视化浏览器 | ssh_sftp_engine | File::SftpBrowser | P0 | V1.0 |
| FR-FILE-002 | SCP 命令传输 | ssh_sftp_engine | File::Transfer | P0 | V1.0 |
| FR-FILE-003 | 双面板同步浏览 | ssh_channel_fsm | File::SftpBrowser | P1 | V2.0 |
| FR-FILE-004 | ZMODEM | ssh_channel_fsm | File::Zmodem | P1 | V2.0 |
| FR-FILE-005 | 批量文件传输 | ssh_sftp_engine | File::Transfer | P1 | V2.0 |
| FR-FILE-006 | 远程文件编辑 | — | File::Watcher | P2 | V3.0 |
| FR-SEC-001 | 凭据加密存储 | — | Security::Vault | P0 | V1.0 |
| FR-SEC-002 | 主机密钥验证 | ssh_known_hosts | Security::HostKey | P0 | V1.0 |
| FR-SEC-003 | SSH Agent 集成 | ssh_auth_engine | Security::KeyManager | P1 | V2.0 |
| FR-SEC-004 | 密钥对生成 | — | Security::KeyManager | P1 | V2.0 |
| FR-SEC-005 | 凭据同步加密 | — | Security::Vault | P2 | V3.0 |
| FR-SEC-006 | 2FA/MFA 支持 | ssh_auth_engine | Security::OTP | P2 | V3.0 |
| FR-NET-001 | 端口转发 | ssh_port_fwd | Network::PortForward | P0 | V1.0 |
| FR-NET-002 | SOCKS5/HTTP 代理 | ssh_conn_worker | Network::Proxy | P1 | V2.0 |
| FR-NET-003 | X11 转发 | ssh_port_fwd | — | P2 | V3.0 |
| FR-NET-004 | 连接诊断 | — | Network::Diagnostics | P1 | V2.0 |
| FR-NET-005 | 流量统计 | ssh_conn_worker | Network::Stats | P2 | V3.0 |
| FR-TERM-001 | 终端仿真 | ssh_channel_fsm | Terminal::Emulator | P0 | V1.0 |
| FR-TERM-002 | 主题与配色 | — | Terminal::Theme | P0 | V1.0 |
| FR-TERM-003 | 字体配置 | — | Terminal::Renderer | P0 | V1.0 |
| FR-TERM-004 | 快捷键定制 | — | TUI 层 | P1 | V2.0 |
| FR-TERM-005 | 搜索与高亮 | — | Terminal::Buffer | P1 | V2.0 |
| FR-TERM-006 | 日志记录 | ssh_channel_fsm | Terminal::Logger | P0 | V1.0 |
| FR-TERM-007 | 回滚缓冲区 | — | Terminal::Buffer | P0 | V1.0 |
| FR-TERM-008 | 输入同步/广播 | — | Session::Manager#broadcast | P1 | V2.0 |
| FR-TERM-009 | 代码片段管理 | — | Automation::SnippetManager | P1 | V2.0 |
| FR-TERM-010 | 智能选中 | — | Terminal::Emulator | P1 | V2.0 |
| FR-TERM-011 | 窗口透明度 | — | GUI 层 | P2 | V3.0 |
| FR-TERM-012 | 光标样式 | — | Terminal::Renderer | P2 | V3.0 |
| FR-AUTO-001 | 登录宏/脚本 | — | Automation::MacroEngine | P0 | V1.0 |
| FR-AUTO-002 | 会话录放 | — | Automation::Recorder | P2 | V3.0 |
| FR-AUTO-003 | 命令批量执行 | ssh_channel_fsm | Automation::BatchExec | P1 | V2.0 |
| FR-AUTO-004 | 本地 Shell 集成 | — | TUI 层 | P1 | V2.0 |
| FR-AUTO-005 | 脚本引擎扩展 | — | Automation::ScriptEngine | P2 | V3.0 |
| FR-COLLAB-001 | 跨平台支持 | Rebar3 跨平台编译 | Ruby 跨平台 | P1 | V2.0 |
| FR-COLLAB-002 | 配置云同步 | — | Config::Sync | P2 | V3.0 |
| FR-COLLAB-003 | 团队共享 | — | Config::TeamShare | P2 | V3.0 |
| FR-COLLAB-004 | 便携版 | — | 打包脚本 | P2 | V3.0 |

### 9.2 非功能需求映射

| 编号 | 指标 | 实现措施 |
|------|------|----------|
| NFR-PERF-001 | 连接 ≤ 2s | OTP ssh 握手优化，curve25519 优先 |
| NFR-PERF-002 | 渲染 ≥ 30fps | Ruby 差分渲染，只重绘变化行 |
| NFR-PERF-003 | 输入延迟 ≤ 50ms | Unix Socket IPC ≤ 1ms + Erlang 直发 |
| NFR-PERF-004 | SFTP ≥ 50MB/s | Erlang 并行 read/write + 独立通道 |
| NFR-PERF-005 | 10 会话 ≤ 500MB | Erlang 轻量进程，每连接约 2-4MB |
| NFR-PERF-006 | ≥ 50 并发 | Erlang 进程模型天生支持数万并发 |
| NFR-PERF-007 | 搜索 ≤ 500ms | Buffer 索引优化，二分查找 |
| NFR-PERF-008 | 冷启动 ≤ 3s | Erlang release 预编译，Ruby 延迟加载 |
| NFR-REL-001 | 72h 无崩溃 | OTP 监督树自动恢复，Ruby 线程异常隔离 |
| NFR-REL-002 | 重连 ≥ 95% | 指数退避重连 + 会话恢复 |
| NFR-REL-003 | 校验 100% | SFTP 传输后 MD5/SHA-256 校验 |
| NFR-SEC-001 | 无明文凭据 | Vault 加密 + `~vault:` 引用 |
| NFR-SEC-002 | 加密强度 | PBKDF2 ≥ 100000 / Argon2id |
| NFR-SEC-003 | 无 CVE | 发布前 `rebar3 audit` + `bundle audit` |
| NFR-USE-001 | 5 分钟上手 | CLI 向导 + 文档 |
| NFR-USE-002 | 快捷键覆盖 | 全操作快捷键映射 |
| NFR-USE-003 | 中英双语 | i18n 资源文件 |
| NFR-COMP-001 | OS 兼容 | Erlang 跨平台编译 + Ruby 跨平台 |
| NFR-COMP-002 | 服务端兼容 | OTP ssh 兼容 OpenSSH 7.0+、Dropbear、Cisco IOS |
| NFR-COMP-003 | HiDPI 适配 | V2.0 TUI 层处理 DPI 缩放 |

### 9.3 需求覆盖统计

| 层 | V1.0 覆盖 | V2.0 覆盖 | V3.0 覆盖 | 总计 |
|----|----------|----------|----------|------|
| 功能需求 | 17/51 | 19/51 | 15/51 | 51/51 |
| 非功能需求 | 14/20 | 4/20 | 2/20 | 20/20 |

---

## 10 部署与打包

### 10.1 Erlang 引擎分发

Erlang 引擎以预编译 release 形式分发，与 Ruby gem 解耦：

```
ssh-core-ext/
├── windows-x64/
│   └── ssh_core.exe + erts-15.x/
├── macos-universal/
│   └── ssh_core + erts-15.x/
├── linux-x64/
│   └── ssh_core + erts-15.x/
└── VERSION                    # 版本信息
```

Ruby gem 在安装时或运行时检测平台，下载对应预编译引擎到 `ext/ssh_core/` 目录。

### 10.2 Ruby gem 打包

```ruby
# ssh_client.gemspec
Gem::Specification.new do |spec|
  spec.name          = "network-infra-utility-ssh"
  spec.version       = "1.0.0"
  spec.summary       = "SSH 连接客户端 - Erlang 核心 + Ruby 调度"
  spec.authors       = ["Numeron"]
  spec.files         = Dir["lib/**/*.rb", "bin/*", "ext/ssh_core/**/*"]
  spec.bindir        = "bin"
  spec.executables   = ["ssh-client"]
  spec.add_dependency "thor", "~> 1.2"
  spec.add_development_dependency "rspec", "~> 3.12"
end
```

### 10.3 启动流程

```
1. 用户执行 ssh-client connect 10.0.0.1 -u admin
2. Ruby CLI 解析参数
3. SSH::Client.new → 加载配置
4. client.start_engine
   a. 检测平台 → 选择对应 ssh_core 二进制
   b. Process.spawn 启动 Erlang 引擎
   c. Erlang 引擎初始化 → 写入 IPC 端点文件
   d. Ruby 读取端点 → 建立 IPC 连接
5. client.connect(spec)
   a. Vault 解密凭据
   b. IPC RPC 调用 conn.connect
   c. Erlang 建立 SSH 连接
   d. 返回 conn_id
6. session.open_terminal
   a. IPC RPC 调用 channel.open
   b. Ruby 注册 channel.data 推送回调
7. 进入交互模式
```

### 10.4 CI/CD 流水线

```
GitHub Actions / 自建 CI
├── Erlang 编译矩阵 (windows/macos/linux)
│   ├── rebar3 compile
│   ├── rebar3 ct (Common Test)
│   ├── rebar3 release
│   └── 上传预编译二进制
├── Ruby 测试
│   ├── bundle install
│   ├── rspec spec/
│   └── rubocop
├── 集成测试
│   ├── 启动 Erlang 引擎 + Ruby 客户端
│   ├── 连接 Docker 内 SSH 服务器
│   └── 执行端到端测试脚本
└── 发布
    ├── 打包 Ruby gem (含预编译 Erlang 引擎)
    └── 发布到 RubyGems / 内部 gem 服务器
```

---

## 11 三期迭代设计

### 11.1 V1.0 — MVP 核心（P0 需求）

**目标**：可用的单用户 SSH 终端，CLI 交互。

**Erlang 侧交付**：

| 模块 | 状态 | 说明 |
|------|------|------|
| ssh_core_sup | 全量 | 监督树 |
| ssh_ipc_gateway | 全量 | JSON-RPC 网关 |
| ssh_conn_worker | 全量 | SSH2 连接 |
| ssh_auth_engine | 全量 | 密码+公钥+键盘交互 |
| ssh_jump_chain | 全量 | 多级跳板 |
| ssh_channel_fsm | 全量 | shell 通道 |
| ssh_keepalive_mgr | 全量 | 保活 + 断连检测 |
| ssh_port_fwd | 全量 | 3 种端口转发 |
| ssh_sftp_engine | 全量 | SFTP 浏览 + 传输 |
| ssh_known_hosts | 全量 | 主机密钥校验 |

**Ruby 侧交付**：

| 模块 | 状态 | 说明 |
|------|------|------|
| SSH::Client | 全量 | 主入口 + 引擎管理 |
| IPC::Client | 全量 | JSON-RPC 客户端 |
| Session::Manager | 全量 | 会话管理 |
| Session::Tree | 全量 | 分组树 |
| Terminal::Emulator | 基础 | xterm-256color 转义解析 |
| Terminal::Buffer | 全量 | 回滚缓冲 10000 行 |
| Terminal::Theme | 全量 | 内置 10 套配色 |
| Security::Vault | 全量 | AES-256-GCM |
| Security::HostKey | 全量 | 主机密钥管理 |
| Automation::MacroEngine | 全量 | 登录宏 |
| CLI | 基础 | Thor 命令行 |

**V1.0 验收标准**：
- 连接 OpenSSH 服务器，交互终端可用
- 密码 + 公钥 + 跳板连接可用
- SFTP 浏览和文件传输可用
- 端口转发 3 种类型可用
- 凭据加密存储 + 主机密钥校验
- 17 条 P0 需求全部满足量化指标

### 11.2 V2.0 — 效率增强（P1 需求）

**新增内容**：

| 方向 | 模块 | 说明 |
|------|------|------|
| TUI 多面板 | Curses UI + 标签页 + 窗口拆分 | FR-SESS-001 |
| 自动重连 | ssh_conn_worker 扩展 | FR-CONN-005 |
| 会话导入导出 | Config::ImportExport | FR-SESS-003 |
| 会话搜索 | Session::Manager#search | FR-SESS-004 |
| 批量文件传输 | File::Transfer 扩展 | FR-FILE-005 |
| ZMODEM | File::Zmodem | FR-FILE-004 |
| SSH Agent | Security::KeyManager | FR-SEC-003 |
| 密钥生成 | Security::KeyManager | FR-SEC-004 |
| 代理连接 | Network::Proxy | FR-NET-002 |
| 连接诊断 | Network::Diagnostics | FR-NET-004 |
| 搜索高亮 | Terminal::Buffer#search 扩展 | FR-TERM-005 |
| 广播输入 | Session::Manager#broadcast | FR-TERM-008 |
| 代码片段 | Automation::SnippetManager | FR-TERM-009 |
| 批量执行 | Automation::BatchExec | FR-AUTO-003 |
| 跨平台 | 三平台编译 + 测试 | FR-COLLAB-001 |

### 11.3 V3.0 — 差异化竞争力（P2 需求）

**新增内容**：

| 方向 | 模块 | 说明 |
|------|------|------|
| MOSH | mosh_engine (Erlang) | FR-CONN-007 |
| 会话锁屏 | TUI 层 | FR-SESS-006 |
| 远程文件编辑 | File::Watcher | FR-FILE-006 |
| 凭据云同步 | Config::Sync + 端到端加密 | FR-SEC-005 |
| 2FA/MFA | Security::OTP | FR-SEC-006 |
| X11 转发 | ssh_port_fwd 扩展 | FR-NET-003 |
| 流量统计 | Network::Stats | FR-NET-005 |
| 脚本引擎 | Automation::ScriptEngine (Lua) | FR-AUTO-005 |
| 会话录放 | Automation::Recorder | FR-AUTO-002 |
| 团队共享 | Config::TeamShare | FR-COLLAB-003 |
| 便携版 | 打包脚本 | FR-COLLAB-004 |

### 11.4 迭代节奏

| 里程碑 | 时间 | 内容 |
|--------|------|------|
| M1 | V1.0 W1-2 | Erlang 引擎骨架 + IPC 通路 |
| M2 | V1.0 W3-4 | SSH 连接 + 认证 + 跳板 |
| M3 | V1.0 W5-6 | Ruby 调度层 + CLI |
| M4 | V1.0 W7-8 | 终端仿真 + SFTP + 端口转发 |
| M5 | V1.0 W9-10 | 凭据加密 + 已知主机 + 登录宏 |
| V1.0 Release | W10 | 17 条 P0 全量验收 |
| — | — | — |
| M6 | V2.0 W1-4 | TUI 多面板 + 会话管理增强 |
| M7 | V2.0 W5-8 | 文件增强 + 网络增强 |
| V2.0 Release | W8 | 19 条 P1 全量验收 |
| — | — | — |
| V3.0 | W1-10 | 15 条 P2 分批交付 |

---

## 附录 A：设计决策记录

### ADR-001 SSH 协议栈选择 Erlang/OTP

- **日期**：2026-08-02
- **状态**：已决定
- **背景**：需要在 Windows/macOS/Linux 三平台支持高并发 SSH 连接（≥ 50），连接延迟 ≤ 2s
- **决策**：使用 Erlang/OTP 内置 ssh 应用作为协议栈
- **理由**：OTP ssh 是官方维护的成熟 SSH2 实现，进程模型天然适合并发连接管理，跨平台编译稳定
- **后果**：引入 Erlang/Ruby 双语言栈，增加打包复杂度，但换来得连接层面可靠性

### ADR-002 IPC 协议选择 JSON-RPC 2.0

- **日期**：2026-08-02
- **状态**：已决定
- **背景**：Erlang 与 Ruby 之间需要高效、可靠的进程间通信
- **决策**：使用 JSON-RPC 2.0 over Unix Socket / TCP
- **理由**：JSON-RPC 语言无关、调试友好；Unix Socket 零拷贝低延迟；JSON 序列化对终端数据性能损失 < 1ms 可接受
- **代价**：base64 编码增加约 33% 数据量，终端高频小包场景可通过批量推送优化

### ADR-003 UI 分阶段：CLI → TUI → GUI

- **日期**：2026-08-02
- **状态**：已决定
- **背景**：全量 TUI/GUI 开发周期长，需快速验证核心功能链路
- **决策**：V1.0 交付 Thor CLI，V2.0 升级 Curses TUI，V3.0 评估 GUI 需求
- **理由**：降低首版复杂度，先跑通 "连接 → 终端 → 文件" 全链路再增强交互

### ADR-004 凭据存储使用 Ruby 侧 Vault 而非 Erlang 管理

- **日期**：2026-08-02
- **状态**：已决定
- **背景**：凭据加密存储可在 Erlang 或 Ruby 任一侧实现
- **决策**：Ruby 侧用 AES-256-GCM 管理，连接时解密后经 IPC 传入 Erlang
- **理由**：Ruby OpenSSL 生态成熟，与配置管理在同一层更内聚；Erlang 仅作为协议执行层保持无状态
