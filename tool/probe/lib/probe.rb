# frozen_string_literal: true

require_relative "probe_version"
require_relative "probe_result"
require_relative "probe_base"
require_relative "probe_registry"

# NetworkInfraUtility::Probe — 服务连通性探测工具箱
#
# 对网络/服务类设备探测各类服务的连通性，覆盖：
#   icmp / telnet / ssh / netconf / snmp / twamp / dns / ntp / radius
#
# 用法：
#   require "probe"
#
#   # 单协议
#   r = NetworkInfraUtility::Probe.run(:ssh, "10.0.0.1")
#   r.ok?          # → true / false
#
#   # 批量
#   results = NetworkInfraUtility::Probe.check("10.0.0.1", protocols: %i[ssh snmp dns], timeout: 3)
#
#   # 全部协议
#   NetworkInfraUtility::Probe.check("10.0.0.1")
#
#   # 可用协议列表
#   NetworkInfraUtility::Probe.protocols
module NetworkInfraUtility
  module Probe
    module_function

    # 探测单个协议，返回 Result。
    def run(protocol, host, **opts)
      klass = Registry[protocol]
      unless klass
        raise ArgumentError,
              "未知协议: #{protocol.inspect}，可用: #{Registry.protocols.join(', ')}"
      end
      klass.new(host, **opts).call
    end

    # 批量探测，返回 Result 数组。
    # protocols 省略时探测全部已注册协议。
    def check(host, protocols: nil, **opts)
      list = protocols || Registry.protocols
      list.map { |p| run(p, host, **opts) }
    end

    # 全部可用协议名。
    def protocols
      Registry.protocols
    end
  end
end