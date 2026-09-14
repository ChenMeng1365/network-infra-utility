# coding: utf-8
# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../support/switching/mac_table'
require_relative '../../support/switching/frame_forward'
require_relative '../../support/switching/vlan'
require_relative '../../support/switching/stp'
require_relative '../../support/basic/packet'

RSpec.describe MACTable do
  let(:table) { MACTable.new(aging_time: 300) }

  it 'learns MAC addresses' do
    table.learn("00:1a:2b:3c:4d:5e", port: "Gi0/1", now: 0)
    entry = table.lookup("00:1a:2b:3c:4d:5e")
    expect(entry.port).to eq("Gi0/1")
  end

  it 'ages out old entries' do
    table.learn("00:1a:2b:3c:4d:5e", port: "Gi0/1", now: 0)
    table.age_out(now: 350)
    expect(table.lookup("00:1a:2b:3c:4d:5e")).to be_nil
  end

  it 'keeps static entries during aging' do
    table.add_static("00:1a:2b:3c:4d:5e", "Gi0/1")
    table.age_out(now: 1000)
    expect(table.lookup("00:1a:2b:3c:4d:5e")).not_to be_nil
  end

  it 'removes entries by port' do
    table.learn("aa:bb:cc:dd:ee:ff", port: "Gi0/1", now: 0)
    table.remove_by_port("Gi0/1")
    expect(table.lookup("aa:bb:cc:dd:ee:ff")).to be_nil
  end
end

RSpec.describe VLAN do
  let(:vlan) { VLAN.new }

  before do
    vlan.add_access_port("Gi0/1", pvid: 10)
    vlan.add_trunk_port("Gi0/24", allowed: [10, 20], native: 1)
  end

  it 'tags frames on access ports' do
    frame = EthernetFrame.new(dst_mac: "ff:ff:ff:ff:ff:ff", src_mac: "00:1a:2b:3c:4d:5e")
    tagged = vlan.ingress(frame, port: "Gi0/1")
    expect(tagged.vlan_id).to eq(10)
  end

  it 'untags frames on access ports' do
    frame = EthernetFrame.new(dst_mac: "ff:ff:ff:ff:ff:ff", src_mac: "00:1a:2b:3c:4d:5e", vlan_tag: 10)
    untagged = vlan.egress(frame, port: "Gi0/1")
    expect(untagged.tagged?).to be false
  end

  it 'keeps tags on trunk ports' do
    frame = EthernetFrame.new(dst_mac: "ff:ff:ff:ff:ff:ff", src_mac: "00:1a:2b:3c:4d:5e", vlan_tag: 10)
    result = vlan.egress(frame, port: "Gi0/24")
    expect(result.vlan_id).to eq(10)
  end

  it 'lists ports for a VLAN' do
    expect(vlan.ports_for_vlan(10)).to include("Gi0/1", "Gi0/24")
  end
end

RSpec.describe Forward do
  let(:fwd) { Forward.new }
  let(:table) { MACTable.new }

  it 'floods broadcast frames' do
    table.learn("00:1a:2b:3c:4d:5e", port: "Gi0/1", now: 0)
    frame = EthernetFrame.new(dst_mac: "ff:ff:ff:ff:ff:ff", src_mac: "00:1a:2b:3c:4d:5e")
    decision = fwd.decide(frame, in_port: "Gi0/1", mac_table: table, vlan_ports: ["Gi0/1", "Gi0/2", "Gi0/3"])
    expect(decision.action).to eq(:flood)
    expect(decision.ports).to include("Gi0/2", "Gi0/3")
  end

  it 'forwards known unicast' do
    table.learn("00:1a:2b:3c:4d:5e", port: "Gi0/1", now: 0)
    table.learn("aa:bb:cc:dd:ee:ff", port: "Gi0/2", now: 0)
    frame = EthernetFrame.new(dst_mac: "aa:bb:cc:dd:ee:ff", src_mac: "00:1a:2b:3c:4d:5e")
    decision = fwd.decide(frame, in_port: "Gi0/1", mac_table: table, vlan_ports: ["Gi0/1", "Gi0/2", "Gi0/3"])
    expect(decision.action).to eq(:forward)
    expect(decision.ports).to eq(["Gi0/2"])
  end

  it 'drops hairpin traffic' do
    table.learn("00:1a:2b:3c:4d:5e", port: "Gi0/1", now: 0)
    frame = EthernetFrame.new(dst_mac: "00:1a:2b:3c:4d:5e", src_mac: "aa:bb:cc:dd:ee:ff")
    decision = fwd.decide(frame, in_port: "Gi0/1", mac_table: table, vlan_ports: ["Gi0/1", "Gi0/2"])
    expect(decision.action).to eq(:drop)
  end
end
