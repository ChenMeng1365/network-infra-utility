# frozen_string_literal: true

# spec/support/basic/ipv4_address_spec.rb —— IPv4 / IPv4Mask 全功能测试
require "network"

RSpec.describe IPv4 do
  #---- 解析 ----
  describe "解析" do
    it "十进制点分" do
      ip = IPv4.new("10.37.214.42")
      expect(ip.numbers).to eq [10, 37, 214, 42]
      expect(ip.number).to eq 170_251_818
    end

    it "0x 十六进制前缀（整体前缀，后续段纯十六进制）" do
      ip = IPv4.new("0x0a.0.0.1")
      expect(ip.to_d).to eq "10.0.0.1"
    end

    it "0b 二进制前缀" do
      ip = IPv4.new("0b00001010.0.0.1111")
      expect(ip.to_d).to eq "10.0.0.15"
    end

    it "0d 显式十进制前缀" do
      ip = IPv4.new("0d10.0.0.1")
      expect(ip.to_d).to eq "10.0.0.1"
    end

    it "非法格式 warn 且 numbers 为 nil" do
      expect { ip = IPv4.new("nonip") }.to output(/Abnormal/).to_stderr
      ip = IPv4.new("nonip")
      expect(ip.numbers).to be_nil
    end

    it "段超范围 warn 且 number 为 nil" do
      expect { IPv4.new("999.1.1.1") }.to output(/Abnormal/).to_stderr
      expect(IPv4.new("10.0.0.999").number).to be_nil
    end

    it "段数不足 warn" do
      expect { IPv4.new("10.0.0") }.to output(/Abnormal/).to_stderr
    end
  end

  #---- 输出格式 ----
  describe "输出格式" do
    subject(:ip) { IPv4.new("10.37.214.42") }

    it { expect(ip.to_a).to eq [10, 37, 214, 42] }
    it { expect(ip.to_d).to eq "10.37.214.42" }
    it { expect(ip.to_h).to eq "0a.25.d6.2a" }
    it { expect(ip.to_b).to eq "00001010.00100101.11010110.00101010" }
    it { expect(ip.to_s).to eq "10.37.214.42" }
  end

  #---- 算术运算 ----
  describe "算术运算（非破坏性）" do
    it "+ 不修改自身" do
      a = IPv4.new("10.0.0.5")
      b = a + 10
      expect(a.to_d).to eq "10.0.0.5"
      expect(b.to_d).to eq "10.0.0.15"
    end

    it "- 不修改自身" do
      b = IPv4.new("10.0.0.15")
      c = b - 3
      expect(b.to_d).to eq "10.0.0.15"
      expect(c.to_d).to eq "10.0.0.12"
    end

    it "回绕 1.0.0.0 - 1 = 0.255.255.255" do
      expect((IPv4.new("1.0.0.0") - 1).to_d).to eq "0.255.255.255"
    end

    it "+ IPv4 对象（取其 number）" do
      a = IPv4.new("10.0.0.0")
      b = IPv4.new("0.0.0.5")
      expect((a + b).to_d).to eq "10.0.0.5"
    end

    it "链式累加不污染中间值" do
      base = IPv4.new("10.0.0.0")
      r = [base + 1, base + 2, base + 3]
      expect(r.map(&:to_d)).to eq ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
      expect(base.to_d).to eq "10.0.0.0"
    end
  end

  #---- 位运算 ----
  describe "按位与 &" do
    it "与 IPv4 掩码对象相与" do
      ip = IPv4.new("10.37.214.42")
      mask = IPv4Mask.number(24)
      expect((ip & mask).to_d).to eq "10.37.214.0"
    end

    it "与 Integer 前缀长度相与" do
      ip = IPv4.new("10.37.214.42")
      expect((ip & 24).to_d).to eq "10.37.214.0"
      expect((ip & 16).to_d).to eq "10.37.0.0"
      expect((ip & 8).to_d).to eq "10.0.0.0"
    end

    it "与非 IPv4/Integer 返回 self" do
      ip = IPv4.new("10.0.0.1")
      expect(ip & "foo").to equal(ip)
    end
  end

  #---- delegation 子网划分 ----
  describe "delegation 子网划分" do
    it "/24 划 /26 得 4 个子网" do
      base = IPv4.new("192.168.1.0")
      subs = base.delegation(24, 26)
      expect(subs.size).to eq 4
      expect(subs.map { |ip, _| ip.to_d }).to eq [
        "192.168.1.0", "192.168.1.64", "192.168.1.128", "192.168.1.192"
      ]
      expect(subs.all? { |_, m| m.mask_counter == 26 }).to be true
    end

    it "/24 划 /25 得 2 个子网" do
      subs = IPv4.new("192.168.1.0").delegation(24, 25)
      expect(subs.size).to eq 2
    end

    it "base_len >= sub_len 返回空" do
      expect(IPv4.new("10.0.0.0").delegation(24, 24)).to eq []
      expect(IPv4.new("10.0.0.0").delegation(24, 20)).to eq []
    end

    it "长度超 32 返回空" do
      expect(IPv4.new("10.0.0.0").delegation(24, 33)).to eq []
    end
  end

  #---- 地址分类 ----
  describe "地址分类" do
    it "A 类 10.0.0.1" do
      expect(IPv4.new("10.0.0.1").class_a?).to be true
      expect(IPv4.new("10.0.0.1").is_class_a?).to be true
    end
    it "B 类 150.1.2.3" do
      expect(IPv4.new("150.1.2.3").class_b?).to be true
    end
    it "C 类 200.1.2.3" do
      expect(IPv4.new("200.1.2.3").class_c?).to be true
    end
    it "D 类 230.0.0.1" do
      expect(IPv4.new("230.0.0.1").class_d?).to be true
    end
    it "E 类 245.0.0.1" do
      expect(IPv4.new("245.0.0.1").class_e?).to be true
    end
    it "非 A 类 200.1.2.3" do
      expect(IPv4.new("200.1.2.3").class_a?).to be false
    end
  end

  describe "私有/特殊地址" do
    it "私有 10/8" do
      expect(IPv4.new("10.255.255.255").private?).to be true
      expect(IPv4.new("10.255.255.255").is_private?).to be true
    end
    it "私有 172.16/12" do
      expect(IPv4.new("172.16.0.1").private?).to be true
      expect(IPv4.new("172.31.255.255").private?).to be true
    end
    it "私有 192.168/16" do
      expect(IPv4.new("192.168.1.1").private?).to be true
    end
    it "公网 8.8.8.8 非私有" do
      expect(IPv4.new("8.8.8.8").private?).to be false
    end
    it "环回 127.0.0.1" do
      expect(IPv4.new("127.0.0.1").loopback?).to be true
      expect(IPv4.new("126.255.255.255").loopback?).to be false
    end
    it "special? 含 127.0.0.1 / 255.255.255.255 / 0.0.0.0" do
      expect(IPv4.new("127.0.0.1").special?).to be true
      expect(IPv4.new("255.255.255.255").special?).to be true
      expect(IPv4.new("0.0.0.0").special?).to be true
      expect(IPv4.new("8.8.8.8").special?).to be false
    end
    it "is_another? 兼容别名" do
      expect(IPv4.new("0.0.0.0").is_another?).to be true
    end
  end

  #---- 掩码判定 ----
  describe "掩码判定" do
    it "mask? 合法掩码" do
      expect(IPv4.new("255.255.255.0").mask?).to be true
      expect(IPv4.new("255.255.128.0").mask?).to be true
      expect(IPv4.new("255.255.255.255").mask?).to be true
      expect(IPv4.new("0.0.0.0").mask?).to be true
    end
    it "mask? 非法掩码" do
      expect(IPv4.new("10.0.0.1").mask?).to be false
      expect(IPv4.new("255.255.0.255").mask?).to be false
    end
    it "is_mask? 兼容别名" do
      expect(IPv4.new("255.255.255.0").is_mask?).to be true
    end

    it "anti_mask? 合法反掩码" do
      expect(IPv4.new("0.0.0.255").anti_mask?).to be true
      expect(IPv4.new("0.255.255.255").anti_mask?).to be true
    end
    it "anti_mask? 非法" do
      expect(IPv4.new("255.0.0.0").anti_mask?).to be false
    end

    it "mask_counter 前缀长度" do
      expect(IPv4.new("255.255.255.0").mask_counter).to eq 24
      expect(IPv4.new("255.255.128.0").mask_counter).to eq 17
      expect(IPv4.new("255.0.0.0").mask_counter).to eq 8
      expect(IPv4.new("255.255.255.255").mask_counter).to eq 32
      expect(IPv4.new("0.0.0.0").mask_counter).to eq 0
    end
    it "mask_counter 非掩码返回 nil" do
      expect(IPv4.new("10.0.0.1").mask_counter).to be_nil
    end

    it "anti_mask_counter 反掩码尾部1个数" do
      expect(IPv4.new("0.0.0.255").anti_mask_counter).to eq 8
      expect(IPv4.new("0.255.255.255").anti_mask_counter).to eq 24
      expect(IPv4.new("0.0.0.0").anti_mask_counter).to eq 0
      expect(IPv4.new("10.0.0.1").anti_mask_counter).to be_nil
    end

    it "anti_mask 掩码转反掩码" do
      expect(IPv4.new("255.255.255.0").anti_mask.to_d).to eq "0.0.0.255"
      expect(IPv4.new("255.0.0.0").anti_mask.to_d).to eq "0.255.255.255"
      expect(IPv4.new("10.0.0.1").anti_mask).to be_nil
    end
    it "mask 反掩码转掩码" do
      expect(IPv4.new("0.0.0.255").mask.to_d).to eq "255.255.255.0"
      expect(IPv4.new("0.255.255.255").mask.to_d).to eq "255.0.0.0"
    end
  end

  #---- 网络/范围 ----
  describe "网络与范围" do
    it "network_with 网络地址" do
      ip = IPv4.new("10.37.214.42")
      expect(ip.network_with(IPv4Mask.number(24)).to_d).to eq "10.37.214.0"
      expect(ip.network_with(IPv4Mask.number(16)).to_d).to eq "10.37.0.0"
    end

    it "range_with /22 含网络地址与广播地址" do
      ip = IPv4.new("1.0.4.0")
      s, e = ip.range_with(IPv4Mask.number(22))
      expect(s.to_d).to eq "1.0.4.0"
      expect(e.to_d).to eq "1.0.7.255"
    end
    it "range_with /32 返回 [self, self]" do
      ip = IPv4.new("8.8.8.8")
      s, e = ip.range_with(IPv4Mask.number(32))
      expect(s.to_d).to eq "8.8.8.8"
      expect(e.to_d).to eq "8.8.8.8"
    end
    it "range_with /24" do
      s, e = IPv4.new("10.0.0.5").range_with(IPv4Mask.number(24))
      expect(s.to_d).to eq "10.0.0.0"
      expect(e.to_d).to eq "10.0.0.255"
    end

    it "network_with? 网络地址判定" do
      expect(IPv4.new("1.0.4.0").network_with?(IPv4Mask.number(22))).to be true
      expect(IPv4.new("1.0.4.5").network_with?(IPv4Mask.number(22))).to be false
      expect(IPv4.new("1.0.4.0").is_network_with?(IPv4Mask.number(22))).to be true
    end

    it "prefix_with 公共前缀长度" do
      a = IPv4.new("10.0.0.1")
      b = IPv4.new("10.0.1.1")
      expect(a.prefix_with(b)).to eq 23
      expect(IPv4.new("10.0.0.1").prefix_with(IPv4.new("10.0.0.1"))).to eq 32
      expect(IPv4.new("10.0.0.1").prefix_with(IPv4.new("11.0.0.1"))).to eq 7
    end
  end

  #---- Comparable ----
  describe "Comparable 排序" do
    it "sort 升序" do
      arr = [IPv4.new("10.0.0.3"), IPv4.new("10.0.0.1"), IPv4.new("10.0.0.2")]
      expect(arr.sort.map(&:to_d)).to eq ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
    end
    it "<=> 与 between?" do
      expect(IPv4.new("10.0.0.2")).to be > IPv4.new("10.0.0.1")
      expect(IPv4.new("10.0.0.2")).to be < IPv4.new("10.0.0.3")
      expect(IPv4.new("10.0.0.2").between?(IPv4.new("10.0.0.1"), IPv4.new("10.0.0.3"))).to be true
    end
  end
