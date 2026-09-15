# coding: utf-8
# frozen_string_literal: true

require "json"
require_relative "normalize"   # GeoQuery.valid_ip? (服务端可单独加载本文件)

module GeoQuery
  # ------------------------------------------------------------------
  # GEO_CACHE 外带缓存目录 — geocacheXXXXXXXX.json 文件集的读取/写入/合并
  # ------------------------------------------------------------------
  # 文件命名: geocacheYYYYMMDD.json (XXXXXXXX 为 8 位日期时间标签)
  # 文件格式: { "ip" => { 统一 schema 结果, "ts" => 写入时间戳 } }
  #           (与 ngeo-cache.json 同构, 便于 -m 合并与跨机拷贝)
  #
  # 三个角色:
  #   1. 查询源 — lookup(ip) 遍历目录内全部缓存文件, 返回该 IP 的定位信息
  #      (目录内文件增删改自动感知, 服务端/客户端均无需重启)
  #   2. 产出   — put_batch(results) 把查询结果合并写入当天的 geocacheYYYYMMDD.json
  #      (同一天多次产出自动归并到同一文件, 同 IP 以新结果覆盖)
  #   3. 整理   — merge! 把目录内全部缓存文件合并为一个新的 geocacheYYYYMMDD.json
  #      (同 IP 冲突取 ts 最新; 合并生成时间即新文件的时间标签)
  #
  # 命令行入口: bin/ngeo-get (-a 指定目录 / -c 产出 / -nc 不产出 / -m 合并)
  # 服务端入口: bin/geo-api -a (本地库查不到时兜底, 详见 service/geodb/api.rb)
  class GeoCache
    # 缓存文件名: geocache + 8 位日期标签 + .json
    FILE_RE = /\Ageocache\d{8}\.json\z/.freeze
    # -p 顺位参数的合法源
    ORDER_SOURCES = %w[cache local internet].freeze
    # 可缓存状态 (与 GeoQuery::CACHEABLE_STATES 保持一致;
    # 独立定义以支持 geodb 服务端单独加载本文件, 不依赖 geoquery.rb)
    CACHEABLE_STATES = %w[local merged online empty cache].freeze
    # 归属字段白名单 (产出/转换时提取)
    FIELDS = %w[country province city isp asn asn_org network usage].freeze

    attr_reader :dir

    # 默认产出目录: ENV["GEO_CACHE_DIR"] || 当前目录
    def self.default_dir
      d = ENV["GEO_CACHE_DIR"].to_s
      d.empty? ? Dir.pwd : File.expand_path(d)
    end

    # 解析 -p 顺位参数 ("cache,local,internet" / "local internet cache" 等):
    # 返回源名数组; 非法 (含未知源 / 重复 / 为空) 返回 nil
    def self.parse_order(str)
      parts = str.to_s.split(/[,\s]+/).map(&:strip).reject(&:empty?)
      return nil if parts.empty?
      return nil unless parts.all? { |p| ORDER_SOURCES.include?(p) }
      return nil unless parts.uniq.size == parts.size
      parts
    end

    # 统一 schema → geo-api 接口的 GeoLite2 风格响应 (服务端缓存命中时用)。
    # 对应字段缺失时返回 nil (视作该接口无数据, 由调用方继续下一数据源)。
    def self.to_geolite(kind, hit)
      case kind
      when :asn
        return nil if hit["asn"].to_s.empty?
        {
          "network" => hit["network"].to_s,
          "autonomous_system_number" => hit["asn"].to_s,
          "autonomous_system_organization" => hit["asn_org"].to_s,
          "cached" => true,
        }
      when :city
        return nil if hit["province"].to_s.empty? && hit["city"].to_s.empty?
        g = {}
        g["country_name"] = hit["country"].to_s unless hit["country"].to_s.empty?
        g["subdivision_1_name"] = hit["province"].to_s unless hit["province"].to_s.empty?
        g["city_namezh"] = hit["city"].to_s unless hit["city"].to_s.empty?
        { "network" => hit["network"].to_s, "geoname" => g, "cached" => true }
      when :country
        return nil if hit["country"].to_s.empty?
        {
          "network" => hit["network"].to_s,
          "geoname" => { "country_name" => hit["country"].to_s },
          "cached" => true,
        }
      end
    end

    def initialize(dir)
      @dir = File.expand_path(dir.to_s)
      @files = {}   # path => { mtime: Float, data: Hash }
      @lock = Mutex.new
    end

    # 查询: 遍历目录内全部缓存文件, 返回该 IP 的记录 (附加 "cached" => true),
    # 未命中返回 nil。多文件命中时取 ts 最新。
    def lookup(ip)
      @lock.synchronize do
        refresh!
        best = nil
        @files.each_value do |f|
          hit = f[:data][ip]
          next unless hit.is_a?(Hash)
          next if best && hit["ts"].to_i <= best["ts"].to_i
          best = hit
        end
        best ? best.merge("cached" => true) : nil
      end
    end

    # 产出: 把查询结果 (统一 schema Hash 数组, 或 {ip=>result} Hash)
    # 合并写入当天缓存文件 geocacheYYYYMMDD.json。
    # 仅落盘可缓存状态 (local/merged/online/empty/cache); 同 IP 以本次结果覆盖。
    # 返回 { "file" => 路径, "entries" => 写入条数 }; 无可写内容返回 nil。
    def put_batch(results)
      entries = normalize_entries(results)
      return nil if entries.empty?
      @lock.synchronize do
        path = File.join(@dir, "geocache#{Time.now.strftime('%Y%m%d')}.json")
        data = read_file(path)
        entries.each { |ip, r| data[ip] = r.merge("ts" => Time.now.to_i) }
        write_file(path, data)
        { "file" => path, "entries" => entries.size }
      end
    end

    # 整理: 合并目录内全部缓存文件为一个新的 geocacheYYYYMMDD.json
    # (合并生成时间即时间标签; 同 IP 冲突取 ts 最新)。
    # 返回 { "files" => 合并文件数, "entries" => 条目数, "output" => 输出路径 }。
    def merge!
      @lock.synchronize do
        refresh!
        source_count = @files.size   # 写入前统计 (输出文件可能覆盖同名源文件)
        merged = {}
        @files.each_value do |f|
          f[:data].each do |ip, r|
            next unless r.is_a?(Hash)
            cur = merged[ip]
            merged[ip] = r if cur.nil? || r["ts"].to_i >= cur["ts"].to_i
          end
        end
        path = File.join(@dir, "geocache#{Time.now.strftime('%Y%m%d')}.json")
        write_file(path, merged)
        { "files" => source_count, "entries" => merged.size, "output" => path }
      end
    end

    # 目录统计: { "dir", "files", "entries", "states" }
    def stats
      @lock.synchronize do
        refresh!
        states = Hash.new(0)
        @files.each_value do |f|
          f[:data].each_value { |r| states[r["state"]] += 1 if r.is_a?(Hash) }
        end
        {
          "dir" => @dir,
          "files" => @files.size,
          "entries" => @files.values.sum { |f| f[:data].size },
          "states" => states,
        }
      end
    end

    private

    # 目录内全部合法缓存文件 (按文件名排序 = 按日期标签排序)
    def cache_files
      return [] unless File.directory?(@dir)
      Dir.glob(File.join(@dir, "geocache*.json"))
         .select { |p| FILE_RE =~ File.basename(p) }
         .sort
    end

    # 感知目录变化: 新增/修改的文件重载, 已删除的移除
    def refresh!
      current = {}
      cache_files.each do |path|
        mtime = File.mtime(path).to_f
        prev = @files[path]
        current[path] = if prev && prev[:mtime] == mtime
                          prev
                        else
                          { mtime: mtime, data: read_file(path) }
                        end
      end
      @files.replace(current)
    end

    def read_file(path)
      return {} unless File.exist?(path)
      raw = File.binread(path)
      raw = raw.delete_prefix("\xEF\xBB\xBF".b)   # 容错 UTF-8 BOM (Windows 记事本)
      data = JSON.parse(raw)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end

    def write_file(path, data)
      require "fileutils"
      FileUtils.mkdir_p(@dir)
      tmp = "#{path}.tmp#{Process.pid}"
      File.binwrite(tmp, JSON.pretty_generate(data))
      File.rename(tmp, path)
      @files[path] = { mtime: File.mtime(path).to_f, data: data }
      path
    end

    # 产出内容规整: Hash 数组 (取 ip 字段) 或 {ip=>result} Hash
    # 仅保留 ip 合法且状态可缓存的条目
    def normalize_entries(results)
      entries = {}
      if results.is_a?(Hash)
        results.each do |ip, r|
          next unless r.is_a?(Hash) && cacheable?(r) && GeoQuery.valid_ip?(ip)
          entries[ip.to_s] = pick_fields(r)
        end
      elsif results.is_a?(Array)
        results.each do |r|
          next unless r.is_a?(Hash)
          ip = r["ip"].to_s
          next unless cacheable?(r) && GeoQuery.valid_ip?(ip)
          entries[ip] = pick_fields(r)
        end
      end
      entries
    end

    def cacheable?(result)
      CACHEABLE_STATES.include?(result["state"].to_s)
    end

    # 提取归属字段 (剔除 state/message/source/sources/ts/cached 等元数据)
    def pick_fields(r)
      r.select { |k, _| FIELDS.include?(k) }
    end
  end
end
