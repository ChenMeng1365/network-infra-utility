---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: '6a4e300b-498c-4b8e-aca3-75d6bf706299'
  PropagateID: '6a4e300b-498c-4b8e-aca3-75d6bf706299'
  ReservedCode1: '322e695f-ea2e-4e18-a164-50a935a6be6d'
  ReservedCode2: '322e695f-ea2e-4e18-a164-50a935a6be6d'
---

# GUIDE

## 在 Alpine 设备上重新编译 Rust 和 Erlang 引擎

项目 SSH 核心引擎有两个后端，均可在 Alpine（musl libc）上原生编译：

| 引擎 | 目录 | 构建工具 | 产物 |
|------|------|---------|------|
| **Rust 引擎**（默认） | `service/ssh/ext/ssh_core_rs/` | cargo | `target/release/ssh_core_rs` |
| **Erlang 引擎**（可选） | `service/ssh/ext/ssh_core/` | rebar3 | `_build/default/lib/ssh_core/ebin/*.beam` |

### 2.1 安装编译依赖

```bash
# 更新包索引
apk update

# 通用编译工具链（gcc、make、musl-dev、libc Headers 等）
apk add build-base

# ── Rust 引擎依赖 ──
apk add rust cargo
apk add pkgconf openssl-dev     # openssl-dev 预防部分 crate 需要链接系统 OpenSSL

# ── Erlang 引擎依赖 ──
# 方式 A：Alpine 仓库安装（Alpine 3.19+ 提供 OTP 26）
apk add erlang rebar3

# 方式 B：如果仓库 OTP 版本低于 26，从源码编译 Erlang/OTP
#   见下方 2.3 节
```

### 2.2 编译 Rust 引擎

```bash
cd service/ssh/ext/ssh_core_rs

# 清理旧产物（如从其他平台拷贝过来）
rm -rf target/

# Release 编译
cargo build --release

# 验证产物
ls -lh target/release/ssh_core_rs
./target/release/ssh_core_rs --help 2>&1 || true
# 引擎启动后会在 /tmp/ssh_core_<uid>.endpoint 写入端点文件
```

**说明：**
- Alpine 默认 host triple 是 `x86_64-unknown-linux-musl`（ARM 则为 `aarch64-unknown-linux-musl`），cargo 会自动选择，无需额外配置 target。
- `Cargo.toml` 中 russh 使用 `ring` 特性（纯 Rust 加密后端），不依赖系统 OpenSSL / NASM，musl 环境可直接编译。
- 编译后 `bin/ssh_core_rs`（bash 启动脚本）已存在，Ruby 端 `Client.new(backend: :rust)` 会自动调用它。

### 2.3 编译 Erlang 引擎

> 如果 `apk add erlang` 安装的 OTP 版本 >= 26，直接跳到 2.3.2。

#### 2.3.1 从源码编译 Erlang/OTP（仅当仓库版本 < 26 时需要）

```bash
# 安装 Erlang 编译依赖
apk add build-base perl ncurses-dev openssl-dev unixodbc-dev

# 下载 OTP 27（或 26）
cd /tmp
wget https://github.com/erlang/otp/releases/download/OTP-27.3.3/otp_src_27.3.3.tar.gz
tar xzf otp_src_27.3.3.tar.gz
cd otp_src_27.3.3

# 编译（musl 环境，禁用 wx/mac 等 GUI 组件，保留 ssh/crypto/public_key）
export ERL_TOP=/tmp/otp_src_27.3.3
./configure \
  --prefix=/usr/local/erlang \
  --without-ssl-verify \
  --disable-nls \
  --without-javac \
  --without-wx \
  --without-debugger
make -j$(nproc)
make install

# 加入 PATH
export PATH=/usr/local/erlang/bin:$PATH
echo 'export PATH=/usr/local/erlang/bin:$PATH' >> ~/.profile

# 验证
erl -version
# Erlang (SHELL) version 27.3.3
```

#### 2.3.2 安装 rebar3

```bash
# 方式 A：Alpine 仓库已安装则跳过
rebar3 --version

# 方式 B：下载 standalone 二进制
wget https://github.com/erlang/rebar3/releases/download/3.24.0/rebar3
chmod +x rebar3
mv rebar3 /usr/local/bin/
rebar3 --version
```

#### 2.3.3 编译 ssh_core

```bash
cd service/ssh/ext/ssh_core

# 清理旧产物
rm -rf _build/ rebar3.crashdump

# 编译
# rebar.config 中 {deps, []}（无外部依赖），jsx 已内嵌为本地源码
# （local_deps/jsx/src/src/），通过 src_dirs 直接编译，无需从 hex.pm 拉取
rebar3 compile

# 验证产物
ls _build/default/lib/ssh_core/ebin/*.beam | head -5
```

