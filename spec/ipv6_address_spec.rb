# frozen_string_literal: true

# spec/ipv6_address_spec.rb —— IPv6 / IPv6Mask 全功能测试
require "network"

RSpec.describe IPv6 do
  #---- 解析 ----
  describe "解析" do
    it ":: 压缩形式" do
      ip = IPv6.new("::1")
      expect(ip.numbers.size).to eq 8
      expect(ip.number).to eq 1
    end
    it "完整 8 段" do
      ip = IPv6.new("2001:0db8:0000:0000:0000:0000:0000:0001")
      expect(ip.numbers).to eq [0x2001, 0x0db8, 0, 0, 0, 0, 0, 1]
    end
    it "混合压缩 2001:db8::1" do
      ip = IPv6.new("2001:db8::1")
      expect(ip.numbers[0]).to eq 0x2001
      expect(ip.numbers[7]).to eq 1
    end
    it "全 0 ::" do
      ip = IPv6.new("::")
      expect(ip.number).to eq 0
    end
    it "Cloudflare DNS 2606:4700:4700::1111" do
      ip = IPv6.new("2606:4700:4700::1111")
      expect(ip.numbers[0]).to eq 0x2606
      expect(ip.numbers[2]).to eq 0x4700
    end

    it "非法地址抛异常" do
      expect { IPv6.new("gggg::1") }.to raise_error(RuntimeError)
    end
    it "空串抛异常" do
      expect { IPv6.new("") }.to raise_error(RuntimeError)
    end
  end

  #---- 输出格式 ----
  describe "输出格式" do
    let(:ip) { IPv6.new("2001:db8::1") }

    it "to_a 8 段" do
      expect(ip.to_a.size).to eq 8
    end
    it "to_h 完整十六进制" do
      expect(ip.to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0001"
    end
    it "to_b 完整二进制含分隔符" do
      expect(ip.to_b.split(":").size).to eq 8
      expect(ip.to_b.gsub(":", "").length).to eq 128
    end
    it "to_d 十进制段" do
      expect(ip.to_d.split(":").size).to eq 8
    end
    it "to_s 压缩形式" do
      expect(ip.to_s).to eq "2001:db8::1"
    end
    it "to_s_full = to_h" do
      expect(ip.to_s_full).to eq ip.to_h
    end
    it "to_s_short 别名 = to_s" do
      expect(ip.to_s_short).to eq ip.to_s
    end
  end

  #---- 算术运算 ----
  describe "算术运算（非破坏性）" do
    it "+ 不修改自身" do
      a = IPv6.new("::10")
      b = a + 5
      expect(a.number).to eq 0x10
      expect(b.number).to eq 0x15
    end
    it "- 不修改自身" do
      a = IPv6.new("::15")
      b = a - 5
      expect(a.number).to eq 0x15
      expect(b.number).to eq 0x10
    end
    it "负数回绕 ::0 - 1" do
      expect((IPv6.new("::") - 1).to_h).to eq "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
    end
    it "+ IPv6 对象" do
      a = IPv6.new("2001:db8::")
      b = IPv6.new("::1")
      expect((a + b).to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0001"
    end
  end

  #---- 位运算 ----
  describe "按位与 &" do
    it "与 IPv6 掩码对象" do
      ip = IPv6.new("2001:db8::abcd")
      mask = IPv6Mask.number(64)
      expect((ip & mask).to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0000"
    end
    it "与 Integer 前缀长度" do
      ip = IPv6.new("2001:db8::abcd")
      expect((ip & 64).to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0000"
      expect((ip & 32).to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0000"
    end
    it "与非 IPv6/Integer 返回 self" do
      ip = IPv6.new("::1")
      expect(ip & "foo").to equal(ip)
    end
  end

  #---- delegation 子网划分 ----
  describe "delegation 子网划分" do
    it "/48 划 /64 验证首尾子网（用小样本避免 65536 全量构造）" do
      # delegation 内部会构造 2^(64-48)=65536 个，这里仅验证参数校验与小划分
      subs = IPv6.new("2001:db8::").delegation(124, 126)
      expect(subs.count).to eq 4
      expect(subs.first[0].to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0000"
      expect(subs.last[0].to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:000c"
    end
    it "/64 划 /120 得 2^56 不适用（验证参数校验）" do
      # 这种巨型划分会消耗大量内存，只验证校验逻辑
      expect(IPv6.new("::1").delegation(64, 64)).to eq []
      expect(IPv6.new("::1").delegation(70, 64)).to eq []
      expect(IPv6.new("::1").delegation(125, 129)).to eq []
    end
    it "正常小划分 /124 划 /126" do
      subs = IPv6.new("2001:db8::").delegation(124, 126)
      expect(subs.size).to eq 4
      expect(subs.all? { |_, m| m.mask_counter == 126 }).to be true
    end
  end

  #---- 掩码判定 ----
  describe "掩码判定" do
    it "mask? 合法掩码" do
      expect(IPv6Mask.number(64).mask?).to be true
      expect(IPv6Mask.number(0).mask?).to be true
      expect(IPv6Mask.number(128).mask?).to be true
      expect(IPv6.new("2001:db8::1").mask?).to be false
    end
    it "is_mask? 兼容别名" do
      expect(IPv6Mask.number(64).is_mask?).to be true
    end

    it "anti_mask? 合法反掩码" do
      expect(IPv6Mask.anti_number(64).anti_mask?).to be true
      expect(IPv6Mask.anti_number(0).anti_mask?).to be true
    end

    it "mask_counter 前缀长度" do
      expect(IPv6Mask.number(64).mask_counter).to eq 64
      expect(IPv6Mask.number(48).mask_counter).to eq 48
      expect(IPv6Mask.number(0).mask_counter).to eq 0
      expect(IPv6Mask.number(128).mask_counter).to eq 128
    end
    it "mask_counter 非掩码返回 nil" do
      expect(IPv6.new("::1").mask_counter).to be_nil
    end

    it "anti_mask_counter" do
      expect(IPv6Mask.anti_number(64).anti_mask_counter).to eq 64
      expect(IPv6Mask.anti_number(0).anti_mask_counter).to eq 128
    end

    it "anti_mask 掩码转反掩码" do
      expect(IPv6Mask.number(64).anti_mask.anti_mask_counter).to eq 64
      expect(IPv6.new("::1").anti_mask).to be_nil
    end
    it "mask 反掩码转掩码" do
      expect(IPv6Mask.anti_number(64).mask.mask_counter).to eq 64
    end
  end

  #---- 网络/范围 ----
  describe "网络与范围" do
    it "network_with 网络地址" do
      ip = IPv6.new("2001:db8::abcd")
      expect(ip.network_with(IPv6Mask.number(64)).to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0000"
    end

    it "range_with /64 含两端" do
      s, e = IPv6.new("2001:db8::").range_with(IPv6Mask.number(64))
      expect(s.to_h).to eq "2001:0db8:0000:0000:0000:0000:0000:0000"
      expect(e.to_h).to eq "2001:0db8:0000:0000:ffff:ffff:ffff:ffff"
    end
    it "range_with /128 返回 [self, self]" do
      ip = IPv6.new("::1")
      s, e = ip.range_with(IPv6Mask.number(128))
      expect(s.to_h).to eq "0000:0000:0000:0000:0000:0000:0000:0001"
      expect(e.to_h).to eq "0000:0000:0000:0000:0000:0000:0000:0001"
    end
    it "range_with /0 全范围" do
      s, e = IPv6.new("::").range_with(IPv6Mask.number(0))
      expect(s.number).to eq 0
      expect(e.to_h).to eq "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"
    end

    it "network_with? 网络地址判定" do
      expect(IPv6.new("2001:db8::").network_with?(IPv6Mask.number(64))).to be true
      expect(IPv6.new("2001:db8::1").network_with?(IPv6Mask.number(64))).to be false
    end

    it "prefix_with 公共前缀" do
      a = IPv6.new("2001:db8::1")
      b = IPv6.new("2001:db8::2")
      expect(a.prefix_with(b)).to eq 126
      expect(IPv6.new("::1").prefix_with(IPv6.new("::1"))).to eq 128
      expect(IPv6.new("2001:db8::1").prefix_with(IPv6.new("2002:db8::1"))).to eq 14
    end
  end

  #---- Comparable ----
  describe "Comparable 排序" do
    it "sort 升序" do
      arr = [IPv6.new("::3"), IPv6.new("::1"), IPv6.new("::2")]
      expect(arr.sort.map(&:number)).to eq [1, 2, 3]
    end
    it "between?" do
      expect(IPv6.new("::2").between?(IPv6.new("::1"), IPv6.new("::3"))).to be true
    end
  end
end

RSpec.describe IPv6Mask do
  describe ".number" do
    it { expect(IPv6Mask.number(64).to_h).to eq "ffff:ffff:ffff:ffff:0000:0000:0000:0000" }
    it { expect(IPv6Mask.number(0).to_h).to eq "0000:0000:0000:0000:0000:0000:0000:0000" }
    it { expect(IPv6Mask.number(128).to_h).to eq "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" }
    it { expect(IPv6Mask.number(32).to_h).to eq "ffff:ffff:0000:0000:0000:0000:0000:0000" }
    it "越界抛 ArgumentError" do
      expect { IPv6Mask.number(129) }.to raise_error(ArgumentError)
      expect { IPv6Mask.number(-1) }.to raise_error(ArgumentError)
    end
  end

  describe ".anti_number" do
    it { expect(IPv6Mask.anti_number(64).to_h).to eq "0000:0000:0000:0000:ffff:ffff:ffff:ffff" }
    it { expect(IPv6Mask.anti_number(0).to_h).to eq "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" }
    it { expect(IPv6Mask.anti_number(128).to_h).to eq "0000:0000:0000:0000:0000:0000:0000:0000" }
  end

  describe ".string" do
    it { expect(IPv6Mask.string("ffff:ffff:ffff:ffff::").to_h).to eq "ffff:ffff:ffff:ffff:0000:0000:0000:0000" }
    it "非法掩码抛异常" do
      expect { IPv6Mask.string("::1") }.to raise_error(RuntimeError)
    end
  end

  describe ".anti_string" do
    it { expect(IPv6Mask.anti_string("::ffff:ffff:ffff:ffff").anti_mask_counter).to eq 64 }
    it "非反掩码抛异常" do
      expect { IPv6Mask.anti_string("ffff::") }.to raise_error(RuntimeError)
    end
  end
end
