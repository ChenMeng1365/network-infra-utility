# coding: utf-8
# frozen_string_literal: true
# geoquery_example — Geo 系列查询全景用例 (geo-api 服务 + GeoQuery 编排)
# ============================================================
# 合并原 geo_api_query_example.rb (服务端接口) 与旧版 geoquery_example.rb
# (客户端编排), 按"数据服务 → 查询编排"主线组织, 每块发起真实调用并打印
# 响应, 便于阅读:
#
# Part A  geo-api 服务接口直连 (自动在 127.0.0.1:9399 起一个后台 Puma 服务)
#   (一)   健康检查 /                → 确认服务就绪, 返回接口清单
#   (二)   ASN     /geo/asn          → 按 num 查地址段 / 按 addr 查所属 AS
#   (三)   City    /geo/city?id=     → 按 geoname_id 查城市级定位
#   (四)   City    /geo/city?addr=   → 按 IP 查城市归属 (慢, city-IPv4 加载约23s)
#   (五)   Country /geo/country?id=  → 按 geoname_id 查国别
#   (六)   Country /geo/country?addr= → 按 IP 查国家归属
#   (七)   未知路径                  → 404 容错
#
# Part B  GeoQuery 查询编排 (service/geoquery/, 连接 Part A 起的服务)
#   (八)   LocalClient  → geo-get 底座: fetch_raw 原始接口 + lookup 归一化
#   (九)   gen-get      → 互联网查询 (百度智能IP定位 → ip-api.com 链式)
#   (十)   ngeo-get     → 综合查询: 本地优先, 不满意补互联网, 字段叠加
#   (十一) 状态机       → unreachable < local-partial < online 分支
#
# 运行 (项目根目录):
#   ruby document/example/geoquery_example.rb                    # 快速 (跳过 city addr 慢块)
#   ruby document/example/geoquery_example.rb FULL=1            # 含 city addr 慢块全量
#   ruby document/example/geoquery_example.rb SLOW=1            # 同上, 仅启用慢块
#   ruby document/example/geoquery_example.rb GEODB_DATA_DIR=D:/ipdb  PORT=9400
#   ruby document/example/geoquery_example.rb GEOAPI=http://127.0.0.1:9292  # Part B 连已有服务
#
# 环境容忍: 外网不通时 (九)(十)(十一) 展示 unreachable 状态结果并继续, 不判失败。
# 支撑代码 (服务启动 / HTTP 封装) 集中在文件后半, 不介入业务主线。
# ============================================================

# shell 传参 KEY=VAL 统一从 ARGV 解析 (PowerShell 'ruby x.rb FULL=1' 不会注入环境变量)
ARGV.each do |a|
  k, v = a.split('=', 2)
  ENV[k] = v if k && v && k == k.upcase && !ENV.key?(k)
end

# 优先加载工作区代码: 把仓库根插到 $LOAD_PATH 最前,
# 使 api.rb → require 'network' 命中工作区 network.rb (统一入口已挂载 geoquery),
# 避免与已安装 gem 重复加载产生常量重定义警告。
REPO_ROOT = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(REPO_ROOT) unless $LOAD_PATH.include?(REPO_ROOT)

require_relative '../../service/geodb/api'
# 注: 不显式 require version; 版本常量已由 api.rb → require 'network'
# → network.rb → require_relative 'version' 加载, 显式重复 require 会与
# 已安装 gem 的 version.rb 产生常量重定义, 并导致后台 Puma 线程启动阻塞。
# geoquery 亦已由 network.rb 统一入口加载, 无需重复 require。
require 'http_getter'
require 'rack/handler/puma'
require 'socket'
require 'json'

# ============================================================
# Part A — geo-api 服务接口 (GeoAPI 三接口的调用方式与数据流转)
# ============================================================

# ---- (一) 健康检查 ----
# GET /
# 确认服务就绪, 返回服务名、数据目录与三个可用接口的路径清单。
def case_health
  banner '(一) 健康检查  GET /'
  # 调用: GET /
  # 响应: { service, data_dir, endpoints: { asn/city/country } }
  puts get('/')[:json]
end

