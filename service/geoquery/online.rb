# coding: utf-8
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "normalize"

module GeoQuery
  # ------------------------------------------------------------------
  # 互联网查询客户端 (gen-get 核心) — 免费 ip-api.com 接口
  # ------------------------------------------------------------------
  # 接口与参数沿用 ip_geo_lookup.py 的默认配置:
  #   http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,message,country,regionName,city,isp,as,query
  #   (免费版无需 Key, 限 45 req/min; message 字段为诊断扩展, 不影响归属字段)
  #
  # 状态映射 (state):
  #   ok           status:success          互联网查询成功
  #   empty        status:fail             互联网确认无归属 (如私有/保留地址)
  #   unreachable  网络/HTTP 异常          互联网查询不可达 (不缓存, 下次重试)
  #   invalid      IP 参数不合法
  class OnlineClient
    DEFAULT_API = "http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,message,country,regionName,city,isp,as,query"
    MIN_INTERVAL = 1.4  # 两次请求最小间隔 (秒), 对齐 45 req/min 免费限额

    attr_reader :api

    def initialize(api: DEFAULT_API, timeout: 10)
      @api = api || DEFAULT_API
      @timeout = timeout || 10
      @lock = Mutex.new
      @last_ts = 0.0
    end

    # 查询单个 IP, 返回统一 schema:
    #   { "ip", "state", "message", "country", "province", "city",
    #     "isp", "asn", "asn_org", "network", "usage", "source", "ts" }
    def lookup(ip)
      unless valid_ip?(ip)
        return base(ip, "invalid", "IP 不合法")
      end

      raw = fetch(ip)
      case raw[:state]
      when :unreachable
        base(ip, "unreachable", raw[:message]).merge("ts" => Time.now.to_i)
      when :empty
        base(ip, "empty", raw[:message]).merge("ts" => Time.now.to_i)
      else
        parse_success(ip, raw[:body])
      end
    end

    private

    def base(ip, state, message = "")
      {
        "ip" => ip, "state" => state, "message" => message,
        "country" => "", "province" => "", "city" => "",
        "isp" => "", "asn" => "", "asn_org" => "", "network" => "",
        "usage" => "", "source" => "gen-get(ip-api.com)",
      }
    end

    # 发请求并做状态归类, 返回 {state: :ok/:empty/:unreachable, body:, message:}
    def fetch(ip)
      throttle!
      uri = URI(@api.sub("{ip}", URI.encode_www_form_component(ip)))
      res = Net::HTTP.start(uri.hostname, uri.port,
                            open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.get(uri.request_uri)
      end
      case res.code.to_i
      when 200
        body = JSON.parse(res.body)
        if body["status"] == "success"
          { state: :ok, body: body }
        else
          { state: :empty, message: body["message"].to_s }
        end
      when 429
        { state: :unreachable, message: "ip-api.com 限速 (HTTP 429), 稍后重试" }
      else
        { state: :unreachable, message: "ip-api.com 返回 HTTP #{res.code}" }
      end
    rescue => e
      { state: :unreachable, message: "#{e.class}: #{e.message}" }
    end

    # 全局最小间隔限速 (进程内), 多线程调用也保持 45 req/min 以内
    def throttle!
      @lock.synchronize do
        wait = MIN_INTERVAL - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_ts)
        sleep(wait) if wait > 0
        @last_ts = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def parse_success(ip, d)
      # as 字段格式: "AS4134 Chinanet"
      asn = ""
      asn_org = d["as"].to_s
      if (m = asn_org.match(/\AAS(\d+)\s+(.*)\z/))
        asn = m[1]
        asn_org = m[2]
      end
      isp_raw = [asn_org, d["isp"]].reject { |s| s.to_s.empty? }.first.to_s
      {
        "ip" => ip,
        "state" => "ok",
        "message" => "",
        "country" => d["country"].to_s,
        "province" => d["regionName"].to_s,
        "city" => d["city"].to_s,
        "isp" => Normalize.isp_from_asn(isp_raw),
        "asn" => asn,
        "asn_org" => asn_org,
        "network" => "",
        "usage" => Normalize.usage_from_asn(asn_org),
        "source" => "gen-get(ip-api.com)",
        "ts" => Time.now.to_i,
      }
    end

    def valid_ip?(ip)
      ip = ip.to_s.strip
      return false if ip.empty?
      if ip.include?(":")
        ip.match?(/\A[0-9A-Fa-f:]+\z/) && ip.count(":") >= 2
      else
        ip.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/) &&
          ip.split(".").all? { |o| o.to_i < 256 }
      end
    end
  end
end
