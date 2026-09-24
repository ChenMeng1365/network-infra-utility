# frozen_string_literal: true

require_relative "field_types"
require_relative "predefined_templates"

# NetworkInfraUtility::NetStream::Parser — NetStream v5/v9 核心解析器
#
# 支持两种工作模式，可同时启用：
#
# 1. 预定义模板模式（无模板猜测）：
#    use_predefined: true（默认）
#    当抓包中不包含模板 FlowSet 时，使用逆向推断的预定义模板解析数据流。
#    适用于设备未发送模板或模板已丢失的场景。
#
# 2. 报文模板模式（有模板解析）：
#    parse_templates: true（默认）
#    从抓包中解析模板 FlowSet（FlowSet ID=0）和选项模板 FlowSet（ID=1），
#    用报文中的模板定义解析后续数据流。
#    报文模板会自动覆盖同 ID 的预定义模板。
#
# 当两种模式同时启用时，报文模板优先级高于预定义模板。

module NetworkInfraUtility
  module NetStream
    class Parser
      include FieldTypes

      attr_reader :templates, :missing_templates

      # use_predefined:  是否预加载逆向推断的模板（默认 true）
      # parse_templates: 是否从报文中解析模板 FlowSet（默认 true）
      def initialize(use_predefined: true, parse_templates: true)
        @templates = {}
        @missing_templates = Hash.new(0)
        @parse_templates = parse_templates

        if use_predefined
          PredefinedTemplates::TEMPLATES.each do |tid, defn|
            @templates[tid] = {
              version: 9, option: false, fields: defn[:fields],
              scope_fields: nil, option_fields: nil,
              predefined: true, desc: defn[:desc]
            }
          end
        end
      end

      # 解析单个 NetStream UDP 载荷，返回解析结果 Hash 或 nil。
      def parse(payload)
        return nil if payload.nil? || payload.bytesize < 4

        version = FieldTypes.u16(payload, 0)
        case version
        when 5 then parse_v5(payload)
        when 9 then parse_v9(payload)
        else { version: version, error: "unsupported version #{version}" }
        end
      end

      private

      # ── v5: 固定格式，24B 头 + 48B/条 ──

      def parse_v5(p)
        count = FieldTypes.u16(p, 2)
        header = {
          count: count,
          sys_uptime_ms: FieldTypes.u32(p, 4),
          unix_secs: FieldTypes.u32(p, 8),
          unix_nsecs: FieldTypes.u32(p, 12),
          flow_sequence: FieldTypes.u32(p, 16),
          engine_type: p.getbyte(20),
          engine_id: p.getbyte(21),
          sampling: FieldTypes.u16(p, 22)
        }
        records = []
        off = 24
        count.times do
          break if off + 48 > p.bytesize
          r = p.byteslice(off, 48)
          records << {
            src_addr: FieldTypes.ipv4_str(r.byteslice(0, 4)),
            dst_addr: FieldTypes.ipv4_str(r.byteslice(4, 4)),
            next_hop: FieldTypes.ipv4_str(r.byteslice(8, 4)),
            input: FieldTypes.u16(r, 12),
            output: FieldTypes.u16(r, 14),
            d_pkts: FieldTypes.u32(r, 16),
            d_octets: FieldTypes.u32(r, 20),
            first: FieldTypes.u32(r, 24),
            last: FieldTypes.u32(r, 28),
            src_port: FieldTypes.u16(r, 32),
            dst_port: FieldTypes.u16(r, 34),
            tcp_flags: r.getbyte(37),
            protocol: r.getbyte(38),
            tos: r.getbyte(39),
            src_as: FieldTypes.u16(r, 40),
            dst_as: FieldTypes.u16(r, 42),
            src_mask: r.getbyte(44),
            dst_mask: r.getbyte(45)
          }
          off += 48
        end
        { version: 5, header: header, records: records }
      end

      # ── v9: 模板化格式，20B 头 + FlowSet 序列 ──

      def parse_v9(p)
        count = FieldTypes.u16(p, 2)
        header = {
          count: count,
          sys_uptime_ms: FieldTypes.u32(p, 4),
          unix_secs: FieldTypes.u32(p, 8),
          package_sequence: FieldTypes.u32(p, 12),
          source_id: FieldTypes.u32(p, 16)
        }
        flowsets = []
        records = []
        off = 20
        while off + 4 <= p.bytesize
          fs_id = FieldTypes.u16(p, off)
          fs_len = FieldTypes.u16(p, off + 2)
          break if fs_len < 4 || off + fs_len > p.bytesize

          if @parse_templates && fs_id.zero?
            parse_template_flowset(p, off, fs_len, flowsets)
          elsif @parse_templates && fs_id == 1
            parse_option_template_flowset(p, off, fs_len, flowsets)
          elsif fs_id > 1
            parse_data_flowset(fs_id, p, off, fs_len, records)
          end
          off += fs_len
        end
        { version: 9, header: header, flowsets: flowsets, records: records }
      end

      # 模板 FlowSet (FlowSet ID=0)
      def parse_template_flowset(p, base, fs_len, flowsets)
        t = base + 4
        e = base + fs_len
        while t + 4 <= e
          tid = FieldTypes.u16(p, t)
          fc  = FieldTypes.u16(p, t + 2)
          t += 4
          fields = []
          fc.times do
            break if t + 4 > e
            fields << [FieldTypes.u16(p, t), FieldTypes.u16(p, t + 2)]
            t += 4
          end
          @templates[tid] = {
            version: 9, option: false, fields: fields,
            scope_fields: nil, option_fields: nil,
            predefined: false
          }
          flowsets << {
            type: "template", template_id: tid,
            fields: fields.map { |ty, len| FieldTypes.field_info(ty, len) }
          }
        end
      end

      # 选项模板 FlowSet (FlowSet ID=1)
      def parse_option_template_flowset(p, base, fs_len, flowsets)
        t = base + 4
        e = base + fs_len
        while t + 6 <= e
          tid = FieldTypes.u16(p, t)
          scope_len = FieldTypes.u16(p, t + 2)
          opt_len   = FieldTypes.u16(p, t + 4)
          t += 6
          scope_fields = []
          (scope_len / 4).times do
            break if t + 4 > e
            scope_fields << [FieldTypes.u16(p, t), FieldTypes.u16(p, t + 2)]
            t += 4
          end
          option_fields = []
          (opt_len / 4).times do
            break if t + 4 > e
            option_fields << [FieldTypes.u16(p, t), FieldTypes.u16(p, t + 2)]
            t += 4
          end
          @templates[tid] = {
            version: 9, option: true,
            fields: scope_fields + option_fields,
            scope_fields: scope_fields, option_fields: option_fields,
            predefined: false
          }
          flowsets << {
            type: "option_template", template_id: tid,
            scope_fields: scope_fields.map { |ty, len| FieldTypes.field_info(ty, len) },
            option_fields: option_fields.map { |ty, len| FieldTypes.field_info(ty, len) }
          }
        end
      end

      # 数据 FlowSet (FlowSet ID>1)
      def parse_data_flowset(fs_id, p, base, fs_len, records)
        tpl = @templates[fs_id]
        if tpl.nil?
          @missing_templates[fs_id] += 1
          return
        end
        fields = tpl[:fields]
        total_len = fields.sum { |_ty, len| len }
        return if total_len.zero?

        rec_start = base + 4
        rec_end = base + fs_len
        while rec_start + total_len <= rec_end
          r = p.byteslice(rec_start, total_len)
          f = {}
          ro = 0
          fields.each do |ty, len|
            f.merge!(FieldTypes.render_field(ty, len, r.byteslice(ro, len), ro))
            ro += len
          end
          f[:template_id] = fs_id
          f[:template_desc] = tpl[:desc] if tpl[:desc]
          records << f
          rec_start += total_len
        end
      end
    end
  end
end
