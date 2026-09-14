# coding: utf-8
# frozen_string_literal: true

require "spec_helper"
require_relative "../service/geoquery/geoquery"
require "tmpdir"

RSpec.describe GeoQuery do
  # ---- IP 校验 -------------------------------------------------------------
  describe ".valid_ip?" do
    it { expect(described_class.valid_ip?("1.2.3.4")).to be true }
    it { expect(described_class.valid_ip?(" 8.8.8.8 ")).to be true }
    it { expect(described_class.valid_ip?("2606:4700::1111")).to be true }
    it { expect(described_class.valid_ip?("::1")).to be true }
    it { expect(described_class.valid_ip?("999.1.1.1")).to be false }
    it { expect(described_class.valid_ip?("1.2.3")).to be false }
    it { expect(described_class.valid_ip?("nonip")).to be false }
    it { expect(described_class.valid_ip?("")).to be false }
    it { expect(described_class.valid_ip?(nil)).to be false }
  end

  # ---- 归一化 ---------------------------------------------------------------
  describe GeoQuery::Normalize do
    subject(:normalize) { described_class }

    describe ".isp_from_asn" do
      it "识别三大运营商" do
        expect(normalize.isp_from_asn("CHINATELECOM Hubei province 5G network")).to eq("电信")
        expect(normalize.isp_from_asn("China Unicom Beijing Province Network")).to eq("联通")
        expect(normalize.isp_from_asn("China Mobile communications corporation")).to eq("移动")
      end

      it "识别云厂商与 CDN" do
        expect(normalize.isp_from_asn("Tencent building, Kejizhongyi Avenue")).to eq("腾讯云")
        expect(normalize.isp_from_asn("Hangzhou Alibaba Advertising Technology")).to eq("阿里云")
        expect(normalize.isp_from_asn("Cloudflare, Inc.")).to eq("Cloudflare")
        expect(normalize.isp_from_asn("GOOGLE, INC.")).to eq("谷歌云")
      end

      it "多行规则不因缩进空白失效" do
        # 回归: 曾因多行正则字面量中的换行缩进导致 China Mobile 识别失败
        expect(normalize.isp_from_asn("China Mobile Group Hubei")).to eq("移动")
      end

      it "无法识别时返回原文, 空输入返回空串" do
        expect(normalize.isp_from_asn("Some Unknown Org")).to eq("Some Unknown Org")
        expect(normalize.isp_from_asn("")).to eq("")
      end
    end

    describe ".usage_from_asn" do
      it "云/IDC/CDN/教育网/运营商/企业" do
        expect(normalize.usage_from_asn("Tencent cloud")).to eq("云")
        expect(normalize.usage_from_asn("Hangzhou Alibaba Cloud")).to eq("云")
        expect(normalize.usage_from_asn("Beijing CNNIC IDC")).to eq("IDC")
        expect(normalize.usage_from_asn("Akamai International")).to eq("CDN")
        expect(normalize.usage_from_asn("CERNET2 IX")).to eq("教育网")
        expect(normalize.usage_from_asn("CHINANET Hubei province network")).to eq("运营商")
        expect(normalize.usage_from_asn("Apple Inc.")).to eq("企业")
      end

      it "空输入返回未知" do
        expect(normalize.usage_from_asn("")).to eq("未知")
        expect(normalize.usage_from_asn(nil)).to eq("未知")
      end
    end

    describe ".usage_of" do
      it "多候选综合, 取第一个可识别者 (本地优先)" do
        expect(normalize.usage_of("", "China Mobile")).to eq("运营商")
        expect(normalize.usage_of("Tencent", "whatever")).to eq("云")
        expect(normalize.usage_of("", "")).to eq("未知")
      end
    end
  end

  # ---- 字段合并 -------------------------------------------------------------
  describe GeoQuery::Merge do
    let(:local) do
      { "country" => "中国", "province" => "", "city" => "",
        "isp" => "电信", "asn" => "4134", "asn_org" => "Chinanet",
        "network" => "1.2.3.0/24", "usage" => "运营商" }
    end
    let(:online) do
      { "country" => "中国", "province" => "湖北", "city" => "武汉",
        "isp" => "电信", "asn" => "4134", "asn_org" => "Chinanet",
        "network" => "", "usage" => "运营商" }
    end

    it "本地缺失字段由互联网补全" do
      merged = GeoQuery::Merge.fields(local, online)
      expect(merged["province"]).to eq("湖北")
      expect(merged["city"]).to eq("武汉")
    end

    it "本地有值字段优先, 网段仅取本地" do
      merged = GeoQuery::Merge.fields(local, online.merge("country" => "China", "network" => "9.9.9.0/24"))
      expect(merged["country"]).to eq("中国")
      expect(merged["network"]).to eq("1.2.3.0/24")
    end

    it "运营商按合并后组织名重新归一化" do
      merged = GeoQuery::Merge.fields(local.merge("asn_org" => "CHINATELECOM Hubei province 5G network"),
                            online)
      expect(merged["isp"]).to eq("电信")
    end

    it "用途综合两方候选推断" do
      merged = GeoQuery::Merge.fields(local.merge("asn_org" => ""), online.merge("asn_org" => "Tencent"))
      expect(merged["usage"]).to eq("云")
    end
  end

  # ---- 缓存 -----------------------------------------------------------------
  describe GeoQuery::Cache do
    it "put/get 往返, 命中标记 cached" do
      Dir.mktmpdir do |dir|
        cache = described_class.new(File.join(dir, "c.json"))
        cache.put("1.2.3.4", { "ip" => "1.2.3.4", "state" => "local" })
        hit = cache.get("1.2.3.4")
        expect(hit["state"]).to eq("local")
        expect(hit["cached"]).to be true
        expect(cache.get("5.6.7.8")).to be_nil
      end
    end

    it "unreachable 状态不落缓存" do
      Dir.mktmpdir do |dir|
        cache = described_class.new(File.join(dir, "c.json"))
        cache.put("1.2.3.4", { "state" => "unreachable" })
        expect(cache.get("1.2.3.4")).to be_nil
      end
    end
  end

  # ---- 本地客户端 fetch_raw (geo-get 底座) -----------------------------------
  describe GeoQuery::LocalClient do
    def stubbed_client(responses)
      client = described_class.new
      client.define_singleton_method(:fetch_endpoint) { |ep, _ip| responses[ep] }
      client
    end

    let(:asn_body) do
      { "network" => "1.2.3.0/24", "autonomous_system_number" => "4134",
        "autonomous_system_organization" => "Chinanet" }
    end

    it "三接口齐查返回原始响应 Hash" do
      client = stubbed_client(country: { "network" => "1.0.0.0/24" },
                              city: nil, asn: asn_body)
      raw = client.fetch_raw("1.2.3.4")
      expect(raw.keys).to eq(%i[country city asn])
      expect(raw[:asn]).to eq(asn_body)
      expect(raw[:city]).to be_nil
    end

    it "单接口选择 (endpoints 子集)" do
      client = stubbed_client(asn: asn_body)
      raw = client.fetch_raw("1.2.3.4", endpoints: %i[asn])
      expect(raw).to eq(asn: asn_body)
    end

    it "任一接口服务不可达 → 立即返回 :unreachable, 不再请求其余接口" do
      requested = []
      client = described_class.new
      client.define_singleton_method(:fetch_endpoint) do |ep, _ip|
        requested << ep
        :unavailable
      end
      expect(client.fetch_raw("1.2.3.4")).to eq(:unreachable)
      expect(requested).to eq(%i[country])   # 首接口失败即终止
    end

    it "lookup: 服务不可达 → state=unavailable" do
      client = stubbed_client(country: :unavailable)
      expect(client.lookup("1.2.3.4")["state"]).to eq("unavailable")
    end

    it "lookup: 三接口均 404 → state=empty" do
      client = stubbed_client(country: nil, city: nil, asn: nil)
      expect(client.lookup("1.2.3.4")["state"]).to eq("empty")
    end

    it "lookup: 命中 → state=ok 且字段归一化" do
      client = stubbed_client(
        country: { "network" => "1.2.3.0/24",
                   "geoname" => { "country_name" => "中国", "country_iso_code" => "CN" } },
        city: { "network" => "1.2.3.0/24",
                "geoname" => { "subdivision_1_name" => "湖北", "city_name" => "武汉" } },
        asn: asn_body,
      )
      r = client.lookup("1.2.3.4")
      expect(r["state"]).to eq("ok")
      expect(r["country"]).to eq("中国")
      expect(r["province"]).to eq("湖北")
      expect(r["city"]).to eq("武汉")
      expect(r["isp"]).to eq("电信")
      expect(r["asn"]).to eq("4134")
      expect(r["network"]).to eq("1.2.3.0/24")
    end

    it "lookup: IP 不合法 → state=invalid" do
      expect(stubbed_client({}).lookup("999.1.1.1")["state"]).to eq("invalid")
    end
  end

  # ---- ngeo 状态机 ----------------------------------------------------------
  describe GeoQuery::NGeo do
    let(:tmpdir) { Dir.mktmpdir }
    let(:ngeo) { described_class.new(cache_file: File.join(tmpdir, "ngeo.json")) }

    def stub_local(result)
      stub = Object.new
      stub.define_singleton_method(:lookup) { |_ip| result }
      ngeo.instance_variable_set(:@local, stub)
    end

    def stub_online(result = nil, &blk)
      stub = Object.new
      if blk
        stub.define_singleton_method(:lookup, &blk)
      else
        stub.define_singleton_method(:lookup) { |_ip| result }
      end
      ngeo.instance_variable_set(:@online, stub)
    end

    def local_result(overrides = {})
      { "ip" => "1.2.3.4", "state" => "ok", "message" => "",
        "country" => "中国", "province" => "", "city" => "",
        "isp" => "电信", "asn" => "4134", "asn_org" => "Chinanet",
        "network" => "1.2.3.0/24", "usage" => "运营商",
        "source" => "geo-get(geo-api)" }.merge(overrides)
    end

    def online_result(overrides = {})
      { "ip" => "1.2.3.4", "state" => "ok", "message" => "",
        "country" => "中国", "province" => "湖北", "city" => "武汉",
        "isp" => "电信", "asn" => "", "asn_org" => "",
        "network" => "", "usage" => "运营商",
        "source" => "gen-get(ip-api.com)" }.merge(overrides)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "本地满意 → state=local, 不触发互联网" do
      stub_local(local_result("province" => "湖北", "city" => "武汉"))
      stub_online(online_result)
      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("local")
      expect(r["sources"]["online"]["state"]).to eq("skipped")
    end

    it "本地不满意 + 互联网 ok → merged, 字段叠加" do
      stub_local(local_result)
      stub_online(online_result)
      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("merged")
      expect(r["province"]).to eq("湖北")
      expect(r["city"]).to eq("武汉")
      expect(r["network"]).to eq("1.2.3.0/24")  # 网段保留本地
      expect(r["asn"]).to eq("4134")            # ASN 取本地
      expect(r["source"]).to eq("ngeo(geo-get+gen-get)")
    end

    it "本地不可用 + 互联网 ok → online" do
      stub_local(local_result("state" => "unavailable"))
      stub_online(online_result)
      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("online")
      expect(r["source"]).to eq("ngeo(gen-get)")
    end

    it "本地部分 + 互联网不可达 → local-partial (本地空 < 互联网, 但互联网空更差)" do
      stub_local(local_result)
      stub_online(online_result("state" => "unreachable", "message" => "timeout"))
      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("local-partial")
      expect(r["asn"]).to eq("4134")  # 保留本地部分结果
      expect(r["message"]).to include("互联网查询不可达")
      expect(r["state"]).to_not eq("unreachable")
    end

    it "本地空 + 互联网不可达 → unreachable 空结果状态 (最低优先级)" do
      stub_local(local_result("state" => "empty"))
      stub_online(online_result("state" => "unreachable", "message" => "timeout"))
      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("unreachable")
      expect(r["country"]).to eq("")
      expect(r["message"]).to include("互联网查询不可达")
    end

    it "本地空 + 互联网确认无归属 → empty" do
      stub_local(local_result("state" => "empty"))
      stub_online(online_result("state" => "empty", "message" => "private range"))
      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("empty")
    end

    it "结果写入缓存, 下次命中直接返回" do
      stub_local(local_result)
      stub_online(online_result)
      r1 = ngeo.lookup("1.2.3.4")
      expect(r1["cached"]).to be_nil

      r2 = ngeo.lookup("1.2.3.4")
      expect(r2["cached"]).to be true
      expect(r2["state"]).to eq(r1["state"])
    end

    it "unreachable / local-partial 不写缓存" do
      stub_local(local_result)
      stub_online(online_result("state" => "unreachable", "message" => "timeout"))
      ngeo.lookup("1.2.3.4")
      expect(ngeo.cache.get("1.2.3.4")).to be_nil
    end

    it "refresh 跳过缓存" do
      stub_local(local_result)
      stub_online(online_result)
      ngeo.lookup("1.2.3.4")

      stub_local(local_result("province" => "湖北", "city" => "武汉"))
      r = ngeo.lookup("1.2.3.4", refresh: true)
      expect(r["state"]).to eq("local")
    end

    it "no_local 跳过本地, 纯互联网" do
      stub_local(local_result)
      stub_online(online_result)
      r = ngeo.lookup("1.2.3.4", no_local: true)
      expect(r["state"]).to eq("online")
    end

    it "IP 不合法 → invalid" do
      expect(ngeo.lookup("999.1.1.1")["state"]).to eq("invalid")
      expect(ngeo.lookup("nonip")["state"]).to eq("invalid")
    end

    it "连续 3 次不可达后熔断: 不再发在线请求" do
      calls = []
      stub_online { |ip| calls << ip; { "state" => "unreachable", "message" => "down" } }
      stub_local(local_result("state" => "empty"))

      4.times { ngeo.lookup("1.2.3.4") }
      # 第 4 次触发熔断, 在线查询只发出 3 次
      expect(calls.size).to eq(3)
    end
  end
end