# ---- (二) ASN: 查 Autonomous System ----
# 接口:
#   GET /geo/asn?num=XXX       按 AS 编号查该 AS 名下所有地址段
#   GET /geo/asn?addr=X.X.X.X  按 IP 反查所属 AS
# 业务:
#   - num: 服务端对 asn.json 建了 num→[records] 反向索引, O(1) 命中;
#          无此 ASN 或 num 非数字均按空结果返回 (count=0, 200), 不报错。
#   - addr: 先 ip_number 转 32/128 位整数, 再在 asn.json 范围表里二分定位;
#           非法 IP → 400 IP不合法; 命中 → 该段 record; 未命中 → 404 无结果。
def case_asn
  banner '(二) ASN  GET /geo/asn'

  # -- 2.1 num 查询: Cloudflare(AS13335) 名下地址段 --
  # 响应: { asn:"13335", count:N, results:[{network, autonomous_system_number, ...}] }
  puts '2.1  num=13335 (Cloudflare)  → 多段命中'
  puts "     count = #{get('/geo/asn', num: '13335')[:json]['count']}"

  # -- 2.2 num 查询: 验证具体网段是否落在结果中 --
  puts '2.2  num=38803  → 含 1.0.4.0/22 ?'
  nets = get('/geo/asn', num: '38803')[:json]['results'].map { |x| x['network'] }
  puts "     命中 #{nets.size} 段, 含 1.0.4.0/22 = #{nets.include?('1.0.4.0/22')}"

  # -- 2.3 num 无此 ASN / 非数字: 均按空结果 (count=0) 返回 --
  puts '2.3  num=999999999 (无此AS) / num=abc (非数字)  → count=0, 200'
  puts "     999999999 → #{get('/geo/asn', num: '999999999')[:json]['count']}"
  puts "     abc       → #{get('/geo/asn', num: 'abc')[:json]['count']}"

  # -- 2.4 addr 查询: 按 IP 反查 AS (依赖 IP 库做整数转换) --
  if IP_AVAILABLE
    puts '2.4  addr 反查 AS'
    puts '     addr=1.0.0.5 (IPv4) → 如下'
    puts get('/geo/asn', addr: '1.0.0.5')[:json]
    puts '     addr=2606:4700:4700::1111 (IPv6, Cloudflare DNS) → 如下'
    puts get('/geo/asn', addr: '2606:4700:4700::1111')[:json]
    # 未命中: 回环/0.0.0.0 等不在任何 AS 段内 → 404
    puts '     addr=0.0.0.0  → 404 无结果'
    puts "     → #{get('/geo/asn', addr: '0.0.0.0')[:json]}"
  else
    puts '2.4  (SKIP) IP 库未实现, addr 合法 IP 会被误判为不合法 → 跳过'
  end

  # -- 2.5 非法 IP / 缺参: 服务端返回 400 --
  puts '2.5  异常输入 → 400'
  r = get('/geo/asn', addr: '999.1.1.1')
  puts "     addr='999.1.1.1'  (#{r[:code]}) #{r[:json]}"
  r = get('/geo/asn', addr: 'nonip')
  puts "     addr='nonip'      (#{r[:code]}) #{r[:json]}"
  r = get('/geo/asn')
  puts "     (缺参)            (#{r[:code]}) #{r[:json]}"
end

# ---- (三) City 按 id 查地理位置 ----
# 接口: GET /geo/city?id=XXX
# 业务: id 为 geoname_id, 在 geo-city.json (扁平 Hash) 中直接 O(1) 取值;
#       id 非数字/空串 → 400 id不合法; 合法但无此记录 → 404 无结果。
def case_city_by_id
  banner '(三) City  GET /geo/city?id='

  # 3.1 id=11797 → 伊朗; id=1814991 → 中国
  # 响应字段: country_iso_code, country_name, time_zone, continent_name ... (中文)
  puts '3.1  id=11797  → 如下 (伊朗)'
  hd = get('/geo/city', id: '11797')[:json]
  puts "     #{hd['country_iso_code']} / #{hd['country_name']} / #{hd['time_zone']}"
  puts '3.2  id=1814991 → 如下 (中国)'
  hd = get('/geo/city', id: '1814991')[:json]
  puts "     #{hd['country_iso_code']} / #{hd['country_name']} / #{hd['time_zone']}"

  # 3.2 id 校验: 非数字 / 含字母 / 空串 → 400
  puts '3.3  id 非法 → 400 id不合法'
  %w[abc 12a3].each do |bad|
    r = get('/geo/city', id: bad)
    puts "     id=#{bad.inspect.ljust(6)} (#{r[:code]}) #{r[:json]}"
  end
  r = get('/geo/city', id: '')
  puts "     id=''       (#{r[:code]}) #{r[:json]}"

  # 3.3 合法 id 但无此记录 → 404
  puts '3.4  id=999999999 (无此记录) → 404'
  r = get('/geo/city', id: '999999999')
  puts "     (#{r[:code]}) #{r[:json]}"
