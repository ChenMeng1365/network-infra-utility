# frozen_string_literal: true
# coding: utf-8

require "open3"
require_relative "probe_base"

module NetworkInfraUtility
  module Probe
    # ICMP 连通性探测。
    # 复用系统 ping（跨平台），无需 root/raw socket。
    class IcmpProbe < Base
      def self.default_port
        nil
      end

      def call
        out, latency = timing { run_ping }
        if out[:ok]
          rtt = out[:rtt]
          result(:ok, latency: rtt || latency, message: "ICMP 可达", detail: out[:raw])
        else
          result(:fail, latency: latency, message: out[:message], detail: out[:raw])
        end
      rescue StandardError => e
        result(:unknown, message: e.message)
      end

      private

      def run_ping
        count = @options.fetch(:count, 3)
        cmd = if windows?
                ["ping", "-n", count.to_s, "-w", timeout_ms.to_s, @host]
              else
                ["ping", "-c", count.to_s, "-W", @timeout.to_i.to_s, @host]
              end
        stdout, stderr, status = Open3.capture3(*cmd)
        output = stdout.to_s.empty? ? stderr.to_s : stdout.to_s
        text = decode_output(output)
        rtt = parse_rtt(text)
        if status.exitstatus == 0
          { ok: true, rtt: rtt, raw: text }
        else
          { ok: false, message: "ping 失败 (exit #{status.exitstatus})", raw: text }
        end
      rescue Errno::ENOENT
        { ok: false, message: "未找到 ping 命令", raw: nil }
      end

      def timeout_ms
        (@timeout * 1000).to_i
      end

      # 将 ping 输出转为合法 UTF-8（Windows 控制台默认 GBK/CP936）。
      def decode_output(raw)
        return nil if raw.nil? || raw.empty?
        enc = windows? ? (Encoding.locale_charmap || "UTF-8") : "UTF-8"
        raw.dup.force_encoding(enc).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      rescue StandardError
        raw.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # 解析输出中的 RTT（毫秒），取平均。兼容 time=/时间= 两种关键词。
      def parse_rtt(text)
        return nil unless text
        values = text.scan(/(?:time|时间)\s*[=<]\s*(\d+(?:\.\d+)?)\s*ms/).flatten.map(&:to_f)
        values.empty? ? nil : (values.sum / values.size).round(2)
      end
    end
  end
end
