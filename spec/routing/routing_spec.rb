# coding: utf-8
# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../support/routing/prefix'
require_relative '../../support/routing/lpm_trie'
require_relative '../../support/routing/rib'
require_relative '../../support/routing/static_route'

RSpec.describe Prefix do
  describe '.new' do
    it 'parses IPv4 CIDR' do
      p = Prefix.new("192.168.0.0/16")
      expect(p.prefix_len).to eq(16)
      expect(p.family).to eq(:ipv4)
    end

    it 'normalizes host bits to zero' do
      p = Prefix.new("192.168.1.1/16")
      expect(p.network_address.to_s).to eq("192.168.0.0")
    end
  end

  describe '#include?' do
    it 'checks if an IP is within the prefix' do
      p = Prefix.new("192.168.0.0/16")
      expect(p.include?(IPv4.new("192.168.1.1"))).to be true
      expect(p.include?(IPv4.new("10.0.0.1"))).to be false
    end
  end

  describe '#superset_of?' do
    it 'checks containment of another prefix' do
      p1 = Prefix.new("192.168.0.0/16")
      p2 = Prefix.new("192.168.0.0/24")
      expect(p1.superset_of?(p2)).to be true
      expect(p2.superset_of?(p1)).to be false
    end
  end

  describe '#subnets' do
    it 'splits into two sub-prefixes' do
      p = Prefix.new("192.168.0.0/24")
      subs = p.subnets
      expect(subs.size).to eq(2)
      expect(subs[0].prefix_len).to eq(25)
      expect(subs[1].prefix_len).to eq(25)
    end
  end
end

RSpec.describe LpmTrie do
  let(:trie) { LpmTrie.new }

  it 'inserts and matches longest prefix' do
    trie.insert("10.0.0.0/8", "route_8")
    trie.insert("10.1.0.0/16", "route_16")
    expect(trie.match(IPv4.new("10.1.1.1"))).to eq("route_16")
    expect(trie.match(IPv4.new("10.2.0.1"))).to eq("route_8")
  end

  it 'returns nil for no match' do
    trie.insert("10.0.0.0/8", "route")
    expect(trie.match(IPv4.new("192.168.0.1"))).to be_nil
  end

  it 'deletes a prefix' do
    trie.insert("10.0.0.0/8", "route")
    expect(trie.delete("10.0.0.0/8")).to be true
    expect(trie.match(IPv4.new("10.0.0.1"))).to be_nil
  end
end

RSpec.describe RIB do
  let(:rib) { RIB.new }

  it 'adds and looks up routes' do
    rib.add(prefix: "10.0.0.0/8", next_hop: "192.168.1.1", protocol: :ospf, metric: 10)
    route = rib.lookup(IPv4.new("10.0.1.1"))
    expect(route).not_to be_nil
    expect(route.next_hop).to eq("192.168.1.1")
  end

  it 'selects best route by admin distance' do
    rib.add(prefix: "10.0.0.0/8", next_hop: "192.168.1.1", protocol: :rip, metric: 1)
    rib.add(prefix: "10.0.0.0/8", next_hop: "192.168.1.2", protocol: :ospf, metric: 10)
    route = rib.best("10.0.0.0/8")
    expect(route.protocol).to eq(:ospf)  # OSPF AD=110 < RIP AD=120
  end

  it 'deletes routes by protocol' do
    rib.add(prefix: "10.0.0.0/8", next_hop: "192.168.1.1", protocol: :ospf, metric: 10)
    rib.delete("10.0.0.0/8", protocol: :ospf)
    expect(rib.best("10.0.0.0/8")).to be_nil
  end
end

RSpec.describe StaticRoute do
  it 'installs and removes routes' do
    sr = StaticRoute.new
    sr.install("10.0.0.0/8", "192.168.1.1")
    expect(sr.get("10.0.0.0/8")[:next_hop]).to eq("192.168.1.1")
    sr.remove("10.0.0.0/8")
    expect(sr.get("10.0.0.0/8")).to be_nil
  end

  it 'exports to RIB entries' do
    sr = StaticRoute.new
    sr.install("0.0.0.0/0", "192.168.1.254")
    entries = sr.to_rib_entries
    expect(entries.first[:protocol]).to eq(:static)
  end
end