end

# ---- (四) City 按 addr 查归属 (慢, city-IPv4 首次加载约23s) ----
# 接口: GET /geo/city?addr=X.X.X.X
# 业务: 先 ip_number 转整数 → 按地址族在 city-IPv4/city-IPv6 范围表二分定位
#       → 命中后用 enrich() 把 geoname_id / registered_country_geoname_id /
#       represented_country_geoname_id 三个外键关联 geo-city 详情, 输出为
#       geoname / registered_country / represented_country 三个嵌套对象。
#       若 geoname_id 为 null, geoname 落空, 仅 registered_country 可关联。
def case_city_by_addr
  banner '(四) City  GET /geo/city?addr=  [慢: city-IPv4 加载约23s]'
  return puts '  (SKIP) IP 库未实现, 跳过' unless IP_AVAILABLE

  # 4.1 IPv4 命中并关联城市详情 (国别/坐标/精度半径)
  puts '4.1  addr=1.0.1.1 (IPv4) → 命中 1.0.1.0/24, 关联中国'
  r = get('/geo/city', addr: '1.0.1.1')[:json]
  puts "     network = #{r['network']}"
  puts "     geoname = #{r['geoname'] && r['geoname']['country_iso_code']} (#{r['geoname'] && r['geoname']['country_name']})"

  # 4.2 geoname_id 为 null → geoname 落空, 仅 registered_country 关联出注册国
  puts '4.2  addr=1.0.0.5 → geoname_id 为 null, geoname:null, 仅 registered_country'
  r = get('/geo/city', addr: '1.0.0.5')[:json]
  puts "     network = #{r['network']}, geoname = #{r['geoname'].inspect}"
  puts "     registered_country = #{r['registered_country'] && r['registered_country']['country_iso_code']}"

  # 4.3 IPv6 命中: city-IPv6.json 已生成, Cloudflare DNS 可查到记录
  puts '4.3  addr=2606:4700:4700::1111 (IPv6) → 命中 Cloudflare 段'
  r = get('/geo/city', addr: '2606:4700:4700::1111')[:json]
  puts "     network = #{r['network']}"

  # 4.4 非法 IP → 400
  puts '4.4  addr 非法 → 400'
  r = get('/geo/city', addr: '999.1.1.1')
  puts "     (#{r[:code]}) #{r[:json]}"
end

# ---- (五) Country 按 id 查国家 ----
# 接口: GET /geo/country?id=XXX
# 业务: 同 City id 查询, 在 geo-country.json 中 O(1) 取值;
#       id 校验与错误码规则一致。
def case_country_by_id
  banner '(五) Country  GET /geo/country?id='

  puts '5.1  典型命中'
  [['49518', '卢旺达'], ['6252001', '美国'], ['1814991', '中国']].each do |id, name|
    r = get('/geo/country', id: id)[:json]
    puts "     id=#{id.ljust(8)} → #{r['country_iso_code']} / #{r['country_name']}  (期望 #{name})"
  end

  puts '5.2  id 非法 → 400'
  %w[abc 12.3].each do |bad|
    r = get('/geo/country', id: bad)
    puts "     id=#{bad.inspect.ljust(6)} (#{r[:code]}) #{r[:json]}"
  end
  r = get('/geo/country', id: '')
  puts "     id=''       (#{r[:code]}) #{r[:json]}"

  puts '5.3  id=1 (无此记录) → 404'
  r = get('/geo/country', id: '1')
  puts "     (#{r[:code]}) #{r[:json]}"
end

