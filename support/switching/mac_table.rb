# coding: utf-8
# frozen_string_literal: true

# MAC 地址表：学习/老化。
#
# 实现原理：源 MAC + 入端口映射；老化定时（按 aging_time 清除）；
# 静态表项；查询与统计。
#
# 设计要点：
# - 纯内存，不感知仿真环境
# - 通过 age_out(now) 被动老化，不自己计时
#
# 用法：
#   table = MACTable.new(aging_time: 300)
#   table.learn("00:1a:2b:3c:4d:5e", port: "Gi0/1", now: 0)
#   table.lookup("00:1a:2b:3c:4d:5e")  # => {port: "Gi0/1", learned_at: 0}
#   table.age_out(now: 350)  # 老化超过 300 秒的表项

require_relative '../basic/mac_address'

class MACTable
  DEFAULT_AGING_TIME = 300  # 默认老化时间（秒）

  # MAC 表项。
  Entry = Data.define(:mac, :port, :learned_at, :static) do
    def to_s
      "#{mac} -> #{port}#{static ? ' (static)' : ''}"
    end
  end

  attr_reader :entries, :aging_time

  def initialize(aging_time: DEFAULT_AGING_TIME)
    @entries     = {}  # mac_str => Entry
    @aging_time  = aging_time
  end

  # 学习 MAC 地址。
  # mac: MAC 地址字符串或 MacAddress 对象
  # port: 端口标识
  # now: 当前虚拟时间
  def learn(mac, port:, now:)
    mac_str = mac.is_a?(MacAddress) ? mac.to_s : MacAddress.new(mac).to_s

    # 不覆盖静态表项
    existing = @entries[mac_str]
    if existing&.static
      return unless port == existing.port
      return  # 静态表项不更新
    end

    @entries[mac_str] = Entry.new(
      mac: mac_str,
      port: port,
      learned_at: now,
      static: false
    )
  end

  # 添加静态表项。
  def add_static(mac, port)
    mac_str = mac.is_a?(MacAddress) ? mac.to_s : MacAddress.new(mac).to_s
    @entries[mac_str] = Entry.new(
      mac: mac_str,
      port: port,
      learned_at: 0,
      static: true
    )
  end

  # 删除静态表项。
  def remove_static(mac)
    mac_str = mac.is_a?(MacAddress) ? mac.to_s : MacAddress.new(mac).to_s
    entry = @entries[mac_str]
    @entries.delete(mac_str) if entry&.static
  end

  # 查找 MAC 地址对应的端口。
  def lookup(mac)
    mac_str = mac.is_a?(MacAddress) ? mac.to_s : MacAddress.new(mac).to_s
    @entries[mac_str]
  end

  # 老化处理：清除超过 aging_time 的动态表项。
  def age_out(now:)
    @entries.reject! do |_, entry|
      !entry.static && (now - entry.learned_at) > @aging_time
    end
  end

  # 按端口删除表项（端口 down 时调用）。
  def remove_by_port(port)
    @entries.reject! { |_, entry| entry.port == port && !entry.static }
  end

  # 表项总数。
  def size
    @entries.size
  end

  # 动态表项数。
  def dynamic_count
    @entries.count { |_, e| !e.static }
  end

  # 静态表项数。
  def static_count
    @entries.count { |_, e| e.static }
  end

  # 清空所有动态表项。
  def clear_dynamic
    @entries.reject! { |_, e| !e.static }
  end

  # 遍历所有表项。
  def each(&blk)
    @entries.each_value(&blk)
  end

  # 快照为 Hash。
  def to_h
    @entries.transform_values do |e|
      { port: e.port, learned_at: e.learned_at, static: e.static }
    end
  end
end
