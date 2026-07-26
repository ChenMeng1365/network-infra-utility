#coding:utf-8
# query.rb — 调用 geo-api 服务查询单个 IP 的归属信息
# ============================================================
# 默认一次输入 IP, 并行查询 country / city / asn 三类信息并汇总输出。
#
# 用法:
#   ruby query.rb                       # 查默认 IP 1.181.240.251 (三接口齐查)
#   ruby query.rb 8.8.8.8               # 查指定 IP (三接口齐查)
#   ruby query.rb 1.181.240.251 --city  # 仅走 city 接口
#   ruby query.rb 1.181.240.251 --asn   # 仅走 asn 接口
#   ruby query.rb 1.181.240.251 --country  # 仅走 country 接口
#
# 默认连 http://127.0.0.1:9292 (geo-api 默认监听)。
# 服务未运行时给出明确提示与启动命令。
# ============================================================
require 'net/http'
require 'json'
require 'uri'

HOST = '127.0.0.1'
PORT = 9292
BASE = "http://#{HOST}:#{PORT}"

# 解析参数: 第一个非 -- 参数当 IP;
# --country/--city/--asn 单选某接口, 默认 (无 flag) 三接口齐查
ip   = ARGV.find { |a| !a.start_with?('-') } || '1.181.240.251'
only = ARGV.include?('--country') ? :country
     : ARGV.include?('--city')    ? :city
     : ARGV.include?('--asn')     ? :asn
     : nil   # nil = 三接口齐查 (默认)

# 发起一次 GET, 返回 {code:, body:}
def fetch(base, path, params)
  uri = URI("#{base}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.get_response(uri)
  { code: res.code.to_i, body: (JSON.parse(res.body) rescue res.body) }
rescue Errno::ECONNREFUSED
  abort "✗ 无法连接 #{base} —— geo-api 服务未启动。\n  启动命令: geo-api -d E:/workspace/momentum/twinklite/data/geodb"
rescue => e
  abort "✗ 请求失败: #{e.class}: #{e.message}"
end

scope = only ? "仅 #{only}" : 'country / city / asn 三接口齐查'
puts "查询 IP: #{ip}    范围: #{scope}    服务: #{BASE}"
puts '-' * 60

# 默认 (only 为 nil) 三接口齐查; 指定 flag 时只查该接口
do_country = only.nil? || only == :country
do_city    = only.nil? || only == :city
do_asn     = only.nil? || only == :asn

# 统一收集每个接口的命中记录, 最后统一输出。
# 命中才显示, 未命中 (404/无结果) 不逐条刷屏。
hits = []

if do_country
  r = fetch(BASE, '/geo/country', addr: ip)
  if r[:code] == 200
    d = r[:body]
    g = d['geoname']; rc = d['registered_country']
    country = (g && g['country_name']) || (rc && rc['country_name']) || '未知'
    hits << "[国家] #{country} (#{(g && g['country_iso_code']) || (rc && rc['country_iso_code'])})  网段 #{d['network']}"
  end
end

if do_city
  r = fetch(BASE, '/geo/city', addr: ip)
  if r[:code] == 200
    d = r[:body]
    g = d['geoname']
    city = (g && (g['city_namezh'] || g['city_name'])) || '未知'
    coord = g && g['latitude'] && g['longitude'] ? "#{g['latitude']}, #{g['longitude']}" : '无'
    hits << "[城市] #{city}    坐标 #{coord}    网段 #{d['network']}"
  end
end

if do_asn
  r = fetch(BASE, '/geo/asn', addr: ip)
  if r[:code] == 200
    d = r[:body]
    hits << "[ASN]  AS#{d['autonomous_system_number']} #{d['autonomous_system_organization']}    网段 #{d['network']}"
  end
end

# 统一输出: 有命中 → 逐条列出; 全部未命中 → 一句话提示
if hits.empty?
  puts "#{ip} 未查到归属信息 (该 IP 不在已知数据范围内, 如回环/保留地址)"
else
  puts "#{ip} 的归属信息:"
  hits.each { |h| puts "  #{h}" }
end
