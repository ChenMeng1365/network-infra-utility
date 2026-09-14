# coding: utf-8
# frozen_string_literal: true

# 统一报文抽象：EthernetFrame 与 IPPacket。
#
# 供路由/交换共同使用的仿真报文对象，字段对齐真实协议但不编码成字节。
# 支持嵌套封装：EthernetFrame.payload 可以是 IPPacket 或其他协议消息。
#
# 用法：
#   frame = EthernetFrame.new(
#     dst_mac: "ff:ff:ff:ff:ff:ff",
#     src_mac: "00:1a:2b:3c:4d:5e",
#     vlan_tag: 10,
#     payload: IPPacket.new(src: "10.0.0.1", dst: "10.0.0.2", ttl: 64, protocol: :icmp)
#   )
#   frame.broadcast?  # => true
#   frame.payload.ip?  # => true

require_relative 'mac_address'

# 以太网帧。
#
# 字段：dst_mac, src_mac（MacAddress 或字符串）, vlan_tag（Integer 或 nil）,
# payload（任意报文对象或 nil）。
class EthernetFrame
  attr_reader :dst_mac, :src_mac, :vlan_tag, :payload

  BROADCAST_MAC = 0xFFFFFFFFFFFF

  def initialize(dst_mac:, src_mac:, vlan_tag: nil, payload: nil)
    @dst_mac  = mac_addr(dst_mac)
    @src_mac  = mac_addr(src_mac)
    @vlan_tag = vlan_tag
    @payload  = payload
  end

  def broadcast?
    dst_mac.number == BROADCAST_MAC
  end

  def multicast?
    dst_mac.multicast?
  end

  def unicast?
    !broadcast? && !multicast?
  end

  def tagged?
    !vlan_tag.nil?
  end

  def vlan_id
    vlan_tag & 0x0FFF if tagged?
  end

  def priority
    (vlan_tag >> 13) & 0x07 if tagged?
  end

  def ip?
    payload.is_a?(IPPacket)
  end

  def arp?
    payload.is_a?(ArpPacket)
  end

  def to_s
    "Frame[#{src_mac}->#{dst_mac}" +
      (tagged? ? " vlan=#{vlan_id}" : "") +
      (payload ? " #{payload}" : '') + ']'
  end

  alias inspect to_s

  private

  def mac_addr(arg)
    arg.is_a?(MacAddress) ? arg : MacAddress.new(arg)
  end
end

# IP 报文。
#
# 字段：src, dst（IPv4 或字符串）, ttl, protocol, dscp, payload。
class IPPacket
  attr_reader :src, :dst, :ttl, :protocol, :dscp, :payload

  def initialize(src:, dst:, ttl: 64, protocol: :tcp, dscp: 0, payload: nil)
    @src      = ip_addr(src)
    @dst      = ip_addr(dst)
    @ttl      = ttl
    @protocol = protocol
    @dscp     = dscp
    @payload  = payload
  end

  def decrement_ttl
    @ttl -= 1
    self
  end

  def expired?
    @ttl <= 0
  end

  def to_s
    "IP[#{src}->#{dst} ttl=#{ttl} proto=#{protocol}]"
  end

  alias inspect to_s

  private

  def ip_addr(arg)
    return arg if arg.is_a?(IPv4) || arg.is_a?(IPv6)

    if arg.is_a?(String)
      arg.include?(':') ? IPv6.new(arg) : IPv4.new(arg)
    else
      arg
    end
  end
end

# ARP 报文（简化）。
class ArpPacket
  attr_reader :sender_mac, :sender_ip, :target_ip

  def initialize(sender_mac:, sender_ip:, target_ip:)
    @sender_mac = sender_mac.is_a?(MacAddress) ? sender_mac : MacAddress.new(sender_mac)
    @sender_ip  = sender_ip.is_a?(IPv4) ? sender_ip : IPv4.new(sender_ip)
    @target_ip  = target_ip.is_a?(IPv4) ? target_ip : IPv4.new(target_ip)
  end

  def to_s
    "ARP[who-has #{target_ip} tell #{sender_ip}]"
  end

  alias inspect to_s
end

# ICMP Echo 报文（简化）。
class ICMPPacket
  attr_reader :type, :seq, :payload

  def initialize(type: :echo_request, seq: 0, payload: nil)
    @type    = type
    @seq     = seq
    @payload = payload
  end

  def echo_request?
    type == :echo_request
  end

  def echo_reply?
    type == :echo_reply
  end

  def to_s
    "ICMP[#{type} seq=#{seq}]"
  end

  alias inspect to_s
end
