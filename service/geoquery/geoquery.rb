# coding: utf-8
# frozen_string_literal: true

# GeoQuery — IP 归属综合查询服务 (本地 geo-api + 互联网 ip-api.com)
#
# 命令行入口: bin/gen-get (纯互联网) / bin/ngeo-get (本地+互联网综合)
# 详见同目录 GeoQuery.md。
#
# 查询模型 (ngeo, 移植自 ip_geo_lookup.py 并按"叠加综合"需求重构):
#
#   1. 缓存命中 → 直接返回
#   2. 本地接口 (geo-api) 可用 → 使用 geo-get 数据源查询
#   3. 归属满意 (省/市/ASN 齐全) → 直接采用本地结果
#   4. 归属不满意 → 调 gen-get (互联网 ip-api.com) 补全, 与本地字段叠加
#   5. 互联网不通 → 返回"互联网查询不可达"状态; 本地部分结果仍然保留
#
# 结果状态 (state) 按可信度排序 — 体现 互联网空 < 本地空 < 互联网:
#
#   unreachable   本地无可用结果 + 互联网不可达 (空结果状态, 最低)
#   local-partial 本地部分结果 + 互联网不可达/无补充 (保留本地字段)
#   empty         两方均确认无归属 (如私有/保留地址)
#   local         本地结果满意, 无需互联网
#   online        本地无结果, 纯互联网结果
#   merged        本地 + 互联网叠加综合 (最高)
module GeoQuery
  autoload :Cache,    File.expand_path("cache",    __dir__)
  autoload :LocalClient,  File.expand_path("local", __dir__)
  autoload :Merge,    File.expand_path("merge",    __dir__)
  autoload :Normalize, File.expand_path("normalize", __dir__)
  autoload :OnlineClient, File.expand_path("online", __dir__)
end

module GeoQuery
  # 可缓存的结果状态 (unreachable / local-partial 不落盘,
  # 下次重查以便互联网恢复后自动补全)
  CACHEABLE_STATES = %w[local merged online empty].freeze
end

