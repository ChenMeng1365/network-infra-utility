# coding: utf-8
# frozen_string_literal: true

# GeoQuery — IP 归属综合查询服务 (GEO_CACHE 缓存 + 本地 geo-api + 互联网 百度智能IP定位→ip-api.com)
#
# 命令行入口: bin/gen-get (纯互联网) / bin/ngeo-get (缓存+本地+互联网综合)
# 详见同目录 GeoQuery.md。
#
# 查询模型 (ngeo, 三源顺位编排 — 顺位即优先级, 满意即停, 字段叠加):
#
#   1. 会话缓存 (ngeo-cache.json) 命中 → 直接返回
#   2. 按 -p 顺位逐源查询 (默认 cache → local → internet):
#      - cache    GEO_CACHE 外带缓存目录 (geocacheXXXXXXXX.json, bin/ngeo-get -a)
#      - local    本地 geo-api 服务 (GeoLite2)
#      - internet 互联网 百度智能IP定位→ip-api.com 链式 (限速 + 熔断保护)
#   3. 每源结果按顺位折叠: 先查的源字段优先, 后查的补空缺
#   4. 折叠后归属满意 (省/市/ASN 齐全) → 提前终止, 不再查后续源
#   5. 全部源查完仍不满意 → 组装终态 (叠加/部分/空/不可达)
#
# 结果状态 (state) 按可信度排序 — 体现 空结果 < 部分 < 缓存 < 实时 < 叠加:
#
#   unreachable   各源均无结果且有不联通 (空结果状态, 最低)
#   local-partial 本地部分结果, 无更多补充 (保留本地字段)
#   cache-partial 缓存部分结果, 无更多补充 (保留缓存字段)
#   empty         各源均确认无归属 (如私有/保留地址)
#   cache         缓存命中且满意
#   local         本地结果满意 (省/市/ASN 齐全)
#   online        纯互联网结果
#   merged        多源叠加综合 (最高)
module GeoQuery
  autoload :Cache,        File.expand_path("cache",     __dir__)
  autoload :GeoCache,     File.expand_path("geo_cache", __dir__)
  autoload :LocalClient,  File.expand_path("local",     __dir__)
  autoload :Merge,        File.expand_path("merge",     __dir__)
  autoload :Normalize,    File.expand_path("normalize", __dir__)
  autoload :OnlineClient, File.expand_path("online",    __dir__)
end

module GeoQuery
  # 可缓存的结果状态 (unreachable / local-partial / cache-partial 不落盘,
  # 下次重查以便互联网恢复后自动补全)
  CACHEABLE_STATES = %w[local merged online empty cache].freeze
end

