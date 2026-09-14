# coding: utf-8
# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../service/simlab/lib/simlab'

RSpec.describe NetworkInfraUtility::SimLab::Topology do
  let(:topo) { NetworkInfraUtility::SimLab::Topology.new }

  it 'adds routers' do
    topo.add_router("R1", interfaces: { "Gi0/0" => "10.0.0.1/24" })
    expect(topo.devices["R1"]).not_to be_nil
    expect(topo.routers.keys).to include("R1")
  end

  it 'adds switches' do
    topo.add_switch("S1", ports: ["Gi0/1", "Gi0/2"])
    expect(topo.switches.keys).to include("S1")
  end

  it 'adds links and builds adjacency' do
    topo.add_router("R1", interfaces: { "Gi0/0" => "10.0.0.1/24" })
    topo.add_router("R2", interfaces: { "Gi0/0" => "10.0.0.2/24" })
    topo.add_link("R1:Gi0/0", "R2:Gi0/0")

    expect(topo.links.size).to eq(1)
    expect(topo.neighbors_of("R1").first[:peer_device]).to eq("R2")
  end

  it 'finds links between devices' do
    topo.add_router("R1", interfaces: { "Gi0/0" => "10.0.0.1/24" })
    topo.add_router("R2", interfaces: { "Gi0/0" => "10.0.0.2/24" })
    topo.add_link("R1:Gi0/0", "R2:Gi0/0")

    link = topo.link_between("R1", "R2")
    expect(link).not_to be_nil
    expect(link.up?).to be true
  end
end

RSpec.describe NetworkInfraUtility::SimLab::Engine do
  let(:engine) { NetworkInfraUtility::SimLab::Engine.new }

  it 'schedules and executes events in order' do
    results = []
    engine.schedule(at: 10) { results << "first" }
    engine.schedule(at: 5) { results << "second" }
    engine.run_until(20) { |time, event| event.call }

    expect(results).to eq(["second", "first"])
  end

  it 'advances the virtual clock' do
    engine.schedule(at: 10) { }
    engine.run_until(20) { |time, event| event.call }
    expect(engine.now).to eq(20)
  end

  it 'supports delayed scheduling' do
    results = []
    engine.schedule(at: 0) { results << engine.now }
    engine.schedule_delayed(delay: 5) { results << engine.now }
    engine.run_until(10) { |time, event| event.call }
    expect(results).to eq([0, 5])
  end
end

RSpec.describe NetworkInfraUtility::SimLab::Device::Router do
  it 'creates a router with interfaces' do
    router = NetworkInfraUtility::SimLab::Device::Router.new(
      name: "R1",
      interfaces: { "Gi0/0" => "10.0.0.1/24" }
    )
    expect(router.name).to eq("R1")
    expect(router.interfaces).to have_key("Gi0/0")
  end

  it 'installs connected routes' do
    router = NetworkInfraUtility::SimLab::Device::Router.new(
      name: "R1",
      interfaces: { "Gi0/0" => "10.0.0.1/24" }
    )
    route = router.rib.lookup(IPv4.new("10.0.0.5"))
    expect(route).not_to be_nil
    expect(route.protocol).to eq(:connected)
  end

  it 'enables OSPF' do
    router = NetworkInfraUtility::SimLab::Device::Router.new(
      name: "R1",
      interfaces: { "Gi0/0" => "10.0.0.1/24" }
    )
    router.enable_ospf(router_id: "1.1.1.1")
    expect(router.capable?(:ospf)).to be true
    expect(router.ospf).not_to be_nil
  end

  it 'installs static routes' do
    router = NetworkInfraUtility::SimLab::Device::Router.new(
      name: "R1",
      interfaces: { "Gi0/0" => "10.0.0.1/24" }
    )
    router.install_static_route("0.0.0.0/0", "10.0.0.254")
    route = router.rib.lookup(IPv4.new("8.8.8.8"))
    expect(route).not_to be_nil
    expect(route.protocol).to eq(:static)
  end

  it 'handles interface up/down' do
    router = NetworkInfraUtility::SimLab::Device::Router.new(
      name: "R1",
      interfaces: { "Gi0/0" => "10.0.0.1/24" }
    )
    router.interface_down("Gi0/0")
    expect(router.rib.lookup(IPv4.new("10.0.0.5"))).to be_nil

    router.interface_up("Gi0/0")
    expect(router.rib.lookup(IPv4.new("10.0.0.5"))).not_to be_nil
  end
end

RSpec.describe NetworkInfraUtility::SimLab::Device::Switch do
  it 'creates a switch with ports' do
    sw = NetworkInfraUtility::SimLab::Device::Switch.new(
      name: "S1",
      ports: ["Gi0/1", "Gi0/2", "Gi0/3"]
    )
    expect(sw.name).to eq("S1")
    expect(sw.ports.keys).to include("Gi0/1", "Gi0/2", "Gi0/3")
  end

  it 'learns MAC addresses from frames' do
    sw = NetworkInfraUtility::SimLab::Device::Switch.new(name: "S1", ports: ["Gi0/1", "Gi0/2"])
    sw.add_access_port("Gi0/1", pvid: 10)
    sw.add_access_port("Gi0/2", pvid: 10)

    frame = EthernetFrame.new(
      dst_mac: "ff:ff:ff:ff:ff:ff",
      src_mac: "00:1a:2b:3c:4d:5e"
    )
    sw.receive_frame(port: "Gi0/1", frame: frame)

    expect(sw.mac_table.lookup("00:1a:2b:3c:4d:5e")&.port).to eq("Gi0/1")
  end

  it 'forwards frames to known unicast port' do
    sw = NetworkInfraUtility::SimLab::Device::Switch.new(name: "S1", ports: ["Gi0/1", "Gi0/2"])
    sw.add_access_port("Gi0/1", pvid: 10)
    sw.add_access_port("Gi0/2", pvid: 10)

    # 学习源 MAC
    sw.receive_frame(port: "Gi0/1", frame: EthernetFrame.new(
      dst_mac: "ff:ff:ff:ff:ff:ff", src_mac: "00:1a:2b:3c:4d:5e"
    ))
    sw.receive_frame(port: "Gi0/2", frame: EthernetFrame.new(
      dst_mac: "ff:ff:ff:ff:ff:ff", src_mac: "aa:bb:cc:dd:ee:ff"
    ))

    # 发送已知单播
    result = sw.receive_frame(port: "Gi0/1", frame: EthernetFrame.new(
      dst_mac: "aa:bb:cc:dd:ee:ff", src_mac: "00:1a:2b:3c:4d:5e"
    ))

    expect(result.size).to eq(1)
    expect(result.first[:port]).to eq("Gi0/2")
  end
end
