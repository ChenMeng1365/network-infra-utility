#coding:utf-8
# GeoDB Roda API — IP 归属信息查询服务
#
# 作为 network-infra-utility 的命令行服务 (geo-api) 运行，
# 亦可作为 rackup 配置由 config.ru 启动。
#
# 数据文件目录通过环境变量 GEODB_DATA_DIR 指定，默认 ./geodb/
# 用 -d/--data-dir 参数 (命令行) 或设置该环境变量可指向任意位置。
['cc','CasetDown/casetdown','network','roda'].each{|mod| require mod}

module GeoDB
  module_function

  # 数据文件所在目录。
  # 优先级: ENV['GEODB_DATA_DIR'] > ./geodb/
  # 返回绝对路径并以分隔符结尾，便于直接拼接文件名。
  # 与 geodb.rb 的 $prefix 含义一致，但此处只读不写。
  def data_dir
    d = ENV['GEODB_DATA_DIR'].to_s
    d = 'geodb' if d.empty?
    File.expand_path(d) + File::SEPARATOR
  end

  # 缓存: name => 已加载并处理好的结构
  @store = {}
  # asn 反向索引: autonomous_system_number => [record, ...]
  @asn_index = {}
  @lock = Mutex.new

  # ---- 加载 ---------------------------------------------------------------

  # 加载范围型 JSON (asn / city-IPv4 / city-IPv6 / country-IPv4 / country-IPv6)
  # 返回按 start 升序的数组: [[start_num, end_num, record], ...]
  # JSON 的键形如 "[16777217, 16777471]" (Ruby 数组键序列化后的字符串),
  # 用 JSON.parse 还原为 [start, end] 两个整数.
  def ranges(name)
    @lock.synchronize do
      return @store[name] if @store.key?(name)
      path = "#{data_dir}#{name}.json"
      unless File.exist?(path)
        @store[name] = nil
        return nil
      end
      raw = JSON.parse(File.binread(path))
      arr = raw.map do |key, record|
        start_num, end_num = JSON.parse(key)
        [start_num.to_i, end_num.to_i, record]
      end
      arr.sort_by! { |s, _, _| s }
      @store[name] = arr
      # 为 asn 建立反向索引, num 查询 O(1)
      if name == 'asn'
        @asn_index.clear
        arr.each do |_, _, r|
          asn = r['autonomous_system_number']
          (@asn_index[asn] ||= []) << r
        end
      end
      arr
    end
  end

  # 加载地理位置型 JSON (geo-city / geo-country)
  # 返回扁平 Hash: { geoname_id_string => record }
  def geo(name)
    @lock.synchronize do
      return @store[name] if @store.key?(name)
      path = "#{data_dir}#{name}.json"
      unless File.exist?(path)
        @store[name] = nil
        return nil
      end
      @store[name] = JSON.parse(File.binread(path))
    end
  end

  # ---- IP 解析 ------------------------------------------------------------

  # 把 IP 地址转为数字. 合法返回 Integer, 非法返回 nil.
  # 自有库: IP.v4("1.2.3.4").number / IP.v6("::1").number
  # 含冒号按 IPv6 处理, 否则按 IPv4 处理.
  # 说明: 自有库对非法地址通常不抛异常而是返回非 Integer(nil/空串),
  # 仅部分 IPv6 非法输入会抛 IPAddr::InvalidAddressError, 故双重兜底.
  def ip_number(addr)
    s = addr.to_s.strip
    return nil if s.empty?
    begin
      n = s.include?(':') ? IP.v6(s).number : IP.v4(s).number
      n.is_a?(Integer) ? n : nil
    rescue
      nil
    end
  end

  # 判断地址族: 含冒号为 IPv6, 否则 IPv4
  def ipv6?(addr)
    addr.to_s.include?(':')
  end

  # ---- 范围二分查找 -------------------------------------------------------

  # 在 ranges(name) 中查找包含 number 的范围, 返回对应 record, 未命中返回 nil.
  # 范围互不重叠且按 start 升序, 用 bsearch_index 找最后一个 start<=number
  # 的元素, 再校验 number<=end.
  def find_range(name, number)
    arr = ranges(name)
    return nil unless arr && !arr.empty?
    idx = arr.bsearch_index { |s, _, _| s > number }
    cand = idx.nil? ? arr.last : (idx > 0 ? arr[idx - 1] : nil)
    return nil unless cand
    s, e, r = cand
    (number >= s && number <= e) ? r : nil
  end

  # ---- ASN 接口 (1) -------------------------------------------------------

  # /geo/asn?num=XXX  查出该 AS 的所有地址段
  def asn_by_num(num)
    ranges('asn') # 触发加载并建立反向索引
    @asn_index[num.to_s] || []
  end

  # /geo/asn?addr=X.X.X.X  按 IP 查所属 AS
  # 返回: :invalid(IP不合法) / nil(无结果) / record
  def asn_by_addr(addr)
    num = ip_number(addr)
    return :invalid unless num
    find_range('asn', num)
  end

  # ---- City 接口 (2)(3) ---------------------------------------------------

  # /geo/city?id=XXX
  # 返回: :invalid(id不合法) / nil(无结果) / record
  def city_by_id(id)
    return :invalid unless id.to_s.match?(/\A\d+\z/)
    g = geo('geo-city')
    g ? g[id.to_s] : nil
  end

  # /geo/city?addr=X.X.X.X  先查 city-IPv4/city-IPv6, 再关联 geo-city
  # 返回: :invalid / nil / enriched_record
  def city_by_addr(addr)
    num = ip_number(addr)
    return :invalid unless num
    name = ipv6?(addr) ? 'city-IPv6' : 'city-IPv4'
    r = find_range(name, num)
    return nil unless r
    enrich(r, 'geo-city')
  end

  # ---- Country 接口 (4)(5) ------------------------------------------------

  # /geo/country?id=XXX
  def country_by_id(id)
    return :invalid unless id.to_s.match?(/\A\d+\z/)
    g = geo('geo-country')
    g ? g[id.to_s] : nil
  end

  # /geo/country?addr=X.X.X.X  先查 country-IPv4/country-IPv6, 再关联 geo-country
  def country_by_addr(addr)
    num = ip_number(addr)
    return :invalid unless num
    name = ipv6?(addr) ? 'country-IPv6' : 'country-IPv4'
    r = find_range(name, num)
    return nil unless r
    enrich(r, 'geo-country')
  end

  # ---- 关联聚合 -----------------------------------------------------------

  # 把范围型 record 与地理位置详情聚合:
  # 保留 record 原字段, 并按 geoname_id / registered_country_geoname_id /
  # represented_country_geoname_id 三个字段分别关联 geo 表, 输出为
  # geoname / registered_country / represented_country 三个嵌套对象.
  def enrich(record, geo_name)
    g = geo(geo_name)
    result = {}
    record.each { |k, v| result[k] = v }
    {
      'geoname_id'                    => 'geoname',
      'registered_country_geoname_id' => 'registered_country',
      'represented_country_geoname_id'=> 'represented_country'
    }.each do |id_key, out_key|
      id = record[id_key]
      result[out_key] = (id && g) ? g[id] : nil
    end
    result
  end

  # 预热: 启动时后台加载指定文件, 避免首次查询卡顿. 不调用则惰性加载.
  def preload(*names)
    names.each { |n| Thread.new { ranges(n) rescue geo(n) rescue nil } }
  end