# ---- (六) Country 按 addr 查归属 ----
# 接口: GET /geo/country?addr=X.X.X.X
# 业务: 同 City by addr, 范围表为 country-IPv4/country-IPv6, 关联 geo-country。
#       geoname_id 为 null 时仅 registered_country 给出注册国 (如 Cloudflare 美国)。
#       服务端对 addr 做 strip 容错, 前导/尾随空格会被忽略。
def case_country_by_addr
  banner '(六) Country  GET /geo/country?addr='
  return puts '  (SKIP) IP 库未实现, 跳过' unless IP_AVAILABLE

  # 6.1 IPv4 命中中国
  puts '6.1  addr=1.0.1.1 (IPv4) → 命中中国'
  r = get('/geo/country', addr: '1.0.1.1')[:json]
  puts "     network=#{r['network']}, geoname=#{r['geoname'] && r['geoname']['country_iso_code']}"

  # 6.2 IPv6 命中美国 (注册国, geoname 为 null, 由 registered_country 给出)
  puts '6.2  addr=2606:4700:4700::1111 (Cloudflare) → 注册国美国'
  r = get('/geo/country', addr: '2606:4700:4700::1111')[:json]
  puts "     geoname=#{r['geoname'].inspect}, registered_country=#{r['registered_country'] && r['registered_country']['country_iso_code']}"

  # 6.3 IPv6 命中日本
  puts '6.3  addr=2001:200::1 (IPv6) → 命中日本'
  r = get('/geo/country', addr: '2001:200::1')[:json]
  puts "     geoname=#{r['geoname'] && r['geoname']['country_iso_code']} / #{r['geoname'] && r['geoname']['country_name']}"

  # 6.4 无结果: 回环地址 / 0.0.0.0 不在任何国家段内 → 404
  puts '6.4  无结果 → 404'
  ['::1', '0.0.0.0'].each do |addr|
    r = get('/geo/country', addr: addr)
    puts "     addr=#{addr.ljust(9)} (#{r[:code]}) #{r[:json]}"
  end

  # 6.5 容错: 前导空格自动 strip
  puts '6.5  addr=" 1.0.1.1" (前导空格) → strip 后命中中国'
  r = get('/geo/country', addr: ' 1.0.1.1')[:json]
  puts "     geoname=#{r['geoname'] && r['geoname']['country_iso_code']}"

  # 6.6 非法 IP / 缺参 → 400
  puts '6.6  异常输入 → 400'
  r = get('/geo/country', addr: 'gggg::1')
  puts "     addr=gggg::1  (#{r[:code]}) #{r[:json]}"
  r = get('/geo/country', addr: 'nonip')
  puts "     addr=nonip    (#{r[:code]}) #{r[:json]}"
  r = get('/geo/country')
  puts "     (缺参)        (#{r[:code]}) #{r[:json]}"
end

# ---- (七) 未知路径 ----
# 任意未匹配路径 → 404 {"error":"not found"}
def case_unknown_path
  banner '(七) 未知路径  GET /foo'
  r = get('/foo')
  puts "     (#{r[:code]}) #{r[:json]}"
end

# ============================================================
# Part B — GeoQuery 查询编排 (geo-get / gen-get / ngeo-get 的底座)
# ============================================================

# ---- (八) LocalClient: geo-get 底座 ----
# bin/geo-get 是 GeoQuery::LocalClient 的瘦封装:
#   - fetch_raw: 返回各接口原始响应 (geo-get -j 的数据来源)
#   - lookup:    归一化为统一 schema (ngeo 内部同款)
def case_local_client(base)
  banner '(八) LocalClient — geo-get 底座 (fetch_raw / lookup)'
  local = GeoQuery::LocalClient.new(base: base)

  # 8.1 fetch_raw: 原始接口响应, 支持接口子集
  puts '8.1  fetch_raw("8.8.8.8", endpoints: %i[asn]) → 原始 ASN 响应'
  raw = local.fetch_raw('8.8.8.8', endpoints: %i[asn])
  asn = raw[:asn]
  puts "     AS#{asn['autonomous_system_number']} #{asn['autonomous_system_organization']}  网段 #{asn['network']}"

  # 8.2 lookup: 统一 schema (省/市/ASN/运营商/用途)
  puts '8.2  lookup("219.140.0.1") → 统一 schema (本地省市 ASN 齐全)'
  r = local.lookup('219.140.0.1')
  puts "     state=#{r['state']}  #{r['country']} #{r['province']} #{r['city']}  #{r['isp']}  #{r['usage']}"

  # 8.3 lookup: 本地省市缺失 (由 (十) 的 ngeo 补互联网)
  puts '8.3  lookup("111.8.44.6") → 省市缺失 (归属不满意)'
  r = local.lookup('111.8.44.6')
  puts "     state=#{r['state']}  province=#{r['province'].empty? ? '(缺)' : r['province']}  city=#{r['city'].empty? ? '(缺)' : r['city']}  asn=#{r['asn']}"
