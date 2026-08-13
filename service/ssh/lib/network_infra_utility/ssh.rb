# frozen_string_literal: true

require_relative "ssh/version"
require_relative "ssh/client"
require_relative "ssh/ipc/transport"
require_relative "ssh/ipc/router"
require_relative "ssh/ipc/coalesce"
require_relative "ssh/ipc/errors"
require_relative "ssh/session/manager"
require_relative "ssh/session/session"
require_relative "ssh/session/tree"
require_relative "ssh/session/history"
require_relative "ssh/terminal/emulator"
require_relative "ssh/terminal/ansi_parser"
require_relative "ssh/terminal/screen"
require_relative "ssh/terminal/buffer"
require_relative "ssh/terminal/theme"
require_relative "ssh/terminal/logger"
require_relative "ssh/security/vault"
require_relative "ssh/security/host_key"
require_relative "ssh/automation/macro_engine"
require_relative "ssh/config/settings"
require_relative "ssh/config/schema"
require_relative "ssh/config/store"

# NetworkInfraUtility::SSH — SSH 连接客户端
#
# 架构（LLD §1）：
#   Erlang/OTP ssh 做协议核心，Ruby 做调度与终端，
#   两者经 JSON-RPC 2.0 over Unix Socket/TCP 通信。
#
# 组合根：SSH::Client——构造时编排全部子系统，
# 管理 Erlang 引擎生命周期与 IPC 连接。
#
# 用法：
#   client = NetworkInfraUtility::SSH::Client.new
#   client.start_engine
#   session = client.connect(host: "10.0.0.1", user: "admin")
#   terminal = session.open_terminal
#   terminal.puts("show version")
module NetworkInfraUtility
  module SSH
  end
end