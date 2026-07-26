#coding:utf-8
['cc','CasetDown/casetdown','network'].each{|mod|require mod}
CC.use 'file','enum','shell-tools'

# USAGE>
# GeoDB.load_asn("GeoLite2-ASN-CSV_*/*.csv")
# GeoDB.load_city("GeoLite2-City-CSV_*/*.csv")
# GeoDB.load_country("GeoLite2-Country-CSV_*/*.csv")

module GeoDB
    module_function

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
end
