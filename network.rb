# frozen_string_literal: true

require_relative "version"

# Network Infrastructure Utility 统一出口。
#
# 用法：
#   require "network"
#
# 触发后会按 document / service / support / tool 四层依次加载所有子模块。
# 随子模块落地，逐步取消下方对应 require 的注释。
# 加载顺序按依赖方向上游在前，避免循环依赖。
module NetworkInfraUtility
  # 支撑层：无外部依赖的基础工具，最先加载
  require_relative "support/basic/ip"
  require_relative "support/basic/as_num"
  require_relative "support/basic/mac_address"
  require_relative "support/basic/packet"

  # 路由原理层：依赖 support/basic
  require_relative "support/routing/prefix"
  require_relative "support/routing/lpm_trie"
  require_relative "support/routing/rib"
  require_relative "support/routing/static_route"
  require_relative "support/routing/rip"
  require_relative "support/routing/ospf"
  require_relative "support/routing/bgp"

  # 交换原理层：依赖 support/basic
  require_relative "support/switching/mac_table"
  require_relative "support/switching/frame_forward"
  require_relative "support/switching/vlan"
  require_relative "support/switching/stp"

  # 工具层：依赖 support
  require_relative "tool/probe/lib/probe"

  # 服务层：依赖 tool / support
  require_relative "service/simlab/lib/simlab"
  require_relative "service/ssh/lib/network_infra_utility/ssh"
  require_relative "service/geoquery/geoquery"

  # 文档层：依赖 service / tool，最后加载
  # require_relative "document/xxx"
end
