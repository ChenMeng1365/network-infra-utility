#coding:utf-8
['cc','CasetDown/casetdown','network','oj'].each{|mod|require mod}
CC.use 'file','enum','shell-tools'

# USAGE>
# GeoDB.load_asn("GeoLite2-ASN-CSV_*/*.csv")
# GeoDB.load_city("GeoLite2-City-CSV_*/*.csv")
# GeoDB.load_country("GeoLite2-Country-CSV_*/*.csv")
#
# GeoDB.output("geodb/")
# GeoDB.output("geodb/", format: :txt)
# GeoDB.output("geodb/", format: :csv)
# GeoDB.output("geodb/", output_path: "output/")
# GeoDB.output("geodb/", format: [:csv, :txt], output_path: "output/")

module GeoDB
    module_function

    # 加载 GeoLite2 ASN 数据（CSV → JSON）
    # -----------------------------------------------------------
    # 读取 GeoLite2-ASN-CSV_* 目录下的 CSV，将每条网段展开为
    # [start_num, end_num] => record 的 Hash，序列化为 asn.json
    # 供 geo-api 的 /geo/asn 接口做二分范围查找。
    #
    # 参数:
    #   dir_path  — ASN CSV 的 glob 模式，默认当前目录查找
    #   out_path  — JSON 输出目录，默认 geodb/
    #
    # 返回: asn Hash (range => record)
    def load_asn dir_path="GeoLite2-ASN-CSV_*/*.csv", out_path=nil
        out_path = "geodb/" unless out_path
        Dir.mkdir(out_path) unless File.exist?(out_path)
        asn = {}
        Dir[dir_path].each do|path|
            table = CSV.parse File.read(path)
            head = table.first
            bar = ProgressBar.new(table.length-1, title: "#{path.split("/").last}", theme: :classic, color: true)
            table[1..-1].mapping(head).each do|record|
                range = IP.range(record['network']).map{|ip|ip.number}
                asn[range] = record
                bar.update
            end
            bar.finish(message: "✨ 处理了 #{table.length-1} 条记录.")
        end
        File.write "#{out_path}asn.json", JSON.pretty_generate(asn)
        return asn
    end

    # 加载 GeoLite2 City 数据（CSV → JSON）
    # -----------------------------------------------------------
    # 分两阶段处理 City 数据:
    #   1. City-Locations-zh-CN → geo-city.json (geoname_id => 城市地理信息)
    #   2. City-Blocks-IPv4/IPv6 → city-IPv4.json / city-IPv6.json
    #      (网段 [start, end] => record, 含经纬度/精度半径等)
    #
    # 参数:
    #   dir_path  — City CSV 的 glob 模式，默认当前目录查找
    #   out_path  — JSON 输出目录，默认 geodb/
    #
    # 返回: [city, geo] 两个 Hash
    def load_city dir_path="GeoLite2-City-CSV_*/*.csv", out_path=nil
        out_path = "geodb/" unless out_path
        Dir.mkdir(out_path) unless File.exist?(out_path)
        city = {};geo = {}
        Dir[dir_path].each do|path|
            next unless path.include?("City-Locations-zh-CN")
            table = CSV.parse File.read(path)
            bar = ProgressBar.new(table.length-1, title: "#{path.split("/").last}", theme: :classic, color: true)
            table[1..-1].mapping(table.first).each do|record|
                geo[record['geoname_id']] = record
                bar.update
            end
            bar.finish(message: "✨ 处理了 #{table.length-1} 条记录.")
        end
        File.write "#{out_path}geo-city.json", JSON.pretty_generate(geo)

        Dir[dir_path].each do|path|
            next unless path.include?("City-Blocks")
            postfix = 'IPv4' if path.include?('IPv4')
            postfix = 'IPv6' if path.include?('IPv6')
            table = CSV.parse File.read(path)
            bar = ProgressBar.new(table.length-1, title: "#{path.split("/").last}", theme: :classic, color: true)
            table[1..-1].mapping(table.first).each do|record|
                range = IP.range(record['network']).map{|ip|ip.number}
                city[range] = record
                bar.update
            end
            bar.finish(message: "✨ 处理了 #{table.length-1} 条记录.")
            File.write "#{out_path}city-#{postfix}.json", city.to_json # JSON.pretty_generate(city)
        end
        return city,geo
    end

    # 加载 GeoLite2 Country 数据（CSV → JSON）
    # -----------------------------------------------------------
    # 分两阶段处理 Country 数据:
    #   1. Country-Locations-zh-CN → geo-country.json (geoname_id => 国家信息)
    #   2. Country-Blocks-IPv4/IPv6 → country-IPv4.json / country-IPv6.json
    #      (网段 [start, end] => record)
    #
    # 参数:
    #   dir_path  — Country CSV 的 glob 模式，默认当前目录查找
    #   out_path  — JSON 输出目录，默认 geodb/
    #
    # 返回: [country, geo] 两个 Hash
    def load_country dir_path="GeoLite2-Country-CSV_*/*.csv", out_path=nil
        out_path = "geodb/" unless out_path
        Dir.mkdir(out_path) unless File.exist?(out_path)
        country = {};geo = {}
        Dir[dir_path].each do|path|
            next unless path.include?("Country-Locations-zh-CN")
            table = CSV.parse File.read(path)
            bar = ProgressBar.new(table.length-1, title: "#{path.split("/").last}", theme: :classic, color: true)
            table[1..-1].mapping(table.first).each do|record|
                geo[record['geoname_id']] = record
                bar.update
            end
            bar.finish(message: "✨ 处理了 #{table.length-1} 条记录.")
        end
        File.write "#{out_path}geo-country.json", JSON.pretty_generate(geo)

        Dir[dir_path].each do|path|
            next unless path.include?("Country-Blocks")
            postfix = 'IPv4' if path.include?('IPv4')
            postfix = 'IPv6' if path.include?('IPv6')
            table = CSV.parse File.read(path)
            bar = ProgressBar.new(table.length-1, title: "#{path.split("/").last}", theme: :classic, color: true)
            table[1..-1].mapping(table.first).each do|record|
                range = IP.range(record['network']).map{|ip|ip.number}
                country[range] = record
                bar.update
            end
            bar.finish(message: "✨ 处理了 #{table.length-1} 条记录.")
            File.write "#{out_path}country-#{postfix}.json", JSON.pretty_generate(country)
        end
        return country,geo
    end

    # ============================================================
    # output — 将已导入的 JSON 拼接成一张大表并输出文件
    # ------------------------------------------------------------
    # 对 data_path 下的 city-IPv4/IPv6、country-IPv4/IPv6 逐条关联
    # asn 和 geo-city / geo-country，以 network 为联合主键合并，
    # 最终按 IPv4 / IPv6 分别输出为大表文件。
    #
    # 参数:
    #   data_path   — 数据目录路径（末尾可带可不带分隔符）
    #   format      — 输出格式，:csv / :txt / [:csv, :txt]（默认两者都输出）
    #   output_path — 输出目录路径，默认 geodb/（与数据目录相同）
    #
    # CSV: 符合 RFC 4180，对含逗号/引号/换行的字段自动加引号转义
    # TXT: 以 \n 换行、\t 分隔单元格，空值留空
    #
    # 用法:
    #   GeoDB.output("geodb/")
    #   GeoDB.output("geodb/", format: :csv)
    #   GeoDB.output("geodb/", output_path: "output/")
    # ============================================================

    # output 表头
    OUTPUT_HEADERS = %w[
        network start_num end_num
        asn_number asn_organization
        city_geoname_id city_latitude city_longitude city_accuracy_radius
        continent_code continent_name country_iso_code country_name
        subdivision_1_name subdivision_2_name city_name time_zone
        registered_country_geoname_id registered_country_name
        is_anonymous_proxy is_satellite_provider is_anycast
    ].freeze

    # IPv4 数值上界（不含），用于区分 v4 / v6
    IPv4_MAX = 4294967296  # 2**32

    def output data_path="geodb/", format: [:csv, :txt], output_path: nil
        data_path = data_path.chomp(File::SEPARATOR) + File::SEPARATOR
        # 输出目录: 指定了就用指定的，没指定则与数据目录相同
        if output_path
            out_dir = output_path.chomp(File::SEPARATOR) + File::SEPARATOR
            Dir.mkdir(out_dir) unless File.exist?(out_dir)
        else
            out_dir = data_path
        end
        formats = format.is_a?(Array) ? format : [format]

        # ---- 1. 加载 asn，排序后用于二分查找 ----
        puts "[output] 加载 asn.json ..."
        asn_arr = []
        _stream_entries("#{data_path}asn.json") do |key, record|
            start_num, end_num = key.scan(/\d+/).map(&:to_i)
            asn_arr << [start_num, end_num, record]
        end
        asn_arr.sort_by! { |s, _, _| s }
        puts "[output] asn 排序完成，共 #{asn_arr.size} 条"

        # ---- 2. 加载 geo-city / geo-country（整表载入，文件不大）----
        puts "[output] 加载 geo-city.json ..."
        geo_city = Oj.load_file("#{data_path}geo-city.json")
        puts "[output] geo-city: #{geo_city.size} 条"
        puts "[output] 加载 geo-country.json ..."
        geo_country = Oj.load_file("#{data_path}geo-country.json")
        puts "[output] geo-country: #{geo_country.size} 条"

        # ---- 3. 分别处理 IPv4 / IPv6 ----
        { v4: 'IPv4', v6: 'IPv6' }.each do |tag, label|
            puts "\n[output] === 处理 #{label} ==="

            # 收集所有 city / country 记录到内存 Hash
            # key=[start_num, end_num] => { city: record, country: record }
            # city 和 country 的 geoname_id 同名但语义不同（城市级 vs 国家级），
            # 不能直接 merge!，需分别存放各自关联各自的 geo 表。
            records = {}

            ["city-#{label}", "country-#{label}"].each do |file|
                source = file.start_with?('city') ? :city : :country
                path = "#{data_path}#{file}.json"
                next unless File.exist?(path)
                count = 0
                _stream_entries(path) do |key, rec|
                    start_num, end_num = key.scan(/\d+/).map(&:to_i)
                    # v6 文件可能混入 v4 数据（load 阶段历史问题），按 start_num 区分
                    is_v6_data = start_num >= IPv4_MAX
                    next if tag == :v4 && is_v6_data
                    next if tag == :v6 && !is_v6_data

                    k = [start_num, end_num]
                    records[k] ||= {}
                    records[k][source] = rec
                    count += 1
                end
                puts "[output]   #{file}.json → #{count} 条"
            end

            next if records.empty?
            puts "[output]   合并后 #{records.size} 个唯一网段"

            # 排序
            sorted_keys = records.keys.sort_by { |s, _| s }

            # 输出
            formats.each do |fmt|
                ext = fmt == :csv ? 'csv' : 'txt'
                out_file = "#{out_dir}output-#{label.downcase}.#{ext}"
                total = sorted_keys.size
                puts "[output]   写入 #{out_file} (#{total} 行, #{fmt}) ..."

                if fmt == :csv
                    _write_csv(out_file, sorted_keys, records, asn_arr, geo_city, geo_country)
                else
                    _write_txt(out_file, sorted_keys, records, asn_arr, geo_city, geo_country)
                end
                puts "[output]   ✓ #{out_file} 完成"
            end
        end
    end

    # ---- output 内部方法 ----

    # Oj ScHandler 流式收集器：逐条回调 key-value
    class RangeCollector < Oj::ScHandler
        def initialize(&block)
            @block = block
            @depth = 0
        end
        def hash_start; @depth += 1; {}; end
        def hash_end;   @depth -= 1; end
        def array_start; []; end
        def array_end;   end
        def hash_set(hash, key, value)
            if @depth == 1
                @block.call(key, value)
            else
                hash[key] = value
            end
        end
        def array_append(array, value)
            array << value
        end
    end

    # 流式遍历 JSON 文件，每条 entry 回调 yield(key, record)
    def _stream_entries path
        return unless File.exist?(path)
        collector = RangeCollector.new { |k, v| yield k, v }
        File.open(path, 'r') { |f| Oj.sc_parse(collector, f) }
    end

    # 二分查找：在排序的 [[start, end, record], ...] 中找包含 num 的范围
    def _find_range arr, num
        return nil if arr.nil? || arr.empty?
        idx = arr.bsearch_index { |s, _, _| s > num }
        cand = idx.nil? ? arr.last : (idx > 0 ? arr[idx - 1] : nil)
        return nil unless cand
        s, e, r = cand
        (num >= s && num <= e) ? r : nil
    end

    # 为一条记录构建完整输出行
    # entry 是 { city: record_hash, country: record_hash } 结构（任一可缺）
    def _build_row start_num, end_num, entry, asn_arr, geo_city, geo_country
        city_rec    = entry[:city]
        country_rec = entry[:country]
        # network 优先从 city 取（有更丰富字段），回退到 country
        network = (city_rec || country_rec)['network']

        # ASN 关联（用 start_num 查）
        asn_rec = _find_range(asn_arr, start_num)

        # geo-city 关联（用 city 表的 geoname_id）
        city_gid = city_rec ? city_rec['geoname_id'] : nil
        city_geo = (city_gid && city_rec.key?('latitude')) ? geo_city[city_gid] : nil

        # geo-country 关联（用 country 表的 geoname_id）
        country_gid = country_rec ? country_rec['geoname_id'] : nil
        country_geo = country_gid ? geo_country[country_gid] : nil

        # 用于 continent / country 的统一取值（优先 city_geo，其次 country_geo）
        unified_geo = city_geo || country_geo

        # registered_country（city 和 country 表都有该字段，优先 city）
        reg_id = (city_rec || country_rec)['registered_country_geoname_id']
        reg_country_geo = reg_id ? geo_country[reg_id] : nil

        OUTPUT_HEADERS.map do |h|
            case h
            when 'network'                       then network
            when 'start_num'                     then start_num
            when 'end_num'                       then end_num
            when 'asn_number'                    then asn_rec ? asn_rec['autonomous_system_number'] : nil
            when 'asn_organization'              then asn_rec ? asn_rec['autonomous_system_organization'] : nil
            when 'city_geoname_id'               then city_gid
            when 'city_latitude'                 then city_rec ? city_rec['latitude'] : nil
            when 'city_longitude'                then city_rec ? city_rec['longitude'] : nil
            when 'city_accuracy_radius'          then city_rec ? city_rec['accuracy_radius'] : nil
            when 'continent_code'                then unified_geo ? unified_geo['continent_code'] : nil
            when 'continent_name'                then unified_geo ? unified_geo['continent_name'] : nil
            when 'country_iso_code'              then unified_geo ? unified_geo['country_iso_code'] : nil
            when 'country_name'                  then unified_geo ? unified_geo['country_name'] : nil
            when 'subdivision_1_name'            then city_geo ? city_geo['subdivision_1_name'] : nil
            when 'subdivision_2_name'            then city_geo ? city_geo['subdivision_2_name'] : nil
            when 'city_name'                     then city_geo ? city_geo['city_name'] : nil
            when 'time_zone'                     then city_geo ? city_geo['time_zone'] : nil
            when 'registered_country_geoname_id' then reg_id
            when 'registered_country_name'       then reg_country_geo ? reg_country_geo['country_name'] : nil
            when 'is_anonymous_proxy'            then (city_rec || country_rec)['is_anonymous_proxy']
            when 'is_satellite_provider'         then (city_rec || country_rec)['is_satellite_provider']
            when 'is_anycast'                    then (city_rec || country_rec)['is_anycast']
            end
        end
    end

    # 写 CSV 文件（自动对复杂内容加引号）
    def _write_csv out_file, sorted_keys, records, asn_arr, geo_city, geo_country
        CSV.open(out_file, 'w', encoding: 'utf-8') do |csv|
            csv << OUTPUT_HEADERS
            sorted_keys.each do |start_num, end_num|
                row = _build_row(start_num, end_num, records[[start_num, end_num]],
                                 asn_arr, geo_city, geo_country)
                csv << row
            end
        end
    end

    # 写 TXT 文件（\n 换行, \t 分隔）
    def _write_txt out_file, sorted_keys, records, asn_arr, geo_city, geo_country
        File.open(out_file, 'w:UTF-8') do |f|
            f.puts OUTPUT_HEADERS.join("\t")
            sorted_keys.each do |start_num, end_num|
                row = _build_row(start_num, end_num, records[[start_num, end_num]],
                                 asn_arr, geo_city, geo_country)
                f.puts row.map { |v| v.nil? ? '' : v.to_s }.join("\t")
            end
        end
    end
end
