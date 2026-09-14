# coding: utf-8
# frozen_string_literal: true

# 最长前缀匹配（Longest Prefix Match）Trie。
#
# 基于二叉 Trie 实现，支持 IPv4/IPv6 统一位串。
# 查找复杂度 O(前缀长)。
#
# 用法：
#   trie = LpmTrie.new
#   trie.insert("10.0.0.0/8", data1)
#   trie.insert("10.1.0.0/16", data2)
#   trie.match(IPv4.new("10.1.1.1"))  # => data2 (最长前缀匹配)
#   trie.match("10.2.0.1")            # => data1

require_relative '../basic/ip'

class LpmTrie
  Node = Struct.new(:left, :right, :data) do
    def initialize
      self.left = nil
      self.right = nil
      self.data = nil
    end
  end

  attr_reader :root, :count

  def initialize
    @root  = Node.new
    @count = 0
  end

  # 插入前缀与关联数据。prefix 为 CIDR 字符串。
  def insert(prefix, data)
    bits, len = to_bits(prefix)
    node = @root

    len.times do |i|
      bit = bits[i]
      child = bit == 0 ? node.left : node.right
      if child.nil?
        child = Node.new
        bit == 0 ? node.left = child : node.right = child
      end
      node = child
    end

    @count += 1 if node.data.nil?
    node.data = data
  end

  # 最长前缀匹配。ip 为 IPv4/IPv6/字符串。
  def match(ip)
    bits = ip_to_bits(ip)
    node = @root
    best = node.data  # 检查根节点（处理默认路由 /0）

    bits.each do |bit|
      child = bit == 0 ? node.left : node.right
      break if child.nil?

      node = child
      best = node.data if node.data
    end

    best
  end

  # 删除指定前缀。
  def delete(prefix)
    bits, len = to_bits(prefix)
    node = @root

    path = []
    len.times do |i|
      bit = bits[i]
      child = bit == 0 ? node.left : node.right
      return false unless child

      path << [node, bit]
      node = child
    end

    return false unless node.data

    node.data = nil
    @count -= 1

    # 清理空叶子节点
    path.reverse_each do |parent_node, bit|
      child = bit == 0 ? parent_node.left : parent_node.right
      next unless child && child.data.nil? && child.left.nil? && child.right.nil?

      bit == 0 ? parent_node.left = nil : parent_node.right = nil
    end

    true
  end

  def empty?
    @count.zero?
  end

  # 遍历所有有数据的节点。
  def each(&blk)
    return to_enum(:each) unless block_given?

    traverse(@root, '', &blk)
  end

  private

  def traverse(node, path, &blk)
    yield [path, node.data] if node.data
    traverse(node.left, path + '0', &blk) if node.left
    traverse(node.right, path + '1', &blk) if node.right
  end

  def to_bits(prefix)
    if prefix.is_a?(Prefix)
      ip_to_bits(prefix.network) # 取前 len 位
    else
      addr_str, len_str = prefix.split('/')
      len = len_str.to_i
      ip = addr_str.include?(':') ? IPv6.new(addr_str) : IPv4.new(addr_str)
      [ip_to_bits(ip).first(len), len]
    end
  end

  def ip_to_bits(ip)
    case ip
    when IPv4
      ip.to_b.gsub('.', '').chars.map(&:to_i)
    when IPv6
      nums = ip.numbers
      nums.flat_map { |n| '%08b' % n }.chars.map(&:to_i)
    when String
      ip_obj = ip.include?(':') ? IPv6.new(ip) : IPv4.new(ip)
      ip_to_bits(ip_obj)
    else
      raise ArgumentError, "Cannot convert #{ip.class} to bits"
    end
  end
end
