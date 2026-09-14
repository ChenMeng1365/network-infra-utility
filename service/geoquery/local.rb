# coding: utf-8
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "normalize"

module GeoQuery
  # ------------------------------------------------------------------
  # 本地查询客户端 — 向运行中的 geo-api 服务 (geo-get 的数据源) 查询
  # ------------------------------------------------------------------
  # 一次拉取 /geo/country /geo/city /geo/asn 三接口:
  #   - lookup    归一化为统一 schema (与 OnlineClient 同构, 供 ngeo 编排)
  #   - fetch_raw 返回各接口原始响应 (bin/geo-get 的底座, 保持其输出契约)
  # geo-api 未启动不算错误, state 标记 unavailable, 由上层 (ngeo) 决定
  # 是否回退互联网。
  #
  # 状态映射 (state):
  #   ok           三接口至少一个有数据
  #   empty        三接口均 404 (IP 不在本地库范围)
  #   unavailable  geo-api 服务不可达 (未启动/端口不对)
  #   invalid      IP 参数不合法
  class LocalClient
    DEFAULT_BASE = "http://127.0.0.1:9292"
    TIMEOUT = 15
    ENDPOINTS = %i[country city asn].freeze

    attr_reader :base

    def initialize(base: DEFAULT_BASE, timeout: TIMEOUT)
      @base = base.chomp("/")
      @timeout = timeout
    end

    # 返回统一 schema (与 OnlineClient 同构):
    #   { "ip", "state", "message", "country", "province", "city",
    #     "isp", "asn", "asn_org", "network", "usage", "source", "ts" }
    def lookup(ip)
      unless valid_ip?(ip)
        return base(ip, "invalid", "IP 不合法")
      end

      raw = fetch_raw(ip)
      return base(ip, "unavailable", "geo-api 服务不可达 (#@base)") if raw == :unreachable

      if raw.values.compact.empty?
        return base(ip, "empty", "本地库无该 IP 归属数据")
      end

      compose(ip, raw)
    end

    # 原始接口查询 (bin/geo-get 底座):
    #   endpoints: ENDPOINTS 的子集, 默认三接口齐查
    # 返回:
    #   Hash        { :country => body|nil, :city => body|nil, :asn => body|nil }
    #               (仅含请求的接口; 404/400/非 200 → nil)
    #   :unreachable geo-api 服务不可达 (连接失败/超时)
    def fetch_raw(ip, endpoints: ENDPOINTS)
      result = {}
      endpoints.each do |ep|
        r = fetch_endpoint(ep, ip.to_s)
        return :unreachable if r == :unavailable
        result[ep] = r.is_a?(Hash) ? r : nil
      end
      result
    end

    private

    def base(ip, state, message = "")
      {
        "ip" => ip, "state" => state, "message" => message,
        "country" => "", "province" => "", "city" => "",
        "isp" => "", "asn" => "", "asn_org" => "", "network" => "",
        "usage" => "", "source" => "geo-get(geo-api)",
      }
    end

    # 单接口查询: 200 → body(Hash); 404 → nil; 400 → :bad;
    # 连接失败 → :unavailable (调用方遇之立即终止, 不再请求其余接口)
    def fetch_endpoint(endpoint, ip)
      uri = URI("#{@base}/geo/#{endpoint}?addr=#{URI.encode_www_form_component(ip)}")
      res = Net::HTTP.get_response(uri)
      case res.code.to_i
      when 200 then JSON.parse(res.body)
      when 404 then nil
      when 400 then :bad
      else nil
      end
    rescue JSON::ParserError
      nil
    rescue => e
      @last_error = "#{e.class}: #{e.message}"
      :unavailable
    end

    # 三接口数据归一化为统一 schema (raw: fetch_raw 的结果)
    def compose(ip, raw)
      city     = raw[:city]
      country  = raw[:country]
      asn      = raw[:asn]
      g_city   = city.is_a?(Hash)    ? (city["geoname"] || {})        : {}
      g_country = country.is_a?(Hash) ? (country["geoname"] ||
                                        country["registered_country"] || {}) : {}
      rc_city  = city.is_a?(Hash)    ? (city["registered_country"] || {}) : {}

      country_name = g_city["country_name"].to_s
      country_name = g_country["country_name"].to_s if country_name.empty?
      country_name = rc_city["country_name"].to_s if country_name.empty?

      province = g_city["subdivision_1_name"].to_s
      city_name = g_city["city_namezh"].to_s
      city_name = g_city["city_name"].to_s if city_name.empty?

      asn_num = asn.is_a?(Hash) ? asn["autonomous_system_number"].to_s : ""
      asn_org = asn.is_a?(Hash) ? asn["autonomous_system_organization"].to_s : ""

      network = [city, country, asn].map { |r| r.is_a?(Hash) ? r["network"].to_s : "" }
                                    .find { |n| !n.empty? }.to_s

      {
        "ip" => ip,
        "state" => "ok",
        "message" => "",
        "country" => country_name,
        "province" => province,
        "city" => city_name,
        "isp" => Normalize.isp_from_asn(asn_org),
        "asn" => asn_num,
        "asn_org" => asn_org,
        "network" => network,
        "usage" => Normalize.usage_from_asn(asn_org),
        "source" => "geo-get(geo-api)",
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