> **常见问题**：启动时如果报 `undefined function os:getuid/0`，是因为 OTP 版本 < 26 缺少此 BIF。代码已修复为自动 fallback 到 `os:cmd("id -u")`，确保 `rebar3 compile` 重新编译即可。

#### 2.3.4 创建 Unix 启动脚本

项目当前只有 `bin/ssh_core.cmd`（Windows），Linux/Alpine 需要创建 `bin/ssh_core`：

```bash
cat > service/ssh/ext/ssh_core/bin/ssh_core << 'SCRIPT'
#!/usr/bin/env sh
# ssh_core engine launcher for Linux/macOS/Alpine
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_CORE_DIR="$(dirname "$SCRIPT_DIR")"
EBIN_DIR="$SSH_CORE_DIR/_build/default/lib/ssh_core/ebin"

# Delete stale endpoint file
ENDPOINT_FILE="/tmp/ssh_core_$(id -u).endpoint"
rm -f "$ENDPOINT_FILE"

# Start the Erlang VM
exec erl -noshell -noinput -pa "$EBIN_DIR" \
  -eval "application:ensure_all_started(ssh_core)"
SCRIPT
chmod +x service/ssh/ext/ssh_core/bin/ssh_core
```

#### 2.3.5 验证 Erlang 引擎可启动

```bash
cd service/ssh/ext/ssh_core
./bin/ssh_core &
# 等 2 秒后查看端点文件
sleep 2 && cat /tmp/ssh_core_$(id -u).endpoint
# 应输出类似：tcp://127.0.0.1:xxxxx\n<auth_token>

# 停止引擎
kill %1
```

### 2.4 编译后的 Ruby 端验证

```bash
# 在项目根目录，确认 Ruby 可连接引擎
ruby -e '
  $LOAD_PATH.unshift("service/ssh/lib")
  require "network_infra_utility/ssh"

  # Rust 引擎（默认）
  client = NetworkInfraUtility::SSH::Client.new(backend: :rust)
  client.start_engine
  puts "Rust engine: #{client.started?}"
  client.stop

  # Erlang 引擎
  client2 = NetworkInfraUtility::SSH::Client.new(backend: :erlang)
  client2.start_engine
  puts "Erlang engine: #{client2.started?}"
  client2.stop
'
```

### 2.5 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `cargo build` 报 `linker cc not found` | 未安装 build-base | `apk add build-base` |
| `cargo build` 拉 crates.io 超时 | 国内网络限制 | `~/.cargo/config.toml` 配中科大/清华镜像源 |
| `cargo build` 报 `edition2024 is required` | Alpine 仓库 Rust 版本过旧 (< 1.85) | `apk del rust cargo` 后用 rustup 装最新稳定版 |
| `curl https://sh.rustup.rs` 下载不动 | rustup 安装脚本在国外 | 设 `RUSTUP_DIST_SERVER` 中科大镜像，或直接下载 rustup-init 二进制 |
| `rebar3 compile` 报 `undef ssh` 模块 | OTP 版本 < 26 | 按本文 2.3.1 从源码编译 OTP 27 |
| Erlang 引擎报 `undefined function os:getuid/0` | OTP < 26 缺少此 BIF | 代码已修复自动 fallback，`rebar3 compile` 重新编译 |
| Erlang 引擎启动报 `ssh_core beam not found` | `bin/ssh_core` 脚本 EBIN_DIR 路径不对 | 确认 `_build/default/lib/ssh_core/ebin/` 下有 beam 文件 |
| Ruby 报 `Engine binary not found` | 缺少启动脚本 | Rust: 确认 `bin/ssh_core_rs` 存在；Erlang: 按本文 2.3.4 创建 `bin/ssh_core` |
| Ruby 报 `Permission denied` 启动脚本 | Windows 拷来的脚本丢失执行位 | `chmod +x service/ssh/ext/ssh_core_rs/bin/ssh_core_rs` |
| Ruby 报 `ECONNREFUSED` 连接引擎 | 旧引擎残留进程占用端口 | `pkill ssh_core_rs; rm -f /tmp/ssh_core_*.endpoint` |
| `conn.connect` 超时 (60s) | 网络不通或设备 SSH 不兼容 | 先 `ping`/`nc -zv` 确认网络，再用 `RUST_LOG=debug` 定位 |
| `auth_rejected` 认证被拒绝 | 设备只支持 keyboard-interactive | 配置文件 `auth.type` 改为 `keyboard_interactive` |
| Rust 编译卡在 `ring` 或 `aws-lc-rs` | 误用了 aws-lc-rs 后端 | Cargo.toml 已指定 `features = ["ring"]`，确认未被覆盖 |
| `error: musl-gcc: not found` | 部分 crate 尝试用 musl-gcc | `apk add musl-dev`（已含于 build-base） |