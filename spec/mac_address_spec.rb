# frozen_string_literal: true

# spec/support/basic/mac_address_spec.rb —— MacAddress / MAC 全功能测试
require "network"

RSpec.describe MacAddress do
  # ---- 解析 ----
  describe "解析" do
    it "6 段 - 分隔" do
      mac = MacAddress.new("00-1A-2B-3C-4D-5E")
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "6 段 : 分隔" do
      mac = MacAddress.new("00:1A:2B:3C:4D:5E")
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "3 段 . 分隔（Cisco 格式）" do
      mac = MacAddress.new("001A.2B3C.4D5E")
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "3 段 - 分隔（部分设备写法）" do
      mac = MacAddress.new("001A-2B3C-4D5E")
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "无分隔符 12 位 hex" do
      mac = MacAddress.new("001A2B3C4D5E")
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "Array 字符串段" do
      mac = MacAddress.new(["00", "1A", "2B", "3C", "4D", "5E"])
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "Array 整数段" do
      mac = MacAddress.new([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "Integer 输入" do
      mac = MacAddress.new(0x001A2B3C4D5E)
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "number 属性为 48 位整数" do
      mac = MacAddress.new("00-1A-2B-3C-4D-5E")
      expect(mac.number).to eq 0x001A2B3C4D5E
    end

    it "大小写混合" do
      mac = MacAddress.new("00-1a-2B-3c-4D-5e")
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "去除前后空白" do
      mac = MacAddress.new("  00:1A:2B:3C:4D:5E  ")
      expect(mac.numbers).to eq [0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]
    end

    it "非法格式抛异常" do
      expect { MacAddress.new("GG-1A-2B-3C-4D-5E") }.to raise_error(ArgumentError)
    end

    it "段数错误抛异常" do
      expect { MacAddress.new("00-1A-2B-3C") }.to raise_error(ArgumentError)
    end

    it "整数超 48 位范围抛异常" do
      expect { MacAddress.new(0x1000000000000) }.to raise_error(ArgumentError)
    end

    it "不支持的类型抛异常" do
      expect { MacAddress.new(nil) }.to raise_error(ArgumentError)
    end
  end

  # ---- 输出格式 ----
  describe "输出格式" do
    subject(:mac) { MacAddress.new("00-1A-2B-3C-4D-5E") }

    it "to_s 默认 - 6 组" do
      expect(mac.to_s).to eq "00-1a-2b-3c-4d-5e"
    end

    it "to_hex : 6 组" do
      expect(mac.to_hex(":", 6)).to eq "00:1a:2b:3c:4d:5e"
    end

    it "to_hex . 3 组（Cisco 格式）" do
      expect(mac.to_hex(".", 3)).to eq "001a.2b3c.4d5e"
    end

    it "to_hex 无分隔符" do
      expect(mac.to_hex("", 6)).to eq "001a2b3c4d5e"
    end

    it "to_hex 1 组" do
      expect(mac.to_hex("", 1)).to eq "001a2b3c4d5e"
    end

    it "to_upcase 大写" do
      expect(mac.to_upcase(":", 6)).to eq "00:1A:2B:3C:4D:5E"
    end

    it "to_downcase 小写" do
      expect(mac.to_downcase("-", 6)).to eq "00-1a-2b-3c-4d-5e"
    end

    it "非法 groups 抛异常" do
      expect { mac.to_hex("-", 5) }.to raise_error(ArgumentError)
    end
  end

  # ---- 属性判定 ----
  describe "属性判定" do
    it "multicast? bit0=1 为组播" do
      expect(MacAddress.new("01-00-5E-00-00-01").multicast?).to be true
    end

    it "multicast? bit0=0 为单播" do
      expect(MacAddress.new("00-1A-2B-3C-4D-5E").multicast?).to be false
    end

    it "locally_administered? bit1=1 为本地分配" do
      expect(MacAddress.new("02-00-00-00-00-01").locally_administered?).to be true
    end

    it "locally_administered? bit1=0 为全球分配" do
      expect(MacAddress.new("00-1A-2B-3C-4D-5E").locally_administered?).to be false
    end

    it "universally_administered? 为 locally_administered? 取反" do
      expect(MacAddress.new("00-1A-2B-3C-4D-5E").universally_administered?).to be true
      expect(MacAddress.new("02-00-00-00-00-01").universally_administered?).to be false
    end

    it "broadcast? 全 1" do
      expect(MacAddress.new("FF-FF-FF-FF-FF-FF").broadcast?).to be true
    end

    it "zero? 全 0" do
      expect(MacAddress.new("00-00-00-00-00-00").zero?).to be true
    end

    it "OUI 前 3 字节" do
      expect(MacAddress.new("00-1A-2B-3C-4D-5E").oui).to eq "00-1a-2b"
    end

    it "NIC 后 3 字节" do
      expect(MacAddress.new("00-1A-2B-3C-4D-5E").nic).to eq "3c-4d-5e"
    end
  end

  # ---- EUI-64 ----
  describe "EUI-64 / SLAAC" do
    subject(:mac) { MacAddress.new("00-1A-2B-3C-4D-5E") }

    it "to_eui64 插入 FF:FE" do
      expect(mac.to_eui64).to eq [0x00, 0x1A, 0x2B, 0xFF, 0xFE, 0x3C, 0x4D, 0x5E]
    end

    it "to_eui64_s 默认冒号分隔" do
      expect(mac.to_eui64_s).to eq "00:1a:2b:ff:fe:3c:4d:5e"
    end

    it "to_interface_id 翻转 U/L 位" do
      expect(mac.to_interface_id).to eq [0x02, 0x1A, 0x2B, 0xFF, 0xFE, 0x3C, 0x4D, 0x5E]
    end

    it "to_interface_id_s" do
      expect(mac.to_interface_id_s).to eq "02:1a:2b:ff:fe:3c:4d:5e"
    end

    it "EUI-64 长度为 8" do
      expect(mac.to_eui64.size).to eq 8
    end
  end

  # ---- Comparable ----
  describe "Comparable 排序" do
    it "支持 < > 比较" do
      expect(MacAddress.new("00-00-00-00-00-01")).to be < MacAddress.new("00-00-00-00-00-02")
    end

    it "支持 == 比较" do
      expect(MacAddress.new("00:1A:2B:3C:4D:5E")).to eq MacAddress.new("00-1A-2B-3C-4D-5E")
    end

    it "支持排序" do
      arr = [MacAddress.new("FF-FF-FF-FF-FF-FF"), MacAddress.new("00-00-00-00-00-00"), MacAddress.new("00-1A-2B-3C-4D-5E")]
      expect(arr.sort.map(&:number)).to eq [0, 0x001A2B3C4D5E, 0xFFFFFFFFFFFF]
    end
  end

  # ---- Hash key ----
  describe "Hash key" do
    it "相同 MAC hash 一致" do
      expect(MacAddress.new("00:1A:2B:3C:4D:5E").hash).to eq MacAddress.new("00-1A-2B-3C-4D-5E").hash
    end

    it "可作为 Hash key" do
      h = { MacAddress.new("00-00-00-00-00-01") => "a", MacAddress.new("00-00-00-00-00-02") => "b" }
      expect(h[MacAddress.new("00:00:00:00:00:01")]).to eq "a"
    end
  end

  # ---- 兼容原接口 ----
  describe "兼容原接口" do
    it "writing 默认 3 组 - 分隔" do
      mac = MacAddress.new("00-1A-2B-3C-4D-5E")
      expect(mac.writing).to eq "001a-2b3c-4d5e"
    end

    it "writing 6 组冒号" do
      mac = MacAddress.new("00-1A-2B-3C-4D-5E")
      expect(mac.writing(6, ":")).to eq "00:1a:2b:3c:4d:5e"
    end

    it "writing >=6 归 6" do
      mac = MacAddress.new("00-1A-2B-3C-4D-5E")
      expect(mac.writing(10, "-")).to eq "00-1a-2b-3c-4d-5e"
    end
  end
end

RSpec.describe MAC, ".address" do
  it "字符串 : 分隔" do
    expect(MAC.address("00:1A:2B:3C:4D:5E").number).to eq 0x001A2B3C4D5E
  end

  it "3 段 . 分隔" do
    expect(MAC.address("001A.2B3C.4D5E").number).to eq 0x001A2B3C4D5E
  end

  it "3 段 - 分隔" do
    expect(MAC.address("001A-2B3C-4D5E").number).to eq 0x001A2B3C4D5E
  end

  it "Integer" do
    expect(MAC.address(0x001A2B3C4D5E).number).to eq 0x001A2B3C4D5E
  end

  it "Array" do
    expect(MAC.address([0, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]).number).to eq 0x001A2B3C4D5E
  end

  it "不同格式等价" do
    a = MAC.address("00:1A:2B:3C:4D:5E")
    b = MAC.address("001A.2B3C.4D5E")
    c = MAC.address("001A-2B3C-4D5E")
    d = MAC.address("001A2B3C4D5E")
    expect(a).to eq b
    expect(a).to eq c
    expect(a).to eq d
  end
end

RSpec.describe MacAddress, ".valid?" do
  it "合法 MAC 返回 true" do
    expect(MacAddress.valid?("00:1A:2B:3C:4D:5E")).to be true
  end

  it "非法 MAC 返回 false" do
    expect(MacAddress.valid?("GG:1A:2B:3C:4D:5E")).to be false
  end
end