end

# ---- (九) gen-get: 互联网查询 ----
# GeoQuery::OnlineClient: 百度智能IP定位 → ip-api.com 双接口链式
# (百度优先, 查不出来才用 ip-api; 每接口独立限速+熔断, 多线程不阻塞)。
# 外网不通时展示 unreachable 状态并继续, 不判失败。
def case_gen_get
  banner '(九) gen-get — 互联网查询 (百度智能IP定位 → ip-api.com 链式)'
  online = GeoQuery::OnlineClient.new(timeout: 8)
  %w[60.188.84.0 8.8.8.8 114.114.114.114 10.20.30.40].each do |ip|
    r = online.lookup(ip)
    if r['state'] == 'unreachable'
      puts "#{ip}: 互联网查询不可达 (#{r['message']}), 继续后续用例"
      next
    end
    show('ip' => ip, 'state' => r['state'], 'country' => r['country'],
         'province' => r['province'], 'city' => r['city'],
         'isp' => r['isp'], 'usage' => r['usage'],
         'asn' => r['asn'], 'asn_org' => r['asn_org'],
         'message' => r['message'])
  end
end

# ---- (十) ngeo-get: 综合查询 ----
# GeoQuery::NGeo: 本地 geo-get 优先 → 归属不满意补互联网 → 字段级叠加。
def case_ngeo_get(base, cache_dir)
  banner '(十) ngeo-get — 本地优先, 不满意补互联网, 字段叠加'
  ngeo = GeoQuery::NGeo.new(geoapi_base: base, cache_dir: cache_dir)

  # 219.140.0.1  本地省市齐全 → local
  # 111.8.44.6   本地省市缺失 → 互联网补全 → merged
  %w[219.140.0.1 111.8.44.6].each do |ip|
    r = ngeo.lookup(ip, refresh: true)
    show('ip' => ip, 'state' => r['state'], 'country' => r['country'],
         'province' => r['province'], 'city' => r['city'],
         'isp' => r['isp'], 'usage' => r['usage'],
         'network' => r['network'], 'source' => r['source'],
         'sources' => r['sources'])
  end
  ngeo.save_cache
end

# ---- (十一) 状态机: 互联网不可达 ----
# 用不通的接口地址模拟断网 (TEST-NET 保留段), 演示状态优先级链:
#   unreachable (本地空+互联网不可达) < local-partial (本地部分结果保留)
def case_state_machine(base, cache_dir)
  banner '(十一) 状态机 — 互联网不可达时: unreachable < local-partial'
  broken = GeoQuery::NGeo.new(
    geoapi_base: base,
    api: 'http://192.0.2.1/json/{ip}?lang=zh-CN',
    timeout: 2,
    cache_dir: cache_dir + '-broken',
  )

  # 本地有部分结果 → local-partial (保留本地字段, 标注不可达)
  r1 = broken.lookup('111.8.44.6', refresh: true)
  puts "本地部分 + 互联网不可达 → #{r1['state']} (province=#{r1['province'].empty? ? '缺' : r1['province']}, asn=#{r1['asn']})"
  puts "  message: #{r1['message']}"

  # 本地空 + 互联网不可达 → unreachable (空结果状态, 价值最低)
  r2 = broken.lookup('10.20.30.40', refresh: true)
  puts "本地空 + 互联网不可达 → #{r2['state']} (全部字段为空)"

  puts
  puts "状态优先级链: unreachable(#{r2['state'] == 'unreachable' ? '✓' : '✗'}) < local-partial(#{r1['state'] == 'local-partial' ? '✓' : '✗'}) < online/merged/local"
end

# ============================================================
# 以下是支撑代码 (配置 / HTTP 调用封装 / 服务启动) —— 非业务主体, 折叠阅读
# ============================================================

