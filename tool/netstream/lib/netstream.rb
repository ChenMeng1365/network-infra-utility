# frozen_string_literal: true

require_relative "netstream_version"
require_relative "field_types"
require_relative "predefined_templates"
require_relative "pcap_reader"
require_relative "parser"
require_relative "flow_stats"

require "json"

# NetworkInfraUtility::NetStream — NetStream v5/v9 pcap 解析工具
#
# 从 pcap 抓包文件中解析华为 NetStream v5/v9 流记录，输出结构化数据。
# 纯 Ruby 实现，无第三方依赖。
#
# 支持两种工作模式（可同时启用）：
#
# 1. 预定义模板模式（无模板猜测）：
#    抓包中不含模板 FlowSet 时，使用逆向推断的预定义模板解析数据流。
#    适用于设备未发送模板或模板已丢失的场景。
#
# 2. 报文模板模式（有模板解析）：
#    从抓包中解析模板 FlowSet，用报文中的模板定义解析数据流。
#    报文模板优先级高于预定义模板。
#
# 用法：
#   require "netstream"
#
#   # 解析 pcap 文件
#   result = NetworkInfraUtility::NetStream.parse("capture.pcap")
#   result.templates  # => 模板列表
#   result.records    # => 流记录数组
#   result.stats      # => FlowStats 统计
#
#   # 禁用预定义模板（仅使用报文中的模板）
#   result = NetworkInfraUtility::NetStream.parse("capture.pcap", use_predefined: false)
#
#   # 禁用报文模板解析（仅使用预定义模板）
#   result = NetworkInfraUtility::NetStream.parse("capture.pcap", parse_templates: false)
#
#   # 限制每模板输出条数
#   result = NetworkInfraUtility::NetStream.parse("capture.pcap", limit: 100)
#
#   # 导出到目录
#   result = NetworkInfraUtility::NetStream.parse("capture.pcap", output_dir: "output/")
module NetworkInfraUtility
  module NetStream
    # 解析结果。
    class Result
      attr_reader :source, :templates, :records, :stats,
                  :packet_count, :v5_count, :v9_count, :other_count,
                  :missing_templates, :record_count

      def initialize(source:, templates:, records:, stats:,
                     packet_count:, v5_count:, v9_count:, other_count:,
                     missing_templates:, record_count:)
        @source = source
        @templates = templates
        @records = records
        @stats = stats
        @packet_count = packet_count
        @v5_count = v5_count
        @v9_count = v9_count
        @other_count = other_count
        @missing_templates = missing_templates
        @record_count = record_count
      end

      def main_version
        @v5_count > @v9_count ? 5 : 9
      end

      # 模板列表转为可序列化的数组。
      def templates_to_a
        @templates.map do |tid, t|
          {
            template_id: tid,
            option: t[:option],
            predefined: t[:predefined] == true,
            desc: t[:desc],
            fields: (t[:fields] || []).map { |ty, len| FieldTypes.field_info(ty, len) }
          }
        end
      end

      # 统计摘要转为 Hash。
      def summary
        {
          source: @source,
          netstream_version: main_version,
          packet_count: @packet_count,
          record_count: @record_count,
          v5_packets: @v5_count,
          v9_packets: @v9_count,
          other_packets: @other_count,
          template_count: @templates.size,
          missing_templates: @missing_templates,
          stats: @stats.to_a
        }
      end

      # 将模板导出为 JSON 字符串。
      def templates_json
        JSON.pretty_generate(templates_to_a)
      end

      # 将统计摘要导出为 JSON 字符串。
      def summary_json
        JSON.pretty_generate(summary)
      end
    end

    module_function

    # 解析 pcap 文件。
    #
    # 参数：
    #   pcap_path:       pcap 文件路径
    #   use_predefined:  是否使用预定义模板（默认 true）
    #   parse_templates: 是否从报文解析模板 FlowSet（默认 true）
    #   limit:           每模板最大输出记录数，0=不限（默认 0）
    #   output_dir:      输出目录，nil=不写文件（默认 nil）
    #   progress:        是否输出进度（默认 false）
    #
    # 返回 Result 对象。
    def parse(pcap_path, use_predefined: true, parse_templates: true,
              limit: 0, output_dir: nil, templates_only: false, progress: false)
      reader = PcapReader.new(pcap_path)
      parser = Parser.new(use_predefined: use_predefined, parse_templates: parse_templates)
      stats = FlowStats.new

      records = []
      template_counts = Hash.new(0)
      pkt_n = 0
      v5_count = 0
      v9_count = 0
      other_count = 0
      record_count = 0

      # 输出目录准备
      records_dir = nil
      if output_dir
        Dir.mkdir(output_dir) unless Dir.exist?(output_dir)
        unless templates_only
          records_dir = File.join(output_dir, "records")
          Dir.mkdir(records_dir) unless Dir.exist?(records_dir)
        end
      end

      file_n = 0
      write_files = output_dir && !templates_only

      reader.each_packet do |ts_sec, ts_usec, frame|
        pkt_n += 1

        l3 = PcapReader.extract_udp_payload(frame, reader.linktype)
        if l3.nil?
          other_count += 1
          next
        end

        ns = parser.parse(l3[:payload])
        if ns.nil? || ns[:version] != 5 && ns[:version] != 9
          other_count += 1
          next
        end

        case ns[:version]
        when 5
          v5_count += 1
          ns[:records].each do |rec|
            records << rec unless write_files
            record_count += 1
            if write_files
              write_record(records_dir, file_n += 1, ts_sec, ts_usec, l3, ns, rec)
            end
          end
        when 9
          v9_count += 1
          ns[:records].each do |rec|
            tid = rec[:template_id]

            # 统计（全量，不受 limit 影响）
            in_pkts  = rec["in_pkts"] || rec[:in_pkts] || 0
            in_bytes = rec["in_bytes"] || rec[:in_bytes] || 0
            stats.add(tid, in_pkts, in_bytes)
            record_count += 1

            # 详细输出（受 limit 控制）
            if limit.zero? || template_counts[tid] < limit
              template_counts[tid] += 1
              records << rec unless write_files
              if write_files
                file_n += 1
                write_record(records_dir, file_n, ts_sec, ts_usec, l3, ns, rec)
              end
            end
          end
        end

        if progress && (pkt_n % 50_000).zero?
          puts "  [progress] packets=#{pkt_n} v5=#{v5_count} v9=#{v9_count} records=#{record_count}"
          $stdout.flush
        end
      end

      # 写文件输出
      if output_dir
        write_templates(output_dir, parser)
        write_summary(output_dir, pcap_path, pkt_n, v5_count, v9_count, other_count,
                      record_count, template_counts, parser, stats, limit)
      end

      Result.new(
        source: pcap_path,
        templates: parser.templates,
        records: records,
        stats: stats,
        packet_count: pkt_n,
        v5_count: v5_count,
        v9_count: v9_count,
        other_count: other_count,
        missing_templates: parser.missing_templates,
        record_count: record_count
      )
    end

    # ── 内部方法 ──

    def self.write_record(records_dir, file_n, ts_sec, ts_usec, l3, ns, rec)
      ts_str = Time.at(ts_sec + ts_usec / 1_000_000.0).utc.strftime("%Y%m%dT%H%M%S_%6NZ")
      fname = format("%08d_%04d_%s.json", file_n, rec[:template_id] || 0, ts_str)
      fpath = File.join(records_dir, fname)

      tid = rec.delete(:template_id)
      tdesc = rec.delete(:template_desc)

      output = {
        flow_id: file_n,
        timestamp: Time.at(ts_sec + ts_usec / 1_000_000.0).utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        ts_sec: ts_sec,
        ts_usec: ts_usec,
        exporter: {
          src_ip: l3[:src_ip],
          dst_ip: l3[:dst_ip],
          src_port: l3[:src_port],
          dst_port: l3[:dst_port]
        },
        netstream_header: ns[:header],
        template_id: tid,
        template_desc: tdesc,
        fields: rec
      }

      File.write(fpath, JSON.pretty_generate(output))
    end
    private_class_method :write_record

    def self.write_templates(output_dir, parser)
      tpl_out = parser.templates.map do |tid, t|
        {
          template_id: tid,
          option: t[:option],
          predefined: t[:predefined] == true,
          desc: t[:desc],
          fields: (t[:fields] || []).map { |ty, len| FieldTypes.field_info(ty, len) }
        }
      end
      File.write(File.join(output_dir, "templates.json"), JSON.pretty_generate(tpl_out))
    end
    private_class_method :write_templates

    def self.write_summary(output_dir, source, pkt_n, v5, v9, other, rec_count,
                           template_counts, parser, stats, limit)
      report = {
        source: source,
        scanned_packets: pkt_n,
        v5_packets: v5,
        v9_packets: v9,
        other_packets: other,
        record_count: rec_count,
        per_template_limit: limit,
        template_detail_counts: template_counts,
        missing_templates: parser.missing_templates,
        templates: stats.to_a
      }
      File.write(File.join(output_dir, "summary.json"), JSON.pretty_generate(report))
    end
    private_class_method :write_summary
  end
end
