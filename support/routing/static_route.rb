# coding: utf-8
# frozen_string_literal: true

# 静态路由：增删、出接口/下一跳有效性检查、递归下一跳解析接口。
#
# 不联动 RIB，只提供静态路由的管理和解析接口。
# service 层负责将 static_route 的条目安装到 RIB。
#
# 用法：
#   sr = StaticRoute.new
#   sr.install("10.0.0.0/8", "192.168.1.1")
#   sr.install("0.0.0.0/0", "192.168.1.254", description: "default route")
#   sr.routes  # => { "10.0.0.0/8" => {next_hop: "192.168.1.1"}, ... }
#   sr.resolve_next_hop("10.0.0.0/8", rib)  # => 递归解析

require 'set'
require_relative 'prefix'

class StaticRoute
  attr_reader :routes

  def initialize
    @routes = {}
  end

  # 安装一条静态路由。
  # prefix: CIDR 字符串
  # next_hop: 下一跳 IP
  # ifindex: 出接口（可选）
  # description: 描述（可选）
  # distance: 管理距离（可选，默认 1）
  def install(prefix, next_hop, ifindex: nil, description: nil, distance: 1)
    @routes[prefix] = {
      next_hop: next_hop,
      ifindex: ifindex,
      description: description,
      distance: distance
    }
  end

  # 删除静态路由。
  def remove(prefix)
    @routes.delete(prefix)
  end

  # 查询静态路由。
  def get(prefix)
    @routes[prefix]
  end

  # 递归解析下一跳：如果 next_hop 不是直连，在 RIB 中查找到达 next_hop 的路由。
  # 返回最终下一跳和出接口。
  def resolve_next_hop(prefix, rib, max_depth = 10)
    route = @routes[prefix]
    return nil unless route

    nh = route[:next_hop]
    visited = Set.new
    depth = 0

    while depth < max_depth
      break if visited.include?(nh)
      visited.add(nh)

      match = rib.lookup(nh)
      break unless match

      # 如果匹配的路由是 connected（直连），解析完成
      if match.protocol == :connected
        return { next_hop: nh, ifindex: match.ifindex || route[:ifindex] }
      end

      # 继续递归
      nh = match.next_hop
      depth += 1
    end

    { next_hop: nh, ifindex: route[:ifindex] }
  end

  # 遍历所有静态路由。
  def each(&blk)
    @routes.each(&blk)
  end

  def size
    @routes.size
  end

  # 导出为 RIB 可用的格式。
  def to_rib_entries
    @routes.map do |prefix_str, info|
      {
        prefix: prefix_str,
        next_hop: info[:next_hop],
        ifindex: info[:ifindex],
        protocol: :static,
        metric: info[:distance]
      }
    end
  end
end
