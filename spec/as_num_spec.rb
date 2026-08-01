# frozen_string_literal: true

# spec/support/basic/as_num_spec.rb —— ASNum 全功能测试
require "network"

RSpec.describe ASNum do
  # ---- 解析 ----
  describe "解析" do
    it "asplain 字符串" do
      as = ASNum.new("65546")
      expect(as.to_i).to eq 65546
    end

    it "asdot 字符串" do
      as = ASNum.new("1.10")
      expect(as.to_i).to eq 65546
    end

    it "Integer 输入" do
      as = ASNum.new(65546)
      expect(as.to_i).to eq 65546
    end

    it "asdot 高低位分解正确" do
      as = ASNum.new("1.10")
      expect(as.high).to eq 1
      expect(as.low).to eq 10
    end

    it "plain 32 位号高位正确" do
      as = ASNum.new("4259860001")
      expect(as.high).to eq 65000
      expect(as.low).to eq 20001
    end

    it "16 位号 high 为 0" do
      as = ASNum.new("100")
      expect(as.high).to eq 0
      expect(as.low).to eq 100
    end

    it "去除字符串前后空白" do
      expect(ASNum.new("  65546  ").to_i).to eq 65546
    end

    it "非法字符串抛异常" do
      expect { ASNum.new("abc") }.to raise_error(ArgumentError)
    end

    it "asdot 段超范围抛异常" do
      expect { ASNum.new("70000.1") }.to raise_error(ArgumentError)
      expect { ASNum.new("1.70000") }.to raise_error(ArgumentError)
    end

    it "数值超 32 位范围抛异常" do
      expect { ASNum.new(4_294_967_296) }.to raise_error(ArgumentError)
    end

    it "负数抛异常" do
      expect { ASNum.new(-1) }.to raise_error(ArgumentError)
    end

    it "不支持的类型抛异常" do
      expect { ASNum.new(nil) }.to raise_error(ArgumentError)
      expect { ASNum.new([]) }.to raise_error(ArgumentError)
    end
  end

  # ---- 格式输出 ----
  describe "格式输出" do
    it "to_plain 返回纯十进制串" do
      expect(ASNum.new("1.10").to_plain).to eq "65546"
    end

    it "to_dot 16 位内无点" do
      expect(ASNum.new("100").to_dot).to eq "100"
      expect(ASNum.new("65535").to_dot).to eq "65535"
    end

    it "to_dot 32 位带点" do
      expect(ASNum.new("65546").to_dot).to eq "1.10"
      expect(ASNum.new("4259860001").to_dot).to eq "65000.20001"
    end

    it "to_s 等于 to_dot" do
      expect(ASNum.new("1.10").to_s).to eq "1.10"
      expect(ASNum.new("100").to_s).to eq "100"
    end

    it "to_i 返回整数" do
      expect(ASNum.new("1.10").to_i).to eq 65546
    end
  end

  # ---- 转: 原有 Bug 复现 ----
  describe "原版 Bug 修正" do
    # Bug 1: 正则未转义点号 → "6a5536" 被误判合法
    it "非数字字符不误判为合法" do
      expect { ASNum.new("6a5536") }.to raise_error(ArgumentError)
    end

    # Bug 2: 原版 ? 方法返回字符串（truthy），导致非法输入 is_public_as? 为 true
    # 现在统一返回布尔值
    it "判定方法始终返回布尔值" do
      as = ASNum.new("100")
      expect(as.public?).to be true
      expect(as.is_public_as?).to be true
      expect(as.is_public_as?).to be_a(Integer).or be_a(TrueClass).or be_a(FalseClass)
    end

    # Bug 3: plain 记法遗漏 32 位范围 → 65536 判 false
    it "65536 asplain 被正确识别为 public" do
      expect(ASNum.new("65536").public?).to be true
    end

    # Bug 4: 16 位保留号缺 65535
    it "65535 被正确识别为 reserved" do
      expect(ASNum.new("65535").reserved?).to be true
    end

    # Bug 6: asdot 段不做范围校验 → 70000.1 拼接错乱
    it "asdot 段超 65535 抛异常" do
      expect { ASNum.new("70000.1") }.to raise_error(ArgumentError)
    end

    # Bug 5: AS_TRANS(23456) 分类矛盾
    context "AS 23456 (AS_TRANS)" do
      subject { ASNum.new("23456") }
      it "被识别为 reserved" do
        expect(subject.reserved?).to be true
      end
      it "不被识别为 public" do
        expect(subject.public?).to be false
      end
    end
  end

  # ---- 类型判定 ----
  describe "类型判定" do
    context "16 位公有 AS" do
      [1, 100, 64511].each do |n|
        it "AS #{n} 是 public" do
          expect(ASNum.new(n).public?).to be true
          expect(ASNum.new(n).type).to eq :public
        end
      end
    end

    context "16 位私有 AS" do
      [64512, 65000, 65534].each do |n|
        it "AS #{n} 是 private" do
          expect(ASNum.new(n).private?).to be true
          expect(ASNum.new(n).type).to eq :private
        end
      end
    end

    context "16 位保留 AS" do
      [0, 23456, 65535].each do |n|
        it "AS #{n} 是 reserved" do
          expect(ASNum.new(n).reserved?).to be true
          expect(ASNum.new(n).type).to eq :reserved
        end
      end
    end

    context "32 位公有 AS" do
      [65536, 1000000, 4199999999].each do |n|
        it "AS #{n} 是 public" do
          expect(ASNum.new(n).public?).to be true
          expect(ASNum.new(n).type).to eq :public
        end
      end
    end

    context "32 位私有 AS" do
      [4200000000, 4250000000, 4294967294].each do |n|
        it "AS #{n} 是 private" do
          expect(ASNum.new(n).private?).to be true
          expect(ASNum.new(n).type).to eq :private
        end
      end
    end

    context "32 位保留 AS" do
      it "AS 4294967295 是 reserved" do
        expect(ASNum.new(4294967295).reserved?).to be true
        expect(ASNum.new(4294967295).type).to eq :reserved
      end
    end

    it "类型互斥：同一 AS 不会同时属于多类" do
      (0..4294967295).step(100_000_000).each do |n|
        as = ASNum.new(n)
        flags = [as.public?, as.private?, as.reserved?].count(true)
        expect(flags).to eq(1)
      end
    end

    it "AS_TRANS (23456) 为 reserved 而非 public" do
      as = ASNum.new(23456)
      expect(as.reserved?).to be true
      expect(as.public?).to be false
    end
  end

  # ---- 位宽判定 ----
  describe "位宽判定" do
    it "16 位号 as2? 为 true" do
      expect(ASNum.new("100").as2?).to be true
      expect(ASNum.new("65535").as2?).to be true
    end

    it "32 位号 as4? 为 true" do
      expect(ASNum.new("65536").as4?).to be true
      expect(ASNum.new("1.10").as4?).to be true
    end

    it "as2? 与 as4? 互斥" do
      expect(ASNum.new("65535").as4?).to be false
      expect(ASNum.new("65536").as2?).to be false
    end
  end

  # ---- 兼容原接口 ----
  describe "兼容原接口" do
    it "is_public_as? 别名" do
      expect(ASNum.new("100").is_public_as?).to be true
      expect(ASNum.new("65536").is_public_as?).to be true
    end

    it "is_private_as? 别名" do
      expect(ASNum.new("64512").is_private_as?).to be true
      expect(ASNum.new("4200000000").is_private_as?).to be true
    end

    it "is_reserved_as? 别名"  do
      expect(ASNum.new("0").is_reserved_as?).to be true
      expect(ASNum.new("23456").is_reserved_as?).to be true
      expect(ASNum.new("65535").is_reserved_as?).to be true
      expect(ASNum.new("4294967295").is_reserved_as?).to be true
    end
  end

  # ---- Comparable ----
  describe "Comparable 排序" do
    it "支持 < > 比较" do
      expect(ASNum.new("100")).to be < ASNum.new("200")
      expect(ASNum.new("200")).to be > ASNum.new("100")
    end

    it "支持 == 比较" do
      expect(ASNum.new("1.10")).to eq ASNum.new("65546")
      expect(ASNum.new("1.10")).to eq ASNum.new(65546)
    end

    it "支持排序" do
      arr = [ASNum.new("300"), ASNum.new("100"), ASNum.new("200")]
      expect(arr.sort.map(&:to_i)).to eq [100, 200, 300]
    end
  end

  # ---- Hash key ----
  describe "Hash key" do
    it "相同 AS 号 hash 一致" do
      expect(ASNum.new("1.10").hash).to eq ASNum.new("65546").hash
    end

    it "可作为 Hash key" do
      h = { ASNum.new("100") => "a", ASNum.new("200") => "b" }
      expect(h[ASNum.new("100")]).to eq "a"
    end
  end

  # ---- asdot ↔ asplain 互换 ----
  describe "记法互换" do
    # asdot → asplain 的转换：asdot 形式输入，查 plain 输出
    # asplain → asdot 的转换：plain 输入，查 dot 输出
    # 两段测试分别按输入→输出方向撰写，不强制双向对称
    {
      "1.10"           => "65546",
      "65000.20001"    => "4259860001",
    }.each do |dot, plain|
      it "#{dot} ↔ #{plain}" do
      expect(ASNum.new(dot).to_plain).to eq plain
      expect(ASNum.new(plain).to_dot).to eq dot
      end
    end

    it "1.23456 → 88992" do
      expect(ASNum.new("1.23456").to_plain).to eq "88992"
    end

    # 16 位号 to_dot 无点（与 asdot 形式不对称，属正常行为）
    it "0.0 输入 -> to_plain 为 0，to_dot 仍为 0" do
      expect(ASNum.new("0.0").to_plain).to eq "0"
      expect(ASNum.new("0.0").to_dot).to eq "0"
    end

    it "0.100 输入 -> to_plain 为 100，to_dot 仍为 100" do
      expect(ASNum.new("0.100").to_plain).to eq "100"
      expect(ASNum.new("0.100").to_dot).to eq "100"
    end
  end
end
