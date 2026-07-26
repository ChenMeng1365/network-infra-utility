# frozen_string_literal: true

# spec/ip_spec.rb —— IP 统一入口模块与 geodb 兼容场景测试
require "network"

RSpec.describe IP do
  #---- IP.v4 ----
  describe ".v4" do
    it "单址返回 IPv4" do
      ip = IP.v4("10.0.0.1")
      expect(ip).to be_a(IPv4)
      expect(ip.to_d).to eq "10.0.0.1"
    end
    it "CIDR 返回 [IPv4, IPv4Mask]" do
      ip, mask = IP.v4("10.0.0.1/24")
      expect(ip).to be_a(IPv4)
      expect(mask).to be_a(IPv4)
      expect(mask.to_d).to eq "255.255.255.0"
      expect(mask.mask_counter).to eq 24
    end
    it "点分十进制掩码形式" do
      ip, mask = IP.v4("10.0.0.1/255.255.255.0")
      expect(mask.to_d).to eq "255.255.255.0"
    end
    it "/32 掩码" do
      ip, mask = IP.v4("8.8.8.8/32")
      expect(mask.to_d).to eq "255.255.255.255"
    end
    it "/0 掩码" do
      ip, mask = IP.v4("0.0.0.0/0")
      expect(mask.to_d).to eq "0.0.0.0"
    end
  end

  #---- IP.v6 ----
  describe ".v6" do
    it "单址返回 IPv6" do
      ip = IP.v6("::1")
      expect(ip).to be_a(IPv6)
      expect(ip.number).to eq 1
    end
    it "CIDR 返回 [IPv6, IPv6Mask]" do
      ip, mask = IP.v6("2001:db8::1/64")
      expect(ip).to be_a(IPv6)
      expect(mask.mask_counter).to eq 64
    end
    it "完整冒号掩码形式" do
      ip, mask = IP.v6("2001:db8::1/ffff:ffff:ffff:ffff::")
      expect(mask.to_h).to eq "ffff:ffff:ffff:ffff:0000:0000:0000:0000"
    end
  end

  #---- IP.range ----
  describe ".range" do
    context "IPv4 CIDR" do
      it "/22 含网络地址与广播地址" do
        s, e = IP.range("1.0.4.0/22")
        expect(s.to_d).to eq "1.0.4.0"
        expect(e.to_d).to eq "1.0.7.255"
      end
      it "/27 边界" do
        s, e = IP.range("133.35.120.80/27")
        expect(s.to_d).to eq "133.35.120.64"
        expect(e.to_d).to eq "133.35.120.95"
      end
      it "/8 大网段" do
        s, e = IP.range("10.0.0.0/8")
        expect(s.to_d).to eq "10.0.0.0"
        expect(e.to_d).to eq "10.255.255.255"
      end
      it "/32 单址" do
        s, e = IP.range("8.8.8.8/32")
        expect(s.to_d).to eq "8.8.8.8"
        expect(e.to_d).to eq "8.8.8.8"
      end
    end

    context "IPv6 CIDR" do
      it "/64 含两端" do
        s, e = IP.range("2001:db8::/64")
        expect(s.to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0000"
        expect(e.to_h).to eq "2001:0db8:0000:0000:ffff:ffff:ffff:ffff"
      end
      it "/0 全范围" do
        s, e = IP.range("::/0")
        expect(s.number).to eq 0
        expect(e.to_h).to eq "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
      end
    end

    context "区间串 start-end" do
      it "IPv4 区间" do
        s, e = IP.range("1.0.4.0-1.0.7.255")
        expect(s.to_d).to eq "1.0.4.0"
        expect(e.to_d).to eq "1.0.7.255"
      end
      it "区间端点为单址" do
        s, e = IP.range("10.0.0.1-10.0.0.10")
        expect(s.to_d).to eq "10.0.0.1"
        expect(e.to_d).to eq "10.0.0.10"
      end
    end

    context "单址（无掩码无连字符）" do
      it "IPv4 单址" do
        s, e = IP.range("8.8.8.8")
        expect(s.to_d).to eq "8.8.8.8"
        expect(e.to_d).to eq "8.8.8.8"
      end
      it "IPv6 单址" do
        s, e = IP.range("::1")
        expect(s.number).to eq 1
        expect(e.number).to eq 1
      end
    end

    it "无法识别的格式抛 ArgumentError" do
      expect { IP.range("#$%") }.to raise_error(ArgumentError)
    end
  end

  #---- IP.cross ----
  describe ".cross 区间相交" do
    it "相交（含于内）" do
      r1 = IP.range("1.0.0.0/24")
      r2 = IP.range("1.0.0.128/25")
      expect(IP.cross(r1, r2)).to be true
    end
    it "相交（部分重叠）" do
      r1 = [IPv4.new("10.0.0.0"), IPv4.new("10.0.0.200")]
      r2 = [IPv4.new("10.0.0.100"), IPv4.new("10.0.0.150")]
      expect(IP.cross(r1, r2)).to be true
    end
    it "相交（端点相接）" do
      r1 = [IPv4.new("10.0.0.0"), IPv4.new("10.0.0.100")]
      r2 = [IPv4.new("10.0.0.100"), IPv4.new("10.0.0.200")]
      expect(IP.cross(r1, r2)).to be true
    end
    it "不相交" do
      r1 = IP.range("1.0.0.0/24")
      r2 = IP.range("2.0.0.0/24")
      expect(IP.cross(r1, r2)).to be false
    end
    it "IPv6 区间相交" do
      r1 = IP.range("2001:db8::/64")
      r2 = [IPv6.new("2001:db8::"), IPv6.new("2001:db8::5")]
      expect(IP.cross(r1, r2)).to be true
    end
  end

  #---- IP.xross ----
  describe ".xross 合并端点" do
    it "IPv4 返回排序去重端点" do
      r1 = IP.range("1.0.0.0/24")
      r2 = IP.range("1.0.1.0/24")
      result = IP.xross(r1, r2)
      expect(result.size).to eq 4
      expect(result).to be_any { |ip| ip.to_d == "1.0.0.0" }
      expect(result).to be_any { |ip| ip.to_d == "1.0.1.255" }
    end
    it "IPv6 option" do
      r1 = IP.range("2001:db8::/127")
      r2 = IP.range("2001:db8::2/127")
      result = IP.xross(r1, r2, :v6)
      expect(result.size).to be >= 2
    end
  end

  #---- geodb 实际调用兼容场景 ----
  describe "geodb 兼容场景" do
    context "geodb.rb:22 IP.range(cidr).map{|ip|ip.number}" do
      it "返回两个 Integer 作为索引键" do
        nums = IP.range("1.0.4.0/22").map { |ip| ip.number }
        expect(nums).to be_an(Array)
        expect(nums.size).to eq 2
        expect(nums.all? { |n| n.is_a?(Integer) }).to be true
        expect(nums[0] < nums[1]).to be true
      end
      it "/22 网段 number 正确" do
        nums = IP.range("1.0.4.0/22").map { |ip| ip.number }
        expect(nums).to eq [16778240, 16779263]
      end
    end

    context "api.rb:88 IP.v4(s).number / IP.v6(s).number" do
      it "IPv4 合法地址返回 Integer" do
        expect(IP.v4("1.2.3.4").number).to eq 16909060
      end
      it "IPv6 合法地址返回 Integer" do
        expect(IP.v6("::1").number).to eq 1
        expect(IP.v6("2606:4700:4700::1111").number).to be_an(Integer)
      end
    end

    context "api.rb:84 非法地址容错" do
      it "非法 IPv4 返回非 Integer（api.rb 转 nil）" do
        expect(IP.v4("999.1.1.1").number).not_to be_an(Integer)
        expect(IP.v4("999.1.1.1").number).to be_nil
      end
      it "非法 IPv6 抛异常（api.rb rescue 兜底）" do
        expect { IP.v6("gggg::1") }.to raise_error(RuntimeError)
      end
    end
  end

  #---- 全进制解析一致性 ----
  describe "进制解析一致性" do
    it "同一地址不同进制相等" do
      a = IP.v4("10.0.0.1")
      b = IPv4.new("0x0a.0.0.1")
      c = IPv4.new("0b00001010.0.0.1")
      expect(a.number).to eq b.number
      expect(a.number).to eq c.number
    end
  end
end
