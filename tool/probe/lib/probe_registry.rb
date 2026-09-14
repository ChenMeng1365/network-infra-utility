# frozen_string_literal: true

require_relative "probe_tcp"
require_relative "probe_icmp"
require_relative "probe_dns"
require_relative "probe_ntp"
require_relative "probe_snmp"
require_relative "probe_radius"

module NetworkInfraUtility
  module Probe
    # 协议名 → 探针类注册表。扩展新协议时调用 Registry.register。
    module Registry
      PROBES = {
        icmp:    IcmpProbe,
        telnet:  TelnetProbe,
        ssh:     SshProbe,
        netconf: NetconfProbe,
        snmp:    SnmpProbe,
        twamp:   TwampProbe,
        dns:     DnsProbe,
        ntp:     NtpProbe,
        radius:  RadiusProbe
      }.freeze

      module_function

      # 全部协议名。
      def protocols
        PROBES.keys
      end

      # 按名字取探针类（符号或字符串均可）。
      def [](name)
        PROBES[name.to_s.downcase.to_sym]
      end

      # 注册自定义探针类。
      def register(klass)
        PROBES[klass.protocol] = klass
      end
    end
  end
end
