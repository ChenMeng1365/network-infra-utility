# coding: utf-8
# frozen_string_literal: true

# 帧转发决策：泛洪/转发/丢弃。
#
# 实现原理：已知单播按端口转发；未知单播/广播泛洪（除入端口）；
# 同端口进出过滤（hairpin 丢弃）；可挂 ACL 钩子接口。
#
# 用法：
#   fwd = Forward.new
#   fwd.decide(frame, in_port: "Gi0/1", mac_table: table, vlan_ports: [1,2,3])
#   # => {action: :forward, ports: ["Gi0/2"]}

require_relative '../basic/packet'

class Forward
  # 转发决策结果。
  Decision = Data.define(:action, :ports, :reason) do
    def to_s
      "#{action} ports=#{ports&.inspect} (#{reason})"
    end
  end

  attr_reader :acl_hooks

  def initialize
    @acl_hooks = []  # ACL 钩子链
  end

  # 添加 ACL 钩子。
  # 钩子签名: ->(frame, in_port) { :drop | :flood | nil }
  def add_acl(&blk)
    @acl_hooks << blk
  end

  # 帧转发决策。
  # frame: EthernetFrame
  # in_port: 入端口
  # mac_table: MACTable 实例（用于查目的 MAC）
  # vlan_ports: 同 VLAN 端口列表（用于泛洪）
  def decide(frame, in_port:, mac_table:, vlan_ports:)
    # ACL 钩子
    @acl_hooks.each do |hook|
      result = hook.call(frame, in_port)
      case result
      when :drop
        return Decision.new(action: :drop, ports: nil, reason: 'ACL drop')
      when :flood
        return Decision.new(action: :flood, ports: vlan_ports - [in_port], reason: 'ACL flood')
      end
    end

    # 广播帧 → 泛洪
    if frame.broadcast?
      ports = vlan_ports - [in_port]
      return Decision.new(action: :flood, ports: ports, reason: 'broadcast flood')
    end

    # 组播帧 → 泛洪（简化）
    if frame.multicast?
      ports = vlan_ports - [in_port]
      return Decision.new(action: :flood, ports: ports, reason: 'multicast flood')
    end

    # 已知单播
    entry = mac_table.lookup(frame.dst_mac)
    if entry
      out_port = entry.port

      # 同端口进出 → 丢弃
      if out_port == in_port
        return Decision.new(action: :drop, ports: nil, reason: 'hairpin drop')
      end

      # 目标端口不在 VLAN 允许列表 → 丢弃
      unless vlan_ports.include?(out_port)
        return Decision.new(action: :drop, ports: nil, reason: 'port not in VLAN')
      end

      Decision.new(action: :forward, ports: [out_port], reason: 'known unicast')
    else
      # 未知单播 → 泛洪
      ports = vlan_ports - [in_port]
      Decision.new(action: :flood, ports: ports, reason: 'unknown unicast flood')
    end
  end
end