class GeoQuery::NGeo
  # 满意度判定字段: 省份 / 城市 / ASN (ASN 齐则用途可推断)
  SATISFY_FIELDS = %w[province city asn].freeze

  # 互联网熔断: 连续失败 N 次后, COOLDOWN 秒内跳过在线查询
  BREAKER_THRESHOLD = 3
  BREAKER_COOLDOWN  = 60

  attr_reader :local, :online, :cache

  def initialize(geoapi_base: nil, api: nil, timeout: 10,
                 cache_dir: nil, cache_file: nil)
    base = geoapi_base || ENV["GEO_API_BASE"] || GeoQuery::LocalClient::DEFAULT_BASE
    @local  = GeoQuery::LocalClient.new(base: base)
    @online = GeoQuery::OnlineClient.new(api: api, timeout: timeout)
    dir = cache_dir || GeoQuery::Cache.default_dir
    @cache = GeoQuery::Cache.new(cache_file || File.join(dir, "ngeo-cache.json"))
    @breaker_mutex = Mutex.new
    @failures = 0
    @breaker_until = nil
  end

  # 综合查询单个 IP。
  #   refresh:  忽略缓存强制重查
  #   no_local: 跳过本地 geo-api (纯互联网模式)
  #   save:     是否把结果写入缓存 (默认 true)
  def lookup(ip, refresh: false, no_local: false, save: true)
    ip = ip.to_s.strip
    return invalid_result(ip, "IP 不合法") unless GeoQuery.valid_ip?(ip)

    hit = @cache.get(ip) unless refresh
    return hit if hit

    local = no_local ? unavailable_local : @local.lookup(ip)
    return local_result(local) if satisfied?(local)

    online = online_with_breaker { @online.lookup(ip) }
    result = combine(ip, local, online)
    @cache.put(ip, result) if save && GeoQuery::CACHEABLE_STATES.include?(result["state"])
    result
  end

  def save_cache
    @cache.save
  end

  private

  # ---- 各终态组装 ---------------------------------------------------------

  # 本地满意: state=local
  def local_result(local)
    local.merge(
      "state" => "local",
      "source" => "ngeo(geo-get)",
      "sources" => { "local" => src_note(local, "满意"), "online" => { "state" => "skipped" } },
    )
  end

  # 本地 + 互联网各状态组合
  def combine(ip, local, online)
    lstate = local["state"]
    ostate = online["state"]

    result =
      case ostate
      when "ok"
        if lstate == "ok"
          # 叠加综合 (最高)
          { "state" => "merged", "fields" => GeoQuery::Merge.fields(local, online),
            "source" => "ngeo(geo-get+gen-get)", "message" => "" }
        else
          # 本地无结果/不可用, 纯互联网
          { "state" => "online", "fields" => online,
            "source" => "ngeo(gen-get)", "message" => "" }
        end
      when "empty"
        if lstate == "ok"
          { "state" => "local-partial", "fields" => local,
            "source" => "ngeo(geo-get)",
            "message" => "互联网确认无归属数据 (#{online['message']})" }
        else
          { "state" => "empty", "fields" => {},
            "source" => "ngeo",
            "message" => "两方均无归属 (#{online['message']})" }
        end
      else # unreachable
        if lstate == "ok"
          # 互联网空 < 本地空: 保留本地部分结果
          { "state" => "local-partial", "fields" => local,
            "source" => "ngeo(geo-get)",
            "message" => "互联网查询不可达: #{online['message']}" }
        else
          # 空结果状态 (最低): 不采纳任何归属字段
          { "state" => "unreachable", "fields" => {},
            "source" => "ngeo",
            "message" => "互联网查询不可达: #{online['message']}" }
        end
      end

    fields = result.delete("fields")
    online_src = { "state" => ostate }
    online_src["message"] = online["message"] unless online["message"].to_s.empty?

    {
      "ip" => ip,
      "state" => result["state"],
      "message" => result["message"],
      "country" => fields["country"].to_s,
      "province" => fields["province"].to_s,
      "city" => fields["city"].to_s,
      "isp" => GeoQuery::Normalize.isp_from_asn(fields["asn_org"].to_s),
      "asn" => fields["asn"].to_s,
      "asn_org" => fields["asn_org"].to_s,
      "network" => fields["network"].to_s,
      "usage" => fields["usage"].to_s,
      "source" => result["source"],
      "sources" => {
        "local" => src_note(local, satisfied?(local) ? "满意" : "不满意"),
        "online" => online_src,
      },
    }
  end

  def src_note(client_result, verdict)
    note = { "state" => client_result["state"] }
    unless client_result["message"].to_s.empty?
      note["message"] = client_result["message"]
    end
    note["verdict"] = verdict if client_result["state"] == "ok"
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

  def unavailable_local
    {
      "ip" => "", "state" => "unavailable",
      "message" => "本地查询已跳过 (--no-local)",
      "country" => "", "province" => "", "city" => "",
      "isp" => "", "asn" => "", "asn_org" => "", "network" => "",
      "usage" => "", "source" => "geo-get(geo-api)",
    }
  end

  # ---- 满意度 / 熔断 ------------------------------------------------------

  # 满意 = 省份、城市、ASN 全部非空 (ASN 有则用途可推断)
  def satisfied?(local)
    return false unless local["state"] == "ok"
    SATISFY_FIELDS.all? { |f| !local[f].to_s.empty? }
  end

  # 互联网熔断: 连续 3 次不可达后 60 秒内直接返回 unreachable, 不再发包
  def online_with_breaker
    @breaker_mutex.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @breaker_until && now < @breaker_until
        return {
          "state" => "unreachable",
          "message" => "熔断中 (前 #{@failures_total} 次不可达, 暂停在线查询)",
        }
      end
      result = yield
      if result["state"] == "unreachable"
        @failures += 1
        if @failures >= BREAKER_THRESHOLD
          @failures_total = BREAKER_THRESHOLD
          @breaker_until = now + BREAKER_COOLDOWN
          @failures = 0
        end
      else
        @failures = 0
      end
      result
    end
  end
end
