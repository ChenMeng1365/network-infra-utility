# coding: utf-8
# frozen_string_literal: true

require_relative "normalize"

module GeoQuery
  # ------------------------------------------------------------------
  # 字段级合并 — 按顺位折叠: 先查的源 (base) 与后查的源 (supp) 结果叠加
  # ------------------------------------------------------------------
  # 综合两方准确字段得出最终结果, 重点字段: 省 (Province) / 城市 (City) /
  # 用途 (IDC、云)。择优原则:
  #
  #   country / province / city / asn / asn_org : base 优先, base 空取 supp
  #     (GeoLite2 网段级数据有值时可信度高; 实践中本地省市缺失率高,
  #      由 ip-api.com / GEO_CACHE 补全 — 对应 ip_geo_lookup.py 的补全策略)
  #   network : base 优先, base 空取 supp (网段 CIDR 谁有取谁;
  #     互联网源恒为空, 实际补给来自本地库与 GEO_CACHE 缓存)
  #   isp     : 按合并后的 asn_org 重新归一化
  #   usage   : 两方组织名综合推断, 取第一个识别出具体用途者 (base 优先)
  module Merge
    module_function

    FIELDS = %w[country province city asn asn_org].freeze

    # base / supp 为统一 schema 的 Hash (local/online 或任意两源折叠),
    # 返回合并后的字段 Hash (不含 ip/state/message/source/sources, 由上层组装)
    def fields(base, supp)
      base ||= {}
      supp ||= {}

      merged = {}
      FIELDS.each do |f|
        merged[f] = nz(base[f]).empty? ? nz(supp[f]) : nz(base[f])
      end
      # 网段: base 优先, 空取 supp (互联网源无网段, 缓存/本地有)
      merged["network"] = nz(base["network"]).empty? ? nz(supp["network"]) : nz(base["network"])

      # 运营商: 用合并后的组织名重新归一化 (长名 → 简称)
      merged["isp"] = Normalize.isp_from_asn(merged["asn_org"])

      # 用途: 两方组织名综合推断
      merged["usage"] = Normalize.usage_of(base["asn_org"], supp["asn_org"],
                                           base["isp"], supp["isp"])

      merged
    end

    def nz(v)
      v.nil? ? "" : v.to_s
    end
  end
end