# ---- 配置 ----
HOST = '127.0.0.1'
PORT = ENV['PORT'] ? ENV['PORT'].to_i : 9399
BASE = "http://#{HOST}:#{PORT}"
DATA_DIR = ENV['GEODB_DATA_DIR'] || 'E:\workspace\momentum\twinklite\data\geodb'
ENV['GEODB_DATA_DIR'] = DATA_DIR

# api.rb 的 ip_number 依赖自有 IP 类 (IP.v4/IP.v6), 未实现时 addr 合法 IP
# 会被判 IP不合法 → 整组跳过, 待 IP 库落地后自动启用。
IP_AVAILABLE = begin
  defined?(IP) && IP.respond_to?(:v4)
rescue NameError
  false
end

# Part B 连接的本地服务: 优先 GEOAPI 环境变量 (如连已运行的 9292 服务),
# 默认连本例 Part A 起的服务。
GEOAPI_BASE_FOR_QUERY = ENV['GEOAPI'] || BASE

# Part B 缓存目录 (默认 .temp/, 不污染项目根目录)
QUERY_CACHE_DIR = ENV['CACHE_DIR'] || File.join(__dir__, '..', '..', '.temp', 'geoquery-example-cache')

# ---- 轻量 HTTP 封装 ----
# HttpGetter.get(url, params, headers, opts): 2xx 返回解析后对象, 4xx/5xx 抛 HttpError。
# 这里统一封装成 {code:, json:}, 供业务案例用同一套写法, 不必区分成功返回与异常。
def get(path, params = {})
  json = HttpGetter.get("#{BASE}#{path}", params, {}, { timeout: 120, max_retries: 0 })
  { code: 200, json: json }
rescue HttpGetter::HttpError => e
  m = /\AHTTP (\d+):\s*(.*)\z/m.match(e.message)
  code = m ? m[1].to_i : 0
  body = m ? m[2] : e.message
  { code: code, json: (JSON.parse(body) rescue body) }
rescue HttpGetter::Error => e
  { code: 0, json: { 'error' => e.message } }
end

# wait_ready: 轮询 TCP 端口直到服务就绪
# 注: socket.close 在 Ruby 中返回 nil, 不可用 'xxx and return' 写法 (会死循环)。
def wait_ready(host, port, timeout = 30)
  start = Time.now
  loop do
    TCPSocket.new(host, port).close
    return
  rescue
    raise "GeoAPI 服务在 #{timeout}s 内未就绪" if Time.now - start > timeout
    sleep 0.3
  end
end

def banner(title); puts "\n===== #{title} =====" end

def show(result)
  puts JSON.pretty_generate(result)
end

# ---- 启动后台 Puma 服务 (抑制启动日志) ----
$stderr_saved = $stderr.dup
Thread.new do
  $stderr.reopen(File::NULL) rescue nil
  Rack::Handler::Puma.run(GeoAPI.app, Host: HOST, Port: PORT, Silent: true, Threads: '1:4')
end
begin
  wait_ready(HOST, PORT)
rescue => e
  abort e.message
end
$stderr.reopen($stderr_saved)
puts "geoquery-example  v#{NetworkInfraUtility::VERSION}"
puts "GeoAPI 服务已启动: #{BASE}  数据目录: #{DATA_DIR}"
puts "Part B 查询编排连接: #{GEOAPI_BASE_FOR_QUERY}"

# ============================================================
# 执行入口 —— 按 Part A → Part B 顺序运行
# ============================================================
t0 = Time.now

# ---- Part A: 服务接口 ----
case_health
case_asn
case_city_by_id
if ENV['FULL'] == '1' || ENV['SLOW'] == '1'
  case_city_by_addr
else
  banner '(四) City  GET /geo/city?addr='
  puts '  (跳过, 用 FULL=1 或 SLOW=1 启用; city-IPv4 加载约23s)'
end
case_country_by_id
case_country_by_addr
case_unknown_path

# ---- Part B: 查询编排 ----
case_local_client(GEOAPI_BASE_FOR_QUERY)
case_gen_get
case_ngeo_get(GEOAPI_BASE_FOR_QUERY, QUERY_CACHE_DIR)
case_state_machine(GEOAPI_BASE_FOR_QUERY, QUERY_CACHE_DIR)

puts "\n===== 完成, 耗时 #{(Time.now - t0).round(1)}s ====="
exit!(0)   # 强制退出后台 Puma 线程, 避免进程挂起