end

RSpec.describe IPv4Mask do
  describe ".number" do
    it { expect(IPv4Mask.number(24).to_d).to eq "255.255.255.0" }
    it { expect(IPv4Mask.number(8).to_d).to eq "255.0.0.0" }
    it { expect(IPv4Mask.number(32).to_d).to eq "255.255.255.255" }
    it { expect(IPv4Mask.number(0).to_d).to eq "0.0.0.0" }
    it { expect(IPv4Mask.number(17).to_d).to eq "255.255.128.0" }
    it "越界抛 ArgumentError" do
      expect { IPv4Mask.number(33) }.to raise_error(ArgumentError)
      expect { IPv4Mask.number(-1) }.to raise_error(ArgumentError)
    end
  end

  describe ".anti_number" do
    it { expect(IPv4Mask.anti_number(24).to_d).to eq "0.0.0.255" }
    it { expect(IPv4Mask.anti_number(0).to_d).to eq "255.255.255.255" }
    it { expect(IPv4Mask.anti_number(32).to_d).to eq "0.0.0.0" }
  end

  describe ".string" do
    it { expect(IPv4Mask.string("255.255.255.0").to_d).to eq "255.255.255.0" }
    it "非法掩码抛异常" do
      expect { IPv4Mask.string("255.255.0.255") }.to raise_error(RuntimeError)
    end
  end

  describe ".anti_string" do
    it { expect(IPv4Mask.anti_string("0.0.0.255").to_d).to eq "0.0.0.255" }
    it "非反掩码抛异常" do
      expect { IPv4Mask.anti_string("255.255.255.0") }.to raise_error(RuntimeError)
    end
  end
end