end


class GeoAPI < Roda
  plugin :json   # 返回 Hash/Array 自动转 JSON

  IDS = %w[geoname_id registered_country_geoname_id represented_country_geoname_id].freeze

  route do |r|
    r.root do
      {
        service: 'GeoDB API',
        data_dir: GeoDB.data_dir,
        endpoints: {
          'asn'     => '/geo/asn?num=XXX | /geo/asn?addr=X.X.X.X',
          'city'    => '/geo/city?id=XXX | /geo/city?addr=X.X.X.X',
          'country' => '/geo/country?id=XXX | /geo/country?addr=X.X.X.X'
        }
      }
    end

    r.on 'geo' do
      r.on 'asn' do
        if r.params.key?('num')
          res = GeoDB.asn_by_num(r.params['num'])
          { asn: r.params['num'], count: res.length, results: res }
        elsif r.params.key?('addr')
          case (res = GeoDB.asn_by_addr(r.params['addr']))
          when :invalid then response.status = 400; { error: 'IP不合法' }
          when nil      then response.status = 404; { error: '无结果' }
          else res
          end
        else
          response.status = 400
          { error: '缺少参数 num 或 addr' }
        end
      end

      r.on 'city' do
        if r.params.key?('id')
          case (res = GeoDB.city_by_id(r.params['id']))
          when :invalid then response.status = 400; { error: 'id不合法' }
          when nil      then response.status = 404; { error: '无结果' }
          else res
          end
        elsif r.params.key?('addr')
          case (res = GeoDB.city_by_addr(r.params['addr']))
          when :invalid then response.status = 400; { error: 'IP不合法' }
          when nil      then response.status = 404; { error: '无结果' }
          else res
          end
        else
          response.status = 400
          { error: '缺少参数 id 或 addr' }
        end
      end

      r.on 'country' do
        if r.params.key?('id')
          case (res = GeoDB.country_by_id(r.params['id']))
          when :invalid then response.status = 400; { error: 'id不合法' }
          when nil      then response.status = 404; { error: '无结果' }
          else res
          end
        elsif r.params.key?('addr')
          case (res = GeoDB.country_by_addr(r.params['addr']))
          when :invalid then response.status = 400; { error: 'IP不合法' }
          when nil      then response.status = 404; { error: '无结果' }
          else res
          end
        else
          response.status = 400
          { error: '缺少参数 id 或 addr' }
        end
      end
    end

    response.status = 404
    { error: 'not found' }
  end
end