class GeoQuery::NGeo
  # 满意度判定字段: 省份 / 城市 / ASN (ASN 齐则用途可推断)
  SATISFY_FIELDS = %w[province city asn].freeze

  # 互联网熔断: 连续失败 N 次后, COOLDOWN 秒内跳过在线查询
  BREAKER_THRESHOLD = 3
  BREAKER_COOLDOWN  = 60

  # 默认查询顺位: 缓存 → 本地 → 互联网
  DEFAULT_ORDER = %w[cache local internet].freeze
  # 合法顺位源 (与 GeoQuery::GeoCache::ORDER_SOURCES 一致)
  ORDER_SOURCES = %w[cache local internet].freeze
  # sources 键 → 结果来源标注
  SRC_LABEL = {
    "cache" => "geo-cache",   # GEO_CACHE 外带缓存
    "local" => "geo-get",     # 本地 geo-api
    "online" => "gen-get",    # 互联网 百度智能IP定位→ip-api.com
  }.freeze

  attr_reader :local, :online, :cache, :geo_cache, :order

  def initialize(geoapi_base: nil, api: nil, baidu_api: nil, timeout: 10,
                 cache_dir: nil, cache_file: nil,
                 geo_cache_dir: nil, order: DEFAULT_ORDER)
    base = geoapi_base || ENV["GEO_API_BASE"] || GeoQuery::LocalClient::DEFAULT_BASE
    @local  = GeoQuery::LocalClient.new(base: base)
    @online = GeoQuery::OnlineClient.new(api: api, baidu_api: baidu_api, timeout: timeout)
    dir = cache_dir || GeoQuery::Cache.default_dir
    @cache = GeoQuery::Cache.new(cache_file || File.join(dir, "ngeo-cache.json"))
    @geo_cache = geo_cache_dir ? GeoQuery::GeoCache.new(geo_cache_dir) : nil
    @order = normalize_order(order)
    @breaker_mutex = Mutex.new
    @failures = 0
    @breaker_until = nil
  end

  # 综合查询单个 IP。
  #   refresh:  忽略缓存强制重查 (会话缓存与 GEO_CACHE 均跳过)
  #   no_local: 跳过本地 geo-api
  #   save:     是否把结果写入会话缓存 (默认 true)
  # 查询产出 (geocacheYYYYMMDD.json) 由调用方用 GeoQuery::GeoCache#put_batch 落盘。
  def lookup(ip, refresh: false, no_local: false, save: true)
    ip = ip.to_s.strip
    return invalid_result(ip, "IP 不合法") unless GeoQuery.valid_ip?(ip)

    hit = @cache.get(ip) unless refresh
    return hit if hit

    result = chain_lookup(ip, refresh: refresh, no_local: no_local)
    @cache.put(ip, result) if save && GeoQuery::CACHEABLE_STATES.include?(result["state"])
    result
  end

  def save_cache
    @cache.save
  end

  private

  # ---- 三源顺位编排 ---------------------------------------------------------

  def chain_lookup(ip, refresh: false, no_local: false)
    plan = planned_order(refresh: refresh, no_local: no_local)
    acc = nil
    sources = {}

    # 不参与本次查询的源, 仍按原输出契约标注
    if no_local && @order.include?("local")
      sources["local"] = { "state" => "unavailable", "message" => "本地查询已跳过 (--no-local)" }
    end
    if refresh && @geo_cache && @order.include?("cache")
      sources["cache"] = { "state" => "skipped", "message" => "已忽略缓存强制重查 (--refresh)" }
    end

    plan.each do |src|
      r = query_source(src, ip)
      key = src_key(src)
      sources[key] = note_for(key, r)
      next unless r["state"] == "ok"
      acc = fold(acc, r)
      break if satisfied_fields?(acc)
    end

    # 满意提前终止后, 顺位中剩余未查的源 → skipped
    plan.each do |src|
      key = src_key(src)
      sources[key] = { "state" => "skipped" } unless sources.key?(key)
    end

    assemble(ip, acc, sources)
  end

  # 实际查询的源列表: 顺位中剔除不可用源
  # (无 GEO_CACHE 目录 → cache 源不存在; refresh → 跳过缓存; no_local → 跳过本地)
  def planned_order(refresh: false, no_local: false)
    @order.reject do |src|
      (src == "cache" && (@geo_cache.nil? || refresh)) ||
        (src == "local" && no_local)
    end
  end

  def query_source(src, ip)
    case src
    when "cache"    then query_cache(ip)
    when "local"    then @local.lookup(ip)
    when "internet" then online_with_breaker { @online.lookup(ip) }
    end
  end

  # GEO_CACHE 缓存查询: 命中记录保留产出时的归属字段,
  # 有归属 → 规整为 ok 参与折叠; empty → 确认无归属; 未命中 → miss (继续下一源)
  def query_cache(ip)
    hit = @geo_cache ? @geo_cache.lookup(ip) : nil
    return cache_base(ip, "miss", "GEO_CACHE 缓存未命中") unless hit
    if hit["state"] == "empty"
      cache_base(ip, "empty", "缓存确认无归属")
    else
      cache_base(ip, "ok", "").merge(pick_fields(hit))
    end
  end

  def cache_base(ip, state, message)
    {
      "ip" => ip, "state" => state, "message" => message,
      "country" => "", "province" => "", "city" => "",
      "isp" => "", "asn" => "", "asn_org" => "", "network" => "",
      "usage" => "", "source" => "geo-cache", "cached" => true,
    }
  end

  # 从缓存记录提取归属字段 (剔除 state/message/source/sources/ts/cached)
  def pick_fields(hit)
    hit.select { |k, _| GeoQuery::GeoCache::FIELDS.include?(k) }
  end

  # ---- 折叠 / 终态组装 ------------------------------------------------------

  # acc 优先, r 补空缺 (顺位即优先级)
  def fold(acc, r)
    return r.dup unless acc
    GeoQuery::Merge.fields(acc, r)
  end

  def assemble(ip, acc, sources)
    ok_srcs = sources.select { |_, n| n["state"] == "ok" }.keys
    fields = acc || {}

    state =
      if ok_srcs.empty?
        # 无任何归属字段: 有源确认无归属且无不联通 → empty, 否则 unreachable
        has_empty = sources.values.any? { |n| n["state"] == "empty" }
        net_down  = sources.values.any? { |n| n["state"] == "unreachable" }
        (has_empty && !net_down) ? "empty" : "unreachable"
      elsif ok_srcs.size == 1
        s = ok_srcs.first
        if satisfied_fields?(fields)
          { "cache" => "cache", "local" => "local", "online" => "online" }.fetch(s, "merged")
        elsif s == "local"
          "local-partial"
        elsif s == "cache"
          "cache-partial"
        else
          "online"   # 互联网结果即使不满意仍为 online (对齐原模型)
        end
      else
        "merged"
      end

    # 运营商: 合并后 asn_org 有值时以其归一化 (网段级数据可信);
    # asn_org 为空 (如纯互联网结果, 百度不提供 ASN) 时沿用已归一化的 isp
    isp = if fields["asn_org"].to_s.empty?
            fields["isp"].to_s
          else
            GeoQuery::Normalize.isp_from_asn(fields["asn_org"].to_s)
          end

    {
      "ip" => ip,
      "state" => state,
      "message" => state_message(state, sources),
      "country" => fields["country"].to_s,
      "province" => fields["province"].to_s,
      "city" => fields["city"].to_s,
      "isp" => isp,
      "asn" => fields["asn"].to_s,
      "asn_org" => fields["asn_org"].to_s,
      "network" => fields["network"].to_s,
      "usage" => fields["usage"].to_s,
      "source" => ok_srcs.empty? ? "ngeo" : "ngeo(#{ok_srcs.map { |s| SRC_LABEL[s] }.join('+')})",
      "sources" => sources,
    }.tap do |r|
      r["cached"] = true if ok_srcs.include?("cache")
    end
  end

  # 各源查询说明 → 终态 message
  def state_message(state, sources)
    online = sources["online"]
    case state
    when "unreachable"
      if online && online["state"] == "unreachable"
        "互联网查询不可达: #{online['message']}"
      else
        "各数据源均无结果 (本地无数据/GEO_CACHE 未命中)"
      end
    when "empty"
      if online && online["state"] == "empty"
        "各数据源均确认无归属 (#{online['message']})"
      else
        "各数据源均确认无归属"
      end
    when "local-partial", "cache-partial"
      if online && online["state"] == "unreachable"
        "互联网查询不可达: #{online['message']}"
      elsif online && online["state"] == "empty"
        "互联网确认无归属 (#{online['message']})"
      else
        "其余数据源无补充结果"
      end
    else
      ""
    end
  end

  def note_for(key, client_result)
    note = { "state" => client_result["state"] }
    unless client_result["message"].to_s.empty?
      note["message"] = client_result["message"]
    end
    if client_result["state"] == "ok" && key != "online"
      note["verdict"] = satisfied_fields?(client_result) ? "满意" : "不满意"
    end
    note
  end

  def invalid_result(ip, message)
    {
      "ip" => ip, "state" => "invalid", "message" => message,
      "country" => "", "province" => "", "city" => "",
      "isp" => "", "asn" => "", "asn_org" => "", "network" => "",
      "usage" => "", "source" => "ngeo", "sources" => {},
    }
  end

  # ---- 满意度 / 熔断 --------------------------------------------------------

  # 满意 = 省份、城市、ASN 全部非空 (ASN 有则用途可推断)
  def satisfied_fields?(result)
    SATISFY_FIELDS.all? { |f| !result[f].to_s.empty? }
  end

  # 顺位参数规整: String (经 GeoCache.parse_order) 或 Array;
  # 非法时回退默认顺位
  def normalize_order(order)
    parts = order.is_a?(String) ? GeoQuery::GeoCache.parse_order(order) : order
    unless parts.is_a?(Array) && !parts.empty?
      parts = DEFAULT_ORDER
    end
    parts.select { |s| ORDER_SOURCES.include?(s) }
  end

  # 互联网熔断: 连续 3 次不可达后 60 秒内直接返回 unreachable, 不再发包
  # (OnlineClient 内部另有逐接口限速/熔断; 此处为 internet 源整体二道防线。
  #  锁只覆盖状态读写, HTTP 请求在锁外执行, 不阻塞其他线程的查询)
  def online_with_breaker
    return breaker_result if breaker_open?
    result = yield
    record_online!(result)
    result
  end

  def breaker_open?
    @breaker_mutex.synchronize do
      @breaker_until &&
        Process.clock_gettime(Process::CLOCK_MONOTONIC) < @breaker_until
    end
  end

  def breaker_result
    {
      "state" => "unreachable",
      "message" => "熔断中 (前 #{@failures_total} 次不可达, 暂停在线查询)",
    }
  end

  def record_online!(result)
    @breaker_mutex.synchronize do
      if result["state"] == "unreachable"
        @failures += 1
        if @failures >= BREAKER_THRESHOLD
          @failures_total = BREAKER_THRESHOLD
          @breaker_until = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BREAKER_COOLDOWN
          @failures = 0
        end
      else
        @failures = 0
      end
    end
  end

  # sources 键名: internet 源 → "online" (沿用既有输出契约)
  def src_key(src)
    src == "internet" ? "online" : src
  end
end
