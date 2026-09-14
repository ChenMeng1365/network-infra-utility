# frozen_string_literal: true

require "resolv"
require_relative "probe_base"

module NetworkInfraUtility
  module Probe
    # DNS 服务探测：向目标 DNS 服务器发起一次记录查询。
    # 默认查询 example.com 的 A 记录。
    class DnsProbe < Base
      def self.default_port
        53
      end

      def call
        query = @options.fetch(:name, "example.com")
        type = @options.fetch(:type, "A")
        answers, latency = timing { resolve(query, type) }
        if answers && !answers.empty?
          result(:ok, latency: latency, message: "DNS 响应正常", detail: "#{query} #{type.upcase} -> #{format_answer(answers.first)}")
        else
          result(:fail, latency: latency, message: "无有效响应")
        end
      rescue Resolv::ResolvError, Resolv::ResolvTimeout => e
        result(:timeout, message: e.message)
      rescue StandardError => e
        result(:unknown, message: e.message)
      end

      private

      def resolve(query, type)
        resolver = Resolv::DNS.new(nameserver: [@host], search: [], ndots: 1)
        resolver.timeouts = [@timeout, @timeout]
        resolver.getresources(query, resource_class(type))
      ensure
        resolver.close if resolver
      end

      def resource_class(type)
        case type.to_s.upcase
        when "PTR"   then Resolv::DNS::Resource::IN::PTR
        when "AAAA"  then Resolv::DNS::Resource::IN::AAAA
        when "NS"    then Resolv::DNS::Resource::IN::NS
        when "MX"    then Resolv::DNS::Resource::IN::MX
        when "CNAME" then Resolv::DNS::Resource::IN::CNAME
        else Resolv::DNS::Resource::IN::A
        end
      end

      # 记录 → 可读字符串。
      def format_answer(rec)
        case rec
        when Resolv::DNS::Resource::IN::A, Resolv::DNS::Resource::IN::AAAA
          rec.address.to_s
        when Resolv::DNS::Resource::IN::MX
          "#{rec.preference} #{rec.exchange}"
        else
          rec.respond_to?(:name) ? rec.name.to_s : rec.to_s
        end
      end
    end
  end
end
