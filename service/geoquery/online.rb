# coding: utf-8
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "normalize"
require_relative "merge"

module GeoQuery
  # ------------------------------------------------------------------
  # 互联网查询客户端 (gen-get 核心) — 百度智能IP定位 → ip-api.com 链式
  # ------------------------------------------------------------------
  # 查询链 (--api 未显式覆盖时的默认行为):
  #   1. 百度智能IP定位 (qifu.baidu.com 企业服务平台"智能IP定位"网页接口)
  #      国内 IP 的省市/运营商/场景 (IDC/家宽等) 定位更准;
  #      省市定位成功 → 直接返回, 不再请求 ip-api.com
  #   2. ip-api.com (免费接口, 全球覆盖, 提供 ASN 与国外城市)
  #      仅当百度查不出来时才尝试:
  #      - 百度确认无归属 (私有/保留地址) / 接口不可达 → ip-api.com 兜底
  #      - 百度仅定位到国家/运营商 (典型国外 IP, 无省市) → ip-api.com 补充,
  #        两方结果字段级叠加 (百度优先, ip-api.com 补 ASN 与省市)
  #
  # 接口与参数:
  #   百度  https://qifu.baidu.com/api/v1/ip-portrait/brief-info?ip={ip}
  #        (需带 Referer: https://qifu.baidu.com/ 请求头; 无官方限速文档,
  #         按 1 QPS 保守限速; 响应含 country/province/city/isp/scene)
  #   ip-api  http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,message,country,regionName,city,isp,as,query
  #        (免费版无需 Key, 限 45 req/min; message 字段为诊断扩展)
  #
  # 并发能力与防阻塞设计 (Provider, 每接口独立):
  #   - 限速: 相邻两次请求最小间隔 (Mutex + 单调时钟), 多线程调用按序放行
  #   - 熔断: 连续 BREAKER_THRESHOLD 次不可达 → BREAKER_COOLDOWN 秒内
  #     直接返回 unreachable, 不发包不等待, 避免持续超时阻塞调用方
  #   - HTTP 请求在限速锁外执行 (open/read 超时兜底), 不持锁等网络;
  #     多线程下发包频率受限但收包互不阻塞
  #   - --api 显式覆盖时进入单接口模式: 只查用户指定接口 (跳过百度链),
  #     兼容自定义接口与离线测试场景
  #
  # 状态映射 (state):
  #   ok           任一接口查询成功 (或百度+ip-api.com 结果叠加)
  #   empty        各接口均确认无归属 (如私有/保留地址)
  #   unreachable  各接口均不可达 (网络/超时/限速), 不缓存, 下次重试
  #   invalid      IP 参数不合法
  class OnlineClient
    # 百度智能IP定位 (qifu.baidu.com "智能IP定位" 页面同源接口)
    BAIDU_API = "https://qifu.baidu.com/api/v1/ip-portrait/brief-info?ip={ip}"
    # 百度无公开限速文档, 按 1 QPS 保守限速 (网页前端接口, 不宜高频)
    BAIDU_MIN_INTERVAL = 1.0
    # 该接口校验 Referer, 缺失时 403
    BAIDU_HEADERS = { "Referer" => "https://qifu.baidu.com/" }.freeze

    # ip-api.com 免费接口 (45 req/min)
    DEFAULT_API = "http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,message,country,regionName,city,isp,as,query"
    MIN_INTERVAL = 1.4  # 两次请求最小间隔 (秒), 对齐 45 req/min 免费限额

    # 熔断参数 (每接口独立)
    BREAKER_THRESHOLD = 3
    BREAKER_COOLDOWN  = 60

    attr_reader :api, :baidu_api

    def initialize(api: nil, baidu_api: nil, timeout: 10)
      # api 显式指定 → 单接口模式 (替换整条互联网链, 跳过百度)
      @custom_api = !api.nil?
      @api = api || DEFAULT_API
      @baidu_api = baidu_api || BAIDU_API
      @timeout = timeout || 10
      # 次选接口标签 (单接口模式为自定义接口 host, 链式模式为 ip-api.com)
      @ipapi_label = @custom_api ? "接口(#{api_host(@api)})" : "ip-api.com"
      @baidu = Provider.new("百度智能IP定位", BAIDU_MIN_INTERVAL,
                            threshold: BREAKER_THRESHOLD, cooldown: BREAKER_COOLDOWN)
      @ipapi = Provider.new(@ipapi_label, MIN_INTERVAL,
                            threshold: BREAKER_THRESHOLD, cooldown: BREAKER_COOLDOWN)
    end

    # 查询单个 IP, 返回统一 schema:
    #   { "ip", "state", "message", "country", "province", "city",
    #     "isp", "asn", "asn_org", "network", "usage", "source", "ts" }
    def lookup(ip)
      unless GeoQuery.valid_ip?(ip)
        return base(ip, "invalid", "IP 不合法")
      end

      raw = @custom_api ? single_fetch(ip) : chained_fetch(ip)
      compose(ip, raw)
    end

    # ------------------------------------------------------------------
    # 单接口 Provider — 限速 + 熔断 (线程安全, HTTP 在锁外执行)
    # ------------------------------------------------------------------
    class Provider
      attr_reader :name

      def initialize(name, interval, threshold: 3, cooldown: 60)
        @name = name
        @interval = interval.to_f
        @threshold = threshold
        @cooldown = cooldown
        @lock = Mutex.new
        @last_ts = 0.0
        @failures = 0
        @open_until = nil
      end

      # 执行一次带限速与熔断保护的请求:
      #   熔断开启 → 直接返回 unreachable (不发包不等待)
      #   否则按最小间隔排队放行后, 在锁外执行块内 HTTP
      def call
        if open?
          return { state: :unreachable,
                   message: "#{@name} 熔断中 (连续 #{@threshold} 次不可达, " \
                            "暂停查询 #{(remaining / 1000.0).round}s)" }
        end
        gate!
        result = yield
        record!(result)
        result
      end

      private

      # 熔断是否开启
      def open?
        @lock.synchronize do
          !@open_until.nil? && monotonic < @open_until
        end
      end

      # 熔断剩余毫秒数 (open? 为真时才有意义; 到期瞬间取 0)
      def remaining
        @lock.synchronize do
          r = ((@open_until - monotonic) * 1000).ceil
          r < 0 ? 0 : r
        end
      end

      # 限速: 锁内等待到最小间隔满足才放行 (sleep 不持 HTTP)
      def gate!
        @lock.synchronize do
          wait = @interval - (monotonic - @last_ts)
          sleep(wait) if wait > 0
          @last_ts = monotonic
        end
      end

      # 熔断记账: 连续 N 次不可达 → 冷却 cooldown 秒
      def record!(result)
        @lock.synchronize do
          if result[:state] == :unreachable
            @failures += 1
            if @failures >= @threshold
              @open_until = monotonic + @cooldown
              @failures = 0
            end
          else
            @failures = 0
          end
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    private

    # ---- 编排: 单接口 / 链式 ---------------------------------------------------

    # 单接口模式 (--api 显式覆盖): 只查指定接口, 不走百度链
    def single_fetch(ip)
      @ipapi.call { fetch_ipapi(ip) }.merge(source: "gen-get(#{api_host(@api)})")
    end

    # 链式模式: 百度优先, 查不出来才用 ip-api.com
    def chained_fetch(ip)
      baidu = @baidu.call { fetch_baidu(ip) }
      return baidu.merge(source: "gen-get(baidu)") if baidu[:state] == :ok

      ipapi = @ipapi.call { fetch_ipapi(ip) }
      combine(baidu, ipapi)
    end

    # 百度 × ip-api.com 结果组合 (百度优先, ip-api.com 补充/兜底):
    #   baidu :ok       → 上游已直接返回, 不会进入本方法
    #   baidu :partial  仅有国家/运营商无省市 (典型国外 IP) → ip-api.com 补;
    #                    补不到时保留百度部分字段 (state=ok)
    #   baidu :empty    百度确认无归属 → ip-api.com 兜底, 仍无 → empty
    #   baidu :unreachable 百度不可达 → ip-api.com 兜底; 均不可达 → unreachable
    def combine(baidu, ipapi)
      case ipapi[:state]
      when :ok
        if baidu[:state] == :partial
          merged = GeoQuery::Merge.fields(baidu[:fields], ipapi[:fields])
          # 百度 scene (IDC/家宽等场景) 在叠加后用途仍未知时兜底
          scene = baidu[:scene].to_s
          merged["usage"] = scene if merged["usage"] == "未知" && !scene.empty?
          { state: :ok, fields: merged, message: "",
            source: "gen-get(baidu+ip-api.com)" }
        elsif baidu[:state] == :unreachable
          { state: :ok, fields: ipapi[:fields],
            message: "百度接口不可达 (#{baidu[:message]}), 已由 ip-api.com 返回",
            source: "gen-get(ip-api.com)" }
        else
          { state: :ok, fields: ipapi[:fields], message: "",
            source: "gen-get(ip-api.com)" }
        end
      when :empty
        case baidu[:state]
        when :partial
          { state: :ok, fields: baidu[:fields],
            message: "ip-api.com 确认无归属 (#{ipapi[:message]}), 保留百度部分结果",
            source: "gen-get(baidu)" }
        when :empty
          { state: :empty,
            message: "#{baidu[:message]}; ip-api.com 确认无归属 (#{ipapi[:message]})" }
        else
          { state: :unreachable,
            message: "百度接口不可达 (#{baidu[:message]}); " \
                     "ip-api.com 确认无归属 (#{ipapi[:message]})" }
        end
      else # :unreachable
        case baidu[:state]
        when :partial
          { state: :ok, fields: baidu[:fields],
            message: "ip-api.com 不可达 (#{ipapi[:message]}), 保留百度部分结果",
            source: "gen-get(baidu)" }
        when :empty
          # 同上: 百度确认无归属的结论优先于 ip-api.com 网络不可达
          { state: :empty,
            message: "#{baidu[:message]}; " \
                     "ip-api.com 不可达 (#{ipapi[:message]}), 以百度结论为准" }
        else
          { state: :unreachable,
            message: "百度接口不可达 (#{baidu[:message]}); " \
                     "ip-api.com 不可达 (#{ipapi[:message]})" }
        end
      end
    end

    # ---- 百度智能IP定位 -------------------------------------------------------

    # 发请求并归类, 返回:
    #   { state: :ok,         fields: {...}, scene: "..." }  省市定位成功
    #   { state: :partial,    fields: {...}, scene: "..." }  仅有国家/运营商
    #   { state: :empty,      message: "..." }               确认无归属
    #   { state: :unreachable, message: "..." }              接口异常
    def fetch_baidu(ip)
      uri = URI(@baidu_api.sub("{ip}", URI.encode_www_form_component(ip)))
      res = Net::HTTP.start(uri.hostname, uri.port,
                            use_ssl: uri.scheme == "https",
                            open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.get(uri.request_uri, BAIDU_HEADERS)
      end
      case res.code.to_i
      when 200
        parse_baidu(res.body)
      when 429
        { state: :unreachable, message: "百度接口限速 (HTTP 429), 稍后重试" }
      else
        { state: :unreachable, message: "百度接口返回 HTTP #{res.code}" }
      end
    rescue JSON::ParserError
      { state: :unreachable, message: "百度接口响应非 JSON" }
    rescue => e
      { state: :unreachable, message: "#{e.class}: #{e.message}" }
    end

    # 百度响应 → 三态归类
    #   {"code":200,"data":{"country":"中国","province":"浙江省","city":"金华市",
    #    "isp":"中国电信","scene":"IDC",...,"query_ip":"60.188.84.0"}}
    #   私有/保留地址: data 归属字段全空, scene 标注"私有地址"/"示例地址"
    def parse_baidu(body)
      parsed = JSON.parse(body)
      return { state: :unreachable, message: "百度接口返回 code=#{parsed['code']}" } \
        unless parsed["code"] == 200

      d = parsed["data"] || {}
      country  = d["country"].to_s
      province = d["province"].to_s
      city     = d["city"].to_s
      isp      = d["isp"].to_s
      scene    = d["scene"].to_s

      if !province.empty? || !city.empty?
        # 省市定位成功 (百度智能定位核心能力) → 查出来了
        { state: :ok, fields: baidu_fields(d), scene: scene }
      elsif !country.empty? || (!isp.empty? && isp != "未知")
        # 仅有国家/运营商 (典型国外 IP) → partial, 交由 ip-api.com 补充
        { state: :partial, fields: baidu_fields(d), scene: scene }
      else
        # 归属字段全空 (私有/保留地址等) → 确认无归属
        { state: :empty,
          message: scene.empty? ? "百度确认无归属" : "百度确认无归属 (#{scene})" }
      end
    rescue JSON::ParserError
      { state: :unreachable, message: "百度接口响应非 JSON" }
    end

    # 百度 data → 归属字段 (isp 直接给中文名, scene 直接作为用途)
    def baidu_fields(d)
      isp = d["isp"].to_s
      scene = d["scene"].to_s
      {
        "country" => d["country"].to_s,
        "province" => d["province"].to_s,
        "city" => d["city"].to_s,
        "isp" => Normalize.isp_from_asn(isp),
        "asn" => "",
        "asn_org" => "",
        "network" => "",
        "usage" => scene.empty? ? Normalize.usage_from_asn(isp) : scene,
      }
    end

    # ---- ip-api.com ----------------------------------------------------------

    # 发请求并归类, 返回:
    #   { state: :ok, fields: {...} } / { state: :empty, message: } /
    #   { state: :unreachable, message: }
    def fetch_ipapi(ip)
      uri = URI(@api.sub("{ip}", URI.encode_www_form_component(ip)))
      res = Net::HTTP.start(uri.hostname, uri.port,
                            open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.get(uri.request_uri)
      end
      case res.code.to_i
      when 200
        body = JSON.parse(res.body)
        if body["status"] == "success"
          { state: :ok, fields: ipapi_fields(body) }
        else
          { state: :empty, message: body["message"].to_s }
        end
      when 429
        { state: :unreachable, message: "#{@ipapi_label} 限速 (HTTP 429), 稍后重试" }
      else
        { state: :unreachable, message: "#{@ipapi_label} 返回 HTTP #{res.code}" }
      end
    rescue JSON::ParserError
      { state: :unreachable, message: "#{@ipapi_label} 响应非 JSON" }
    rescue => e
      { state: :unreachable, message: "#{@ipapi_label} #{e.class}: #{e.message}" }
    end

    # ip-api 响应 → 归属字段 (as 字段格式: "AS4134 Chinanet")
    def ipapi_fields(d)
      asn = ""
      asn_org = d["as"].to_s
      if (m = asn_org.match(/\AAS(\d+)\s+(.*)\z/))
        asn = m[1]
        asn_org = m[2]
      end
      isp_raw = [asn_org, d["isp"]].reject { |s| s.to_s.empty? }.first.to_s
      {
        "country" => d["country"].to_s,
        "province" => d["regionName"].to_s,
        "city" => d["city"].to_s,
        "isp" => Normalize.isp_from_asn(isp_raw),
        "asn" => asn,
        "asn_org" => asn_org,
        "network" => "",
        "usage" => Normalize.usage_from_asn(asn_org),
      }
    end

    # ---- 统一 schema 组装 -----------------------------------------------------

    def compose(ip, raw)
      case raw[:state]
      when :ok
        {
          "ip" => ip,
          "state" => "ok",
          "message" => raw[:message].to_s,
        }.merge(raw[:fields]).merge(
          "source" => raw[:source].to_s,
          "ts" => Time.now.to_i,
        )
      when :empty
        base(ip, "empty", raw[:message]).merge("ts" => Time.now.to_i)
      else
        base(ip, "unreachable", raw[:message]).merge("ts" => Time.now.to_i)
      end
    end

    def base(ip, state, message = "")
      {
        "ip" => ip, "state" => state, "message" => message,
        "country" => "", "province" => "", "city" => "",
        "isp" => "", "asn" => "", "asn_org" => "", "network" => "",
        "usage" => "", "source" => "gen-get",
      }
    end

    # 接口 URL 的 host (用于单接口模式的 source/熔断标注)
    def api_host(url)
      u = URI(url.to_s.sub("{ip}", "0.0.0.0"))
      u.host.to_s
    rescue URI::InvalidURIError
      "custom"
    end
  end
end
