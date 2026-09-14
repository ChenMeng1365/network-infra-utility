# coding: utf-8
# frozen_string_literal: true

require_relative "normalize"

module GeoQuery
  # ------------------------------------------------------------------
  # 字段级合并 — 本地 (geo-get) 与互联网 (gen-get) 结果叠加
  # ------------------------------------------------------------------
  # 综合两方准确字段得出最终结果, 重点字段: 省 (Province) / 城市 (City) /
  # 用途 (IDC、云)。择优原则:
  #
  #   country / province / city / asn / asn_org : 本地优先, 本地空取互联网
  #     (GeoLite2 网段级数据有值时可信度高; 实践中本地省市缺失率高,
  #      由 ip-api.com 补全 — 对应 ip_geo_lookup.py 的补全策略)
  #   network : 仅本地有 (网段 CIDR), 原样保留
  #   isp     : 按合并后的 asn_org 重新归一化
  #   usage   : 两方组织名综合推断, 取第一个识别出具体用途者 (本地优先)
  module Merge
    module_function

    FIELDS = %w[country province city asn asn_org].freeze

    # local / online 为统一 schema 的 Hash, 返回合并后的字段 Hash
    # (不含 ip/state/message/source/sources, 由上层组装)
    def fields(local, online)
      local   ||= {}
      online  ||= {}

      merged = {}
      FIELDS.each do |f|
        merged[f] = nz(local[f]).empty? ? nz(online[f]) : nz(local[f])
      end
      # 网段: 本地独有
      merged["network"] = nz(local["network"])

      # 运营商: 用合并后的组织名重新归一化 (长名 → 简称)
      merged["isp"] = Normalize.isp_from_asn(merged["asn_org"])

      # 用途: 两方组织名综合推断
      merged["usage"] = Normalize.usage_of(local["asn_org"], online["asn_org"],
                                           local["isp"], online["isp"])

      merged
    end

    def nz(v)
      v.nil? ? "" : v.to_s
    end
  end
end
