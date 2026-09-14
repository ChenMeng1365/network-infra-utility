# frozen_string_literal: true

# spec/probe_spec.rb —— Probe 连通性探测工具箱测试
require "network"

RSpec.describe NetworkInfraUtility::Probe do
  describe "Registry 注册表" do
    it "包含全部内置协议" do
      expect(NetworkInfraUtility::Probe.protocols).to contain_exactly(
        :icmp, :telnet, :ssh, :netconf, :snmp, :twamp, :dns, :ntp, :radius
      )
    end

    it "按符号/字符串名取探针类" do
      expect(NetworkInfraUtility::Probe::Registry[:ssh]).to eq NetworkInfraUtility::Probe::SshProbe
      expect(NetworkInfraUtility::Probe::Registry["dns"]).to eq NetworkInfraUtility::Probe::DnsProbe
    end
  end

  describe "协议名派生与默认端口" do
    it "协议名从类名派生" do
      expect(NetworkInfraUtility::Probe::SshProbe.protocol).to eq :ssh
      expect(NetworkInfraUtility::Probe::NetconfProbe.protocol).to eq :netconf
      expect(NetworkInfraUtility::Probe::TwampProbe.protocol).to eq :twamp
      expect(NetworkInfraUtility::Probe::IcmpProbe.protocol).to eq :icmp
    end

    it "默认端口正确" do
      expect(NetworkInfraUtility::Probe::TelnetProbe.default_port).to eq 23
      expect(NetworkInfraUtility::Probe::SshProbe.default_port).to eq 22
      expect(NetworkInfraUtility::Probe::NetconfProbe.default_port).to eq 830
      expect(NetworkInfraUtility::Probe::SnmpProbe.default_port).to eq 161
      expect(NetworkInfraUtility::Probe::TwampProbe.default_port).to eq 862
      expect(NetworkInfraUtility::Probe::DnsProbe.default_port).to eq 53
      expect(NetworkInfraUtility::Probe::NtpProbe.default_port).to eq 123
      expect(NetworkInfraUtility::Probe::RadiusProbe.default_port).to eq 1812
      expect(NetworkInfraUtility::Probe::IcmpProbe.default_port).to be_nil
    end
  end

  describe "Result 结果对象" do
    let(:ok) do
      described_class::Result.new(protocol: :ssh, host: "10.0.0.1", port: 22, status: :ok, latency: 0.01)
    end

    it "状态判定" do
      expect(ok.ok?).to be true
      expect(ok.success?).to be true
    end

    it "to_h 可序列化" do
      expect(ok.to_h[:protocol]).to eq :ssh
      expect(ok.to_h[:status]).to eq :ok
    end
  end

  describe "run 分派" do
    it "未知协议抛 ArgumentError" do
      expect { described_class.run(:foobar, "10.0.0.1") }.to raise_error(ArgumentError)
    end
  end

  describe "BER 编码 (SNMP GET)" do
    it "生成标准 SNMPv2c GET (sysDescr.0) 报文" do
      pkt = NetworkInfraUtility::Probe::BER.encode_get_request(
        version: "2c", community: "public", oid: [1, 3, 6, 1, 2, 1, 1, 1, 0], request_id: 1
      )
      expect(pkt.unpack1("H*")).to eq(
        "302602010104067075626c6963a019020101020100020100300e300c06082b060102010101000500"
      )
      expect(pkt.bytesize).to eq 40
    end
  end

  describe "NTP 报文构造" do
    it "生成 48 字节客户端报文" do
      pkt = NetworkInfraUtility::Probe::NtpProbe.new("1.1.1.1").send(:build_packet, 4)
      expect(pkt.bytesize).to eq 48
      expect(pkt.getbyte(0)).to eq 0x23 # LI=0, VN=4, Mode=3
    end
  end

  describe "RADIUS 报文构造" do
    it "Access-Request 长度字段与报文长度一致" do
      pkt = NetworkInfraUtility::Probe::RadiusProbe.new("1.1.1.1").send(:build_access_request, "probe")
      expect(pkt.getbyte(0)).to eq 1 # Code = Access-Request
      expect(pkt.byteslice(2, 2).unpack1("n")).to eq pkt.bytesize
    end
  end
end
