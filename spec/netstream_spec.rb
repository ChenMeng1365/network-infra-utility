# frozen_string_literal: true

# spec/netstream_spec.rb — NetStream v5/v9 pcap 解析工具测试
require "network"
require "tempfile"

RSpec.describe NetworkInfraUtility::NetStream do
  describe "FieldTypes 字段类型映射" do
    it "包含常用 RFC 3954 字段" do
      ft = NetworkInfraUtility::NetStream::FieldTypes
      expect(ft::FIELD_NAMES[1]).to eq "in_bytes"
      expect(ft::FIELD_NAMES[8]).to eq "ipv4_src_addr"
      expect(ft::FIELD_NAMES[12]).to eq "ipv4_dst_addr"
      expect(ft::FIELD_NAMES[27]).to eq "ipv6_src_addr"
      expect(ft::FIELD_NAMES[60]).to eq "direction"
    end

    it "render_field 将 IPv4 字节渲染为点分十进制" do
      ft = NetworkInfraUtility::NetStream::FieldTypes
      data = "\xc0\xa8\x01\x01".b
      result = ft.render_field(8, 4, data, 0)
      expect(result).to eq("ipv4_src_addr" => "192.168.1.1")
    end

    it "render_field 将 type=0 未知字段命名为 reserved_offN" do
      ft = NetworkInfraUtility::NetStream::FieldTypes
      data = "\x00\x00".b
      result = ft.render_field(0, 2, data, 44)
      expect(result).to eq("reserved_off44" => 0)
    end

    it "render_field 将 1 字节字段渲染为整数" do
      ft = NetworkInfraUtility::NetStream::FieldTypes
      data = "\x06".b
      result = ft.render_field(4, 1, data, 51)
      expect(result).to eq("protocol" => 6)
    end

    it "render_field 将 2 字节字段渲染为大端整数" do
      ft = NetworkInfraUtility::NetStream::FieldTypes
      data = "\x1f\x90".b
      result = ft.render_field(7, 2, data, 36)
      expect(result).to eq("l4_src_port" => 8080)
    end

    it "field_info 返回字段元信息" do
      fi = NetworkInfraUtility::NetStream::FieldTypes.field_info(8, 4)
      expect(fi).to eq(type: 8, length: 4, name: "ipv4_src_addr")
    end
  end

  describe "PredefinedTemplates 预定义模板" do
    it "包含 1315/1316/1505/1501 四个模板" do
      t = NetworkInfraUtility::NetStream::PredefinedTemplates::TEMPLATES
      expect(t.keys).to contain_exactly(1315, 1316, 1505, 1501)
    end

    it "1315 模板总长度为 60 字节" do
      t = NetworkInfraUtility::NetStream::PredefinedTemplates::TEMPLATES[1315]
      total = t[:fields].sum { |_ty, len| len }
      expect(total).to eq 60
    end

    it "1316 模板总长度为 112 字节" do
      t = NetworkInfraUtility::NetStream::PredefinedTemplates::TEMPLATES[1316]
      total = t[:fields].sum { |_ty, len| len }
      expect(total).to eq 112
    end

    it "1505 模板总长度为 84 字节" do
      t = NetworkInfraUtility::NetStream::PredefinedTemplates::TEMPLATES[1505]
      total = t[:fields].sum { |_ty, len| len }
      expect(total).to eq 84
    end

    it "1501 模板总长度为 72 字节" do
      t = NetworkInfraUtility::NetStream::PredefinedTemplates::TEMPLATES[1501]
      total = t[:fields].sum { |_ty, len| len }
      expect(total).to eq 72
    end
  end

  describe "Parser 解析器" do
    it "默认加载预定义模板" do
      parser = described_class::Parser.new
      expect(parser.templates.keys).to include(1315, 1316, 1505, 1501)
      expect(parser.templates[1315][:predefined]).to be true
    end

    it "use_predefined: false 时不加载预定义模板" do
      parser = described_class::Parser.new(use_predefined: false)
      expect(parser.templates).to be_empty
    end

    it "parse 未知版本返回错误" do
      parser = described_class::Parser.new
      payload = "\x00\x0a\x00\x00".b  # version=10
      result = parser.parse(payload)
      expect(result[:version]).to eq 10
      expect(result[:error]).to include("unsupported")
    end

    it "parse nil 返回 nil" do
      parser = described_class::Parser.new
      expect(parser.parse(nil)).to be_nil
    end

    it "解析 v5 固定格式报文" do
      parser = described_class::Parser.new(use_predefined: false)
      # 构造最小 v5 报文: 24B 头 + 1 条 48B 记录
      header = [
        0x0005,      # version=5
        0x0001,      # count=1
        0x00000000,  # sys_uptime
        0x60000000,  # unix_secs
        0x00000000,  # unix_nsecs
        0x00000001,  # flow_sequence
        0x00,        # engine_type
        0x01,        # engine_id
        0x0000       # sampling
      ].pack("n2N4CCn")

      record = "\xc0\xa8\x01\x01".b    # src_addr
      record += "\xc0\xa8\x02\x01".b   # dst_addr
      record += "\xc0\xa8\x01\xfe".b   # next_hop
      record += "\x00\x0a".b           # input
      record += "\x00\x14".b           # output
      record += [100].pack("N")        # d_pkts
      record += [50000].pack("N")      # d_octets
      record += [0].pack("N")          # first
      record += [100].pack("N")        # last
      record += [80].pack("n")         # src_port
      record += [443].pack("n")        # dst_port
      record += "\x00".b               # pad
      record += "\x10".b               # tcp_flags
      record += "\x06".b               # protocol (TCP)
      record += "\x00".b               # tos
      record += [0].pack("n")          # src_as
      record += [0].pack("n")          # dst_as
      record += "\x18\x18".b             # src_mask + dst_mask
      record += "\x00\x00".b             # pad2 (46-47)

      payload = header + record
      result = parser.parse(payload)

      expect(result[:version]).to eq 5
      expect(result[:records].size).to eq 1
      expect(result[:records][0][:src_addr]).to eq "192.168.1.1"
      expect(result[:records][0][:dst_addr]).to eq "192.168.2.1"
      expect(result[:records][0][:protocol]).to eq 6
      expect(result[:records][0][:src_port]).to eq 80
      expect(result[:records][0][:dst_port]).to eq 443
    end

    it "解析 v9 数据流使用预定义模板" do
      parser = described_class::Parser.new(use_predefined: true, parse_templates: false)
      # 构造最小 v9 报文: 20B 头 + 1 个数据 FlowSet (id=1315)
      header = [
        0x0009,      # version=9
        0x0001,      # count=1
        0x00000000,  # sys_uptime
        0x60000000,  # unix_secs
        0x00000001,  # package_sequence
        0x00000000   # source_id
      ].pack("n2N4")

      # 数据 FlowSet: flowset_id=1315, length=4+60=64
      flowset_header = [1315, 64].pack("n2")
      # 60 字节数据 (全零即可)
      flowset_data = "\x00" * 60

      payload = header + flowset_header + flowset_data
      result = parser.parse(payload)

      expect(result[:version]).to eq 9
      expect(result[:records].size).to eq 1
      expect(result[:records][0][:template_id]).to eq 1315
    end

    it "解析 v9 模板 FlowSet 并覆盖预定义模板" do
      parser = described_class::Parser.new(use_predefined: true, parse_templates: true)
      # 构造 v9 报文: 20B 头 + 模板 FlowSet (id=0) + 数据 FlowSet
      header = [
        0x0009,      # version=9
        0x0002,      # count=2
        0x00000000,  # sys_uptime
        0x60000000,  # unix_secs
        0x00000001,  # package_sequence
        0x00000000   # source_id
      ].pack("n2N4")

      # 模板 FlowSet: 定义模板 256, 2 个字段 [in_bytes(4), in_pkts(4)]
      # flowset_id=0, length=4+4+8=16
      tpl_fs = [0, 16].pack("n2")
      tpl_fs += [256, 2].pack("n2")    # template_id=256, field_count=2
      tpl_fs += [1, 4].pack("n2")       # in_bytes, 4 bytes
      tpl_fs += [2, 4].pack("n2")       # in_pkts, 4 bytes

      # 数据 FlowSet: flowset_id=256, 1 条记录 (8 bytes)
      data_fs = [256, 12].pack("n2")
      data_fs += [1000].pack("N")        # in_bytes
      data_fs += [10].pack("N")          # in_pkts

      payload = header + tpl_fs + data_fs
      result = parser.parse(payload)

      expect(result[:version]).to eq 9
      expect(result[:flowsets].size).to eq 1
      expect(result[:flowsets][0][:type]).to eq "template"
      expect(result[:flowsets][0][:template_id]).to eq 256
      expect(result[:records].size).to eq 1
      expect(result[:records][0]["in_bytes"]).to eq 1000
      expect(result[:records][0]["in_pkts"]).to eq 10
      expect(parser.templates[256][:predefined]).to be false
    end

    it "无模板时记录 missing_templates" do
      parser = described_class::Parser.new(use_predefined: false, parse_templates: false)
      header = [0x0009, 0x0001, 0, 0x60000000, 1, 0].pack("n2N4")
      data_fs = [999, 12].pack("n2") + "\x00" * 8
      payload = header + data_fs

      result = parser.parse(payload)
      expect(result[:records]).to be_empty
      expect(parser.missing_templates[999]).to eq 1
    end
  end

  describe "FlowStats 统计收集器" do
    it "按模板聚合统计" do
      stats = described_class::FlowStats.new
      stats.add(1315, 10, 1000)
      stats.add(1315, 20, 2000)
      stats.add(1505, 5, 500)

      report = stats.to_a
      expect(report.size).to eq 2
      expect(report[0][:template_id]).to eq 1315
      expect(report[0][:flow_count]).to eq 2
      expect(report[0][:total_packets]).to eq 30
      expect(report[0][:min_bytes]).to eq 1000
      expect(report[0][:max_bytes]).to eq 2000
      expect(report[1][:template_id]).to eq 1505
      expect(report[1][:flow_count]).to eq 1
    end
  end

  describe "PcapReader" do
    it "未知 magic 抛异常" do
      tmp = Tempfile.new(["netstream_test", ".pcap"])
      tmp.write("NOT_A_PCAP_FILE_24_BYTES!!!!!")  # 28 bytes, >= 24
      tmp.close
      path = tmp.path
      expect {
        described_class::PcapReader.new(path)
      }.to raise_error(/unknown pcap magic/)
      begin; File.delete(path); rescue Errno::EACCES; end
    end
  end
end
