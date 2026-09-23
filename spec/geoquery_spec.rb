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

    it "网段: base 空时取 supp (缓存网段补给本地)" do
      merged = GeoQuery::Merge.fields(local.merge("network" => ""), online.merge("network" => "9.9.9.0/24"))
      expect(merged["network"]).to eq("9.9.9.0/24")
      expect(merged["province"]).to eq("湖北")
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

  # ---- GEO_CACHE 外带缓存 ---------------------------------------------------
  describe GeoQuery::GeoCache do
    def write_cache(dir, file, entries)
      FileUtils.mkdir_p(dir)
      File.binwrite(File.join(dir, file), JSON.generate(entries))
    end

    def entry(overrides = {})
      { "state" => "local", "country" => "中国", "province" => "湖北",
        "city" => "武汉", "isp" => "电信", "asn" => "4134",
        "asn_org" => "Chinanet", "network" => "1.2.3.0/24",
        "usage" => "运营商" }.merge(overrides)
    end

    describe ".parse_order" do
      it "合法顺位解析" do
        expect(described_class.parse_order("cache,local,internet")).to eq(%w[cache local internet])
        expect(described_class.parse_order("local,internet,cache")).to eq(%w[local internet cache])
        expect(described_class.parse_order("local internet cache")).to eq(%w[local internet cache])
        expect(described_class.parse_order("local")).to eq(%w[local])
      end

      it "非法顺位返回 nil (重复/未知源/为空)" do
        expect(described_class.parse_order("local,local")).to be_nil
        expect(described_class.parse_order("local,xxx")).to be_nil
        expect(described_class.parse_order("")).to be_nil
        expect(described_class.parse_order(nil)).to be_nil
      end
    end

    describe ".to_geolite" do
      it "转换为各接口的 GeoLite2 风格响应" do
        hit = entry
        city = described_class.to_geolite(:city, hit)
        expect(city["geoname"]["subdivision_1_name"]).to eq("湖北")
        expect(city["geoname"]["city_namezh"]).to eq("武汉")
        expect(city["cached"]).to be true
        expect(city["network"]).to eq("1.2.3.0/24")

        country = described_class.to_geolite(:country, hit)
        expect(country["geoname"]["country_name"]).to eq("中国")

        asn = described_class.to_geolite(:asn, hit)
        expect(asn["autonomous_system_number"]).to eq("4134")
        expect(asn["autonomous_system_organization"]).to eq("Chinanet")
      end

      it "对应字段缺失返回 nil (视作该接口无数据)" do
        expect(described_class.to_geolite(:asn, entry("asn" => ""))).to be_nil
        expect(described_class.to_geolite(:city, entry("province" => "", "city" => ""))).to be_nil
        expect(described_class.to_geolite(:country, entry("country" => ""))).to be_nil
      end

      it "tag 参数: 互联网兜底标记 online (默认 cached)" do
        hit = entry
        online = described_class.to_geolite(:city, hit, tag: "online")
        expect(online["online"]).to be true
        expect(online).to_not have_key("cached")
        expect(online["geoname"]["city_namezh"]).to eq("武汉")

        cached = described_class.to_geolite(:city, hit)
        expect(cached["cached"]).to be true
      end
    end

    it "lookup: 单文件命中附加 cached, 未命中返回 nil" do
      Dir.mktmpdir do |dir|
        write_cache(dir, "geocache20260901.json",
                    { "1.2.3.4" => entry.merge("ts" => 100) })
        gc = described_class.new(dir)
        hit = gc.lookup("1.2.3.4")
        expect(hit["province"]).to eq("湖北")
        expect(hit["cached"]).to be true
        expect(gc.lookup("5.6.7.8")).to be_nil
      end
    end

    it "lookup: 非法文件名不参与 (geocache.json / 14 位标签)" do
      Dir.mktmpdir do |dir|
        write_cache(dir, "geocache.json", { "1.2.3.4" => entry })
        write_cache(dir, "geocache20260901123456.json", { "1.2.3.4" => entry })
        write_cache(dir, "other.json", { "1.2.3.4" => entry })
        expect(described_class.new(dir).lookup("1.2.3.4")).to be_nil
      end
    end

    it "lookup: 多文件命中取 ts 最新; 目录新增文件自动感知" do
      Dir.mktmpdir do |dir|
        write_cache(dir, "geocache20260901.json",
                    { "1.2.3.4" => entry("city" => "旧城市", "ts" => 100) })
        gc = described_class.new(dir)
        expect(gc.lookup("1.2.3.4")["city"]).to eq("旧城市")

        write_cache(dir, "geocache20260910.json",
                    { "1.2.3.4" => entry("city" => "新城市", "ts" => 200) })
        expect(gc.lookup("1.2.3.4")["city"]).to eq("新城市")
      end
    end

    it "put_batch: 写入当天文件, 已有文件合并覆盖同 IP" do
      Dir.mktmpdir do |dir|
        write_cache(dir, "geocache#{Time.now.strftime('%Y%m%d')}.json",
                    { "1.2.3.4" => entry("city" => "旧值", "ts" => 100) })
        out = described_class.new(dir).put_batch(
          [{ "ip" => "1.2.3.4", "state" => "merged", "country" => "中国",
             "province" => "北京", "city" => "新值" }])
        expect(out["entries"]).to eq(1)
        data = JSON.parse(File.binread(out["file"]))
        expect(data["1.2.3.4"]["city"]).to eq("新值")
        expect(data["1.2.3.4"]["ts"]).to be > 100
      end
    end

    it "put_batch: 不可缓存状态 (unreachable/invalid) 不落盘" do
      Dir.mktmpdir do |dir|
        out = described_class.new(dir).put_batch(
          [{ "ip" => "1.2.3.4", "state" => "unreachable" },
           { "ip" => "999.1.1.1", "state" => "local" }])
        expect(out).to be_nil
        expect(Dir.children(dir)).to be_empty
      end
    end

    it "merge!: 合并全部缓存文件, 同 IP 取 ts 最新, 生成新文件" do
      Dir.mktmpdir do |dir|
        write_cache(dir, "geocache20260901.json",
                    { "1.2.3.4" => entry("city" => "旧值", "ts" => 100),
                      "5.6.7.8" => entry.merge("ts" => 100) })
        write_cache(dir, "geocache20260910.json",
                    { "1.2.3.4" => entry("city" => "新值", "ts" => 200) })
        stats = described_class.new(dir).merge!
        expect(stats["files"]).to eq(2)
        expect(stats["entries"]).to eq(2)
        expect(File.basename(stats["output"]))
          .to eq("geocache#{Time.now.strftime('%Y%m%d')}.json")
        data = JSON.parse(File.binread(stats["output"]))
        expect(data["1.2.3.4"]["city"]).to eq("新值")
        expect(data["5.6.7.8"]["province"]).to eq("湖北")
      end
    end

    it "stats: 目录统计" do
      Dir.mktmpdir do |dir|
        write_cache(dir, "geocache20260901.json",
                    { "1.2.3.4" => entry.merge("ts" => 100),
                      "5.6.7.8" => entry("state" => "empty").merge("ts" => 100) })
        stats = described_class.new(dir).stats
        expect(stats["files"]).to eq(1)
        expect(stats["entries"]).to eq(2)
        expect(stats["states"]["local"]).to eq(1)
        expect(stats["states"]["empty"]).to eq(1)
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

  # ---- 互联网客户端 (百度智能IP定位 → ip-api.com 链式) -----------------------
  describe GeoQuery::OnlineClient do
    def baidu_ok(over = {})
      { state: :ok,
        fields: { "country" => "中国", "province" => "浙江省", "city" => "金华市",
                  "isp" => "电信", "asn" => "", "asn_org" => "", "network" => "",
                  "usage" => "IDC" }.merge(over),
        scene: "IDC" }
    end

    # 百度仅定位到国家/运营商 (典型国外 IP, 无省市)
    def baidu_partial(over = {}, scene: "IDC")
      { state: :partial,
        fields: { "country" => "美国", "province" => "", "city" => "",
                  "isp" => "谷歌公司", "asn" => "", "asn_org" => "", "network" => "",
                  "usage" => scene }.merge(over),
        scene: scene }
    end

    BAIDU_EMPTY = { state: :empty, message: "百度确认无归属 (私有地址)" }.freeze
    BAIDU_DOWN  = { state: :unreachable, message: "Errno::ECONNREFUSED" }.freeze

    def ipapi_ok(over = {})
      { state: :ok,
        fields: { "country" => "美国", "province" => "", "city" => "",
                  "isp" => "谷歌云", "asn" => "15169", "asn_org" => "Google LLC",
                  "network" => "", "usage" => "云" }.merge(over) }
    end

    IPAPI_EMPTY = { state: :empty, message: "private range" }.freeze
    IPAPI_DOWN  = { state: :unreachable, message: "timeout" }.freeze

    let(:client) { described_class.new(timeout: 1) }

    def stub_fetch(target, name, result)
      blk = result.respond_to?(:call) ? result : ->(_ip) { result }
      target.define_singleton_method(name) { |ip| blk.call(ip) }
    end

    it "百度省市定位成功 → 直接返回, 不再请求 ip-api.com" do
      ipapi_calls = []
      stub_fetch(client, :fetch_baidu, baidu_ok)
      stub_fetch(client, :fetch_ipapi, ->(ip) { ipapi_calls << ip; IPAPI_EMPTY })
      r = client.lookup("60.188.84.0")
      expect(r["state"]).to eq("ok")
      expect(r["province"]).to eq("浙江省")
      expect(r["city"]).to eq("金华市")
      expect(r["usage"]).to eq("IDC")
      expect(r["source"]).to eq("gen-get(baidu)")
      expect(ipapi_calls).to be_empty
    end

    it "百度仅国家/运营商 (国外 IP) + ip-api ok → 字段级叠加, 百度优先" do
      stub_fetch(client, :fetch_baidu, baidu_partial)
      stub_fetch(client, :fetch_ipapi,
                 ipapi_ok("province" => "California", "city" => "Los Angeles"))
      r = client.lookup("8.8.8.8")
      expect(r["state"]).to eq("ok")
      expect(r["country"]).to eq("美国")            # 百度优先
      expect(r["province"]).to eq("California")     # ip-api 补
      expect(r["asn"]).to eq("15169")               # ip-api 补
      expect(r["source"]).to eq("gen-get(baidu+ip-api.com)")
    end

    it "叠加后用途未知时用百度 scene 兜底" do
      stub_fetch(client, :fetch_baidu,
                 baidu_partial({ "country" => "X国", "isp" => "Some Org" },
                               scene: "企业专线"))
      stub_fetch(client, :fetch_ipapi,
                 ipapi_ok("country" => "X国", "isp" => "Unknown Org",
                          "asn_org" => "Unknown Org", "usage" => "未知"))
      r = client.lookup("8.8.8.8")
      expect(r["usage"]).to eq("企业专线")
    end

    it "百度确认无归属 + ip-api ok → ip-api.com 兜底" do
      stub_fetch(client, :fetch_baidu, BAIDU_EMPTY)
      stub_fetch(client, :fetch_ipapi, ipapi_ok)
      r = client.lookup("1.2.3.4")
      expect(r["state"]).to eq("ok")
      expect(r["source"]).to eq("gen-get(ip-api.com)")
      expect(r["asn"]).to eq("15169")
    end

    it "百度与 ip-api 均确认无归属 → empty" do
      stub_fetch(client, :fetch_baidu, BAIDU_EMPTY)
      stub_fetch(client, :fetch_ipapi, IPAPI_EMPTY)
      r = client.lookup("10.20.30.40")
      expect(r["state"]).to eq("empty")
      expect(r["message"]).to include("private range")
    end

    it "百度不可达 + ip-api ok → ip-api.com 返回并附降级说明" do
      stub_fetch(client, :fetch_baidu, BAIDU_DOWN)
      stub_fetch(client, :fetch_ipapi, ipapi_ok)
      r = client.lookup("1.2.3.4")
      expect(r["state"]).to eq("ok")
      expect(r["source"]).to eq("gen-get(ip-api.com)")
      expect(r["message"]).to include("百度接口不可达")
    end

    it "百度部分结果 + ip-api 不可达 → 保留百度部分结果 (ok)" do
      stub_fetch(client, :fetch_baidu, baidu_partial)
      stub_fetch(client, :fetch_ipapi, IPAPI_DOWN)
      r = client.lookup("8.8.8.8")
      expect(r["state"]).to eq("ok")
      expect(r["country"]).to eq("美国")
      expect(r["source"]).to eq("gen-get(baidu)")
      expect(r["message"]).to include("ip-api.com 不可达")
    end

    it "百度确认无归属 + ip-api 不可达 → empty (百度结论优先, 可落缓存)" do
      stub_fetch(client, :fetch_baidu, BAIDU_EMPTY)
      stub_fetch(client, :fetch_ipapi, IPAPI_DOWN)
      r = client.lookup("10.20.30.40")
      expect(r["state"]).to eq("empty")
      expect(r["message"]).to include("百度确认无归属")
      expect(r["message"]).to include("ip-api.com 不可达")
    end

    it "百度与 ip-api 均不可达 → unreachable, message 汇总两家" do
      stub_fetch(client, :fetch_baidu, BAIDU_DOWN)
      stub_fetch(client, :fetch_ipapi, IPAPI_DOWN)
      r = client.lookup("1.2.3.4")
      expect(r["state"]).to eq("unreachable")
      expect(r["message"]).to include("百度接口不可达")
      expect(r["message"]).to include("ip-api.com 不可达")
    end

    it "--api 显式覆盖 → 单接口模式, 不请求百度" do
      single = described_class.new(api: "http://192.0.2.1/x/{ip}", timeout: 1)
      baidu_calls = []
      stub_fetch(single, :fetch_baidu, ->(ip) { baidu_calls << ip; baidu_ok })
      stub_fetch(single, :fetch_ipapi, IPAPI_DOWN)
      r = single.lookup("1.2.3.4")
      expect(r["state"]).to eq("unreachable")
      expect(baidu_calls).to be_empty
    end

    it "IP 不合法 → invalid, 不发包" do
      calls = []
      stub_fetch(client, :fetch_baidu, ->(ip) { calls << ip; baidu_ok })
      stub_fetch(client, :fetch_ipapi, ->(ip) { calls << ip; ipapi_ok })
      expect(client.lookup("999.1.1.1")["state"]).to eq("invalid")
      expect(calls).to be_empty
    end

    it "百度连续 3 次不可达 → 熔断, 第 4 次不再发百度请求" do
      baidu_calls = []
      stub_fetch(client, :fetch_baidu, ->(ip) { baidu_calls << ip; BAIDU_DOWN })
      stub_fetch(client, :fetch_ipapi, IPAPI_DOWN)
      4.times { client.lookup("1.2.3.4") }
      expect(baidu_calls.size).to eq(3)

      r = client.lookup("1.2.3.4")
      expect(r["state"]).to eq("unreachable")
      expect(baidu_calls.size).to eq(3)   # 熔断期未再发包
    end
  end

  # ---- 互联网 Provider (限速 + 熔断) ----------------------------------------
  describe GeoQuery::OnlineClient::Provider do
    it "限速: 相邻请求放行间隔不小于设定值" do
      provider = described_class.new("test", 0.2, threshold: 99, cooldown: 60)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      provider.call { { state: :ok } }
      provider.call { { state: :ok } }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      expect(elapsed).to be >= 0.19   # 留少量调度余量
    end

    it "熔断: 连续 N 次不可达后直接返回, 不再执行块" do
      provider = described_class.new("test", 0.0, threshold: 2, cooldown: 60)
      calls = 0
      2.times { provider.call { calls += 1; { state: :unreachable } } }
      r = provider.call { calls += 1; { state: :ok } }
      expect(r[:state]).to eq(:unreachable)
      expect(r[:message]).to include("熔断")
      expect(calls).to eq(2)
    end

    it "成功请求重置熔断计数" do
      provider = described_class.new("test", 0.0, threshold: 2, cooldown: 60)
      provider.call { { state: :unreachable } }
      provider.call { { state: :ok } }
      r = provider.call { { state: :ok } }   # 未达连续 2 次, 不熔断
      expect(r[:state]).to eq(:ok)
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

  # ---- ngeo 三源顺位 (GEO_CACHE) ---------------------------------------------
  describe GeoQuery::NGeo do
    let(:tmpdir) { Dir.mktmpdir }
    let(:cache_dir) { File.join(tmpdir, "geocache") }
    let(:ngeo) do
      described_class.new(cache_file: File.join(tmpdir, "ngeo.json"),
                          geo_cache_dir: cache_dir)
    end

    def stub_local(result)
      stub = Object.new
      calls = []
      stub.define_singleton_method(:lookup) { |_ip| calls << _ip; result }
      stub.define_singleton_method(:calls) { calls }
      ngeo.instance_variable_set(:@local, stub)
      stub
    end

    def stub_online(result = nil, &blk)
      stub = Object.new
      if blk
        stub.define_singleton_method(:lookup, &blk)
      else
        stub.define_singleton_method(:lookup) { |_ip| result }
      end
      ngeo.instance_variable_set(:@online, stub)
      stub
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

    def write_cache_entry(ip, record, file = "geocache20260901.json")
      require "fileutils"
      FileUtils.mkdir_p(cache_dir)
      path = File.join(cache_dir, file)
      data = File.exist?(path) ? JSON.parse(File.binread(path)) : {}
      data[ip] = record.merge("ts" => record["ts"] || 100)
      File.binwrite(path, JSON.generate(data))
    end

    # 给任意 NGeo 实例挂 local/online stub (闭包捕获结果, 不依赖块内作用域)
    def stub_pair(target, local_res, online_res = nil, &online_blk)
      lstub = Object.new
      lstub.define_singleton_method(:lookup) { |_ip| local_res }
      target.instance_variable_set(:@local, lstub)
      ostub = Object.new
      if online_blk
        ostub.define_singleton_method(:lookup, &online_blk)
      else
        ostub.define_singleton_method(:lookup) { |_ip| online_res }
      end
      target.instance_variable_set(:@online, ostub)
    end

    after { FileUtils.remove_entry(tmpdir) }

    it "默认顺位: 缓存命中且满意 → state=cache, 不查本地/互联网" do
      write_cache_entry("1.2.3.4", {
        "state" => "local", "country" => "中国", "province" => "湖北",
        "city" => "武汉", "asn" => "4134", "asn_org" => "Chinanet",
        "network" => "1.2.3.0/24" })
      local = stub_local(local_result)
      stub_online(online_result)

      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("cache")
      expect(r["cached"]).to be true
      expect(r["province"]).to eq("湖北")
      expect(r["network"]).to eq("1.2.3.0/24")
      expect(local.calls).to be_empty       # 本地未查询
      expect(r["sources"]["local"]["state"]).to eq("skipped")
      expect(r["sources"]["online"]["state"]).to eq("skipped")
    end

    it "默认顺位: 缓存 miss → 本地满意 → state=local" do
      local = stub_local(local_result("province" => "湖北", "city" => "武汉"))
      stub_online(online_result)
      r = ngeo.lookup("9.9.9.9")
      expect(r["state"]).to eq("local")
      expect(r["sources"]["cache"]["state"]).to eq("miss")
      expect(local.calls).to eq(["9.9.9.9"])
    end

    it "缓存部分 + 本地补全 → 多源叠加 merged" do
      write_cache_entry("1.2.3.4", {
        "state" => "local", "country" => "中国", "province" => "", "city" => "",
        "asn" => "4134", "asn_org" => "Chinanet", "network" => "1.2.3.0/24" })
      stub_local(local_result("province" => "湖北", "city" => "武汉"))
      stub_online(online_result)

      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("merged")
      expect(r["source"]).to eq("ngeo(geo-cache+geo-get)")
      expect(r["province"]).to eq("湖北")
      expect(r["network"]).to eq("1.2.3.0/24")
    end

    it "-p local,internet,cache: 本地满意 → 不查缓存 (顺序生效)" do
      write_cache_entry("1.2.3.4", {
        "state" => "local", "province" => "缓存省",
        "city" => "缓存市", "asn" => "4134" })
      ordered = described_class.new(
        cache_file: File.join(tmpdir, "n2.json"),
        geo_cache_dir: cache_dir, order: "local,internet,cache")
      stub_pair(ordered, local_result("province" => "湖北", "city" => "武汉"),
                online_result)

      r = ordered.lookup("1.2.3.4")
      expect(r["state"]).to eq("local")
      expect(r["sources"]["cache"]["state"]).to eq("skipped")
      expect(r["sources"]["online"]["state"]).to eq("skipped")
    end

    it "-p local,internet,cache: 本地不满意 + 互联网不可达 → 缓存兑底叠加" do
      write_cache_entry("1.2.3.4", {
        "state" => "local", "country" => "中国", "province" => "湖北",
        "city" => "武汉", "asn" => "4134", "asn_org" => "Chinanet",
        "network" => "1.2.3.0/24" })
      ordered = described_class.new(
        cache_file: File.join(tmpdir, "n2.json"),
        geo_cache_dir: cache_dir, order: "local,internet,cache")
      down = { "state" => "unreachable", "message" => "timeout" }
      stub_pair(ordered, local_result, nil) { |_ip| down }

      r = ordered.lookup("1.2.3.4")
      expect(r["state"]).to eq("merged")     # 本地部分 + 缓存叠加
      expect(r["province"]).to eq("湖北")
      expect(r["asn"]).to eq("4134")
    end

    it "缓存 empty 记录: 各源均确认无归属 → empty" do
      write_cache_entry("1.2.3.4", { "state" => "empty" })
      stub_local(local_result("state" => "empty"))
      stub_online(online_result("state" => "empty", "message" => "private range"))

      r = ngeo.lookup("1.2.3.4")
      expect(r["state"]).to eq("empty")
      expect(r["sources"]["cache"]["state"]).to eq("empty")
    end

    it "缓存命中不满意且无更多补充 → cache-partial" do
      write_cache_entry("1.2.3.4", {
        "state" => "local", "country" => "中国", "province" => "", "city" => "",
        "asn" => "", "asn_org" => "", "network" => "1.2.3.0/24" })
      ordered = described_class.new(
        cache_file: File.join(tmpdir, "n2.json"),
        geo_cache_dir: cache_dir, order: "cache,local")
      down_local = { "state" => "unavailable", "message" => "geo-api 服务不可达" }
      stub_pair(ordered, down_local)

      r = ordered.lookup("1.2.3.4")
      expect(r["state"]).to eq("cache-partial")
      expect(r["network"]).to eq("1.2.3.0/24")
      expect(r["cached"]).to be true
    end

    it "refresh: 跳过 GEO_CACHE 强制重查" do
      write_cache_entry("1.2.3.4", {
        "state" => "local", "province" => "缓存省",
        "city" => "缓存市", "asn" => "4134" })
      stub_local(local_result("province" => "湖北", "city" => "武汉"))
      stub_online(online_result)

      r = ngeo.lookup("1.2.3.4", refresh: true)
      expect(r["state"]).to eq("local")
      expect(r["province"]).to eq("湖北")
      expect(r["sources"]["cache"]["state"]).to eq("skipped")
    end

    it "缓存命中结果写入会话缓存, 二次查询直接命中" do
      write_cache_entry("1.2.3.4", {
        "state" => "local", "country" => "中国", "province" => "湖北",
        "city" => "武汉", "asn" => "4134", "asn_org" => "Chinanet" })
      stub_local(local_result)
      stub_online(online_result)

      r1 = ngeo.lookup("1.2.3.4")
      expect(r1["state"]).to eq("cache")
      r2 = ngeo.lookup("1.2.3.4")
      expect(r2["state"]).to eq("cache")
      expect(r2["cached"]).to be true
    end

    it "无 -a 时 cache 源不参与 (行为与原模型一致)" do
      plain = described_class.new(cache_file: File.join(tmpdir, "n3.json"))
      stub_pair(plain, local_result("province" => "湖北", "city" => "武汉"),
                online_result)

      r = plain.lookup("1.2.3.4")
      expect(r["state"]).to eq("local")
      expect(r["sources"]).to_not have_key("cache")
    end
  end
end
