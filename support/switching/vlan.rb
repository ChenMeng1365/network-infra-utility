# coding: utf-8
# frozen_string_literal: true

# 802.1Q VLAN：tag 的添加/剥离/改写。
#
# 实现原理：access 端口（PVID 打标去标）与 trunk 端口
# （allowed vlan 白名单、native vlan）；VLAN 内洪域隔离。
#
# 用法：
#   vlan = VLAN.new
#   vlan.add_access_port("Gi0/1", pvid: 10)
#   vlan.add_trunk_port("Gi0/24", allowed: [10, 20, 30], native: 1)
#   frame = vlan.ingress(raw_frame, port: "Gi0/1")  # 入口处理
#   out_frame = vlan.egress(frame, port: "Gi0/24")   # 出口处理

require_relative '../basic/packet'

class VLAN
  # 端口配置。
  PortConfig = Data.define(:mode, :pvid, :allowed, :native_vlan) do
    def access?
      mode == :access
    end

    def trunk?
      mode == :trunk
    end
  end

  attr_reader :ports, :vlans

  def initialize
    @ports = {}  # port_name => PortConfig
    @vlans = Set.new  # 所有已定义的 VLAN ID
  end

  # 添加 access 端口。
  def add_access_port(port, pvid:)
    @ports[port] = PortConfig.new(mode: :access, pvid: pvid, allowed: [pvid], native_vlan: nil)
    @vlans.add(pvid)
  end

  # 添加 trunk 端口。
  def add_trunk_port(port, allowed:, native: nil)
    @ports[port] = PortConfig.new(mode: :trunk, pvid: nil, allowed: allowed, native_vlan: native)
    allowed.each { |v| @vlans.add(v) }
    @vlans.add(native) if native
  end

  # 删除端口。
  def remove_port(port)
    @ports.delete(port)
  end

  # 入口处理：根据端口模式给帧打 VLAN tag。
  # raw_frame: 未打标的 EthernetFrame
  # 返回打了 VLAN tag 的帧
  def ingress(raw_frame, port:)
    config = @ports[port]
    return raw_frame unless config  # 未配置端口，透传

    if config.access?
      # access 端口：打上 PVID
      raw_frame.vlan_tag ? raw_frame : EthernetFrame.new(
        dst_mac: raw_frame.dst_mac,
        src_mac: raw_frame.src_mac,
        vlan_tag: config.pvid,
        payload: raw_frame.payload
      )
    elsif config.trunk?
      if raw_frame.vlan_tag
        # trunk 端口已有 tag：检查是否在白名单
        if config.allowed.include?(raw_frame.vlan_id)
          raw_frame
        else
          nil  # 不在白名单，丢弃
        end
      elsif config.native_vlan
        # 无 tag，走 native VLAN
        EthernetFrame.new(
          dst_mac: raw_frame.dst_mac,
          src_mac: raw_frame.src_mac,
          vlan_tag: config.native_vlan,
          payload: raw_frame.payload
        )
      else
        nil  # 无 tag 且无 native VLAN，丢弃
      end
    end
  end

  # 出口处理：根据端口模式去 VLAN tag。
  def egress(frame, port:)
    config = @ports[port]
    return frame unless config && frame.vlan_tag

    if config.access?
      # access 端口：去 tag
      if frame.vlan_id == config.pvid
        EthernetFrame.new(
          dst_mac: frame.dst_mac,
          src_mac: frame.src_mac,
          vlan_tag: nil,
          payload: frame.payload
        )
      else
        nil  # VLAN 不匹配 PVID，丢弃
      end
    elsif config.trunk?
      if config.allowed.include?(frame.vlan_id)
        if config.native_vlan && frame.vlan_id == config.native_vlan
          # native VLAN：去 tag
          EthernetFrame.new(
            dst_mac: frame.dst_mac,
            src_mac: frame.src_mac,
            vlan_tag: nil,
            payload: frame.payload
          )
        else
          frame  # 保留 tag
        end
      else
        nil  # 不在白名单，丢弃
      end
    end
  end

  # 获取指定 VLAN 的端口列表。
  def ports_for_vlan(vlan_id)
    @ports.each_with_object([]) do |(port_name, config), result|
      if config.access? && config.pvid == vlan_id
        result << port_name
      elsif config.trunk? && config.allowed.include?(vlan_id)
        result << port_name
      end
    end
  end

  # 端口属于哪些 VLAN。
  def vlans_for_port(port)
    config = @ports[port]
    return [] unless config

    config.access? ? [config.pvid] : config.allowed
  end

  # 端口配置快照。
  def to_h
    @ports.transform_values do |c|
      { mode: c.mode, pvid: c.pvid, allowed: c.allowed, native: c.native_vlan }
    end
  end
end

require 'set'
