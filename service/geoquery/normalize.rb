# coding: utf-8
# frozen_string_literal: true

# GeoQuery — IP 归属综合查询服务 (本地 geo-api + 互联网 ip-api.com)
#
# 命令行入口: bin/gen-get (纯互联网) / bin/ngeo-get (本地+互联网综合)
# 详见同目录 GeoQuery.md。
module GeoQuery
  # ------------------------------------------------------------------
  # 公共: IP 合法性校验 (含 ":" 按 IPv6, 否则按 IPv4)
  # ------------------------------------------------------------------
  module_function

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

  # ------------------------------------------------------------------
  # 归一化: 运营商 / 用途
  # ------------------------------------------------------------------
  # 移植自 ip_geo_lookup.py 的 _isp_from_asn, 并扩展用途 (usage) 推断:
  #   usage 值域: 云 / IDC / CDN / 教育网 / 运营商 / 企业 / 未知
  module Normalize
    module_function

    # ASN 组织名 → 运营商/机构简称 (中文优先; /x 允许多行书写)
    ISP_RULES = [
      # 三大运营商
      [/chinanet|china[\s-]?telecom|chinatelecom|电信/ix,       "电信"],
      [/china[\s-]?unicom|unicom|联通/ix,                       "联通"],
      [/china[\s-]?mobile|移动|(?:^|\b)cmcc\b/ix,               "移动"],
      [/china[\s-]?radio(?:\s|&)?tv|crtc|广电/ix,                "广电"],
      # 教育 / 鹏博士
      [/cernet|教育/ix,                                          "教育网"],
      [/dr[\s.]?peng|鹏博士|great\s?wall\s?broadband/ix,        "鹏博士"],
      # 云厂商 (先于企业判定)
      [/tencent/ix,                                              "腾讯云"],
      [/alibaba|aliyun/ix,                                       "阿里云"],
      [/huawei/ix,                                               "华为云"],
      [/baidu/ix,                                                "百度云"],
      [/jd[\s-]?cloud|jingdong|京东/ix,                          "京东云"],
      [/volcengine|bytedance|字节|火山/ix,                        "火山引擎"],
      [/ucloud/ix,                                               "UCloud"],
      [/kingsoft|金山/ix,                                        "金山云"],
      [/(?:^|\b)aws\b|amazon/ix,                                 "AWS"],
      [/microsoft|azure/ix,                                      "Azure"],
      [/(?:^|\b)gcp\b|google\s?cloud|google\s?llc|(?:^|\b)google\b/ix,    "谷歌云"],
      [/oracle/ix,                                               "Oracle云"],
      # CDN
      [/cloudflare/ix,                                           "Cloudflare"],
      [/akamai/ix,                                               "Akamai"],
      [/fastly/ix,                                               "Fastly"],
      [/wangsu|网宿|chinacache/ix,                               "网宿CDN"],
    ].freeze

    # ASN 组织名 → 用途类别
    # (正则加 /x: 多行书写时忽略模式空白, 行首缩进不参与匹配)
    USAGE_RULES = [
      [/tencent|alibaba|aliyun|huawei|baidu|jd[\s-]?cloud|jingdong|京东|
        volcengine|bytedance|字节|火山|ucloud|kingsoft|金山|
        (?:^|\b)aws\b|amazon|microsoft|azure|(?:^|\b)gcp\b|google|oracle/ix, "云"],
      [/idc|data[\s-]?cent|数据中心/ix,                                      "IDC"],
      [/cloudflare|akamai|fastly|wangsu|网宿|chinacache|cdn/ix,              "CDN"],
      [/cernet|教育/ix,                                                       "教育网"],
      [/chinanet|china[\s-]?telecom|chinatelecom|电信|china[\s-]?unicom|unicom|联通|
        china[\s-]?mobile|(?:^|\b)cmcc\b|移动|china[\s-]?radio|crtc|广电|
        dr[\s.]?peng|鹏博士/ix,                                              "运营商"],
      [/apple|microsoft|oracle|ibm|intel|cisco|ford|toyota|bank|inc\.?\z/ix,  "企业"],
    ].freeze

    # 从 ASN 组织名推断运营商简称; 无法识别返回原文, 空输入返回空串。
    def isp_from_asn(org)
      return "" if org.to_s.empty?
      ISP_RULES.each { |re, name| return name if org =~ re }
      org.to_s
    end

    # 从 ASN 组织名推断用途类别 (云 / IDC / CDN / 教育网 / 运营商 / 企业 / 未知)
    def usage_from_asn(org)
      return "未知" if org.to_s.empty?
      USAGE_RULES.each { |re, usage| return usage if org =~ re }
      "未知"
    end

    # 综合推断: 依次尝试本地与互联网两方的组织名/ISP 描述,
    # 取第一个能识别出非"未知"用途的结果 (本地优先, 组织名优先)。
    def usage_of(*candidates)
      candidates.each do |c|
        usage = usage_from_asn(c.to_s)
        return usage if usage != "未知"
      end
      "未知"
    end
  end
end
