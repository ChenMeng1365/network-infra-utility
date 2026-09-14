# coding: utf-8
# frozen_string_literal: true

require "json"

module GeoQuery
  # ------------------------------------------------------------------
  # JSON 文件缓存 — 移植自 ip_geo_lookup.py 的缓存设计
  # ------------------------------------------------------------------
  # 结构: { "ip" => { result..., "ts" => 1716000000 } }
  # 线程安全 (Mutex); 不可达 (unreachable) 类结果不写入缓存。
  class Cache
    attr_reader :path

    # 默认缓存根目录: ENV["NGEO_CACHE_DIR"] || ~/.network-infra-utility/
    def self.default_dir
      dir = ENV["NGEO_CACHE_DIR"].to_s
      dir.empty? ? File.join(Dir.home, ".network-infra-utility") : File.expand_path(dir)
    end

    def initialize(path)
      @path = path
      @lock = Mutex.new
      @data = load
    end

    # 命中返回结果 Hash (附加 "cached" => true), 未命中返回 nil
    def get(ip)
      @lock.synchronize do
        hit = @data[ip]
        hit ? hit.merge("cached" => true) : nil
      end
    end

    # 写入一条 (网络类不可达状态不落盘, 下次重查)
    def put(ip, result)
      return if result["state"] == "unreachable"
      @lock.synchronize do
        @data[ip] = result.merge("ts" => Time.now.to_i)
      end
    end

    def save
      @lock.synchronize do
        dir = File.dirname(@path)
        require "fileutils"
        FileUtils.mkdir_p(dir)
        File.binwrite(@path, JSON.pretty_generate(@data))
      end
      @path
    end

    def size
      @lock.synchronize { @data.size }
    end

    def stats
      loaded = @lock.synchronize { @data.dup }
      states = Hash.new(0)
      loaded.each_value { |v| states[v["state"]] += 1 }
      {
        "total" => loaded.size,
        "file" => @path,
        "size_kb" => File.exist?(@path) ? (File.size(@path) / 1024.0).round(1) : 0,
        "states" => states,
      }
    end

    private

    def load
      return {} unless File.exist?(@path)
      JSON.parse(File.binread(@path))
    rescue JSON::ParserError, Errno::ENOENT
      {}
    end
  end
end
