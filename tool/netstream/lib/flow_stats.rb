# frozen_string_literal: true

# NetworkInfraUtility::NetStream::FlowStats — 全量流统计收集器
#
# 按模板 ID 聚合统计流记录数、包数、字节数的 min/max/sum/avg。
module NetworkInfraUtility
  module NetStream
    class FlowStats
      attr_reader :data

      def initialize
        @data = Hash.new do |h, tid|
          h[tid] = { count: 0, pkts_sum: 0, bytes_min: nil, bytes_max: nil, bytes_sum: 0 }
        end
      end

      # 添加一条流记录的统计数据。
      def add(template_id, in_pkts, in_bytes)
        s = @data[template_id]
        s[:count] += 1
        s[:pkts_sum] += in_pkts
        s[:bytes_min] = in_bytes if s[:bytes_min].nil? || in_bytes < s[:bytes_min]
        s[:bytes_max] = in_bytes if s[:bytes_max].nil? || in_bytes > s[:bytes_max]
        s[:bytes_sum] += in_bytes
      end

      # 控制台报告行。
      def report_lines
        @data.keys.sort.map do |tid|
          s = @data[tid]
          avg_bytes = s[:count] > 0 ? (s[:bytes_sum] / s[:count].to_f).round(2) : 0
          avg_pkts  = s[:count] > 0 ? (s[:pkts_sum] / s[:count].to_f).round(2) : 0
          format("  template %-4d  flows=%-8d  total_pkts=%-12d  avg_pkts=%.2f  min_bytes=%-8d  max_bytes=%-8d  avg_bytes=%.2f",
                 tid, s[:count], s[:pkts_sum], avg_pkts,
                 s[:bytes_min] || 0, s[:bytes_max] || 0, avg_bytes)
        end
      end

      # 转为 JSON 友好的数组。
      def to_a
        @data.keys.sort.map do |tid|
          s = @data[tid]
          {
            template_id: tid,
            flow_count: s[:count],
            total_packets: s[:pkts_sum],
            avg_packets: (s[:count] > 0 ? (s[:pkts_sum] / s[:count].to_f).round(2) : 0),
            min_bytes: s[:bytes_min],
            max_bytes: s[:bytes_max],
            avg_bytes: (s[:count] > 0 ? (s[:bytes_sum] / s[:count].to_f).round(2) : 0)
          }
        end
      end
    end
  end
end
