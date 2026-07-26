
# IP 模块功能说明

> 源码位置：`support/basic/ip.rb` / `ipv4_address.rb` / `ipv6_address.rb`
> 加载方式：`require 'network'` 自动加载，或单独 `require_relative 'support/basic/ip'`

## 统一入口 `IP`

`IP` 模块提供 `v4` / `v6` / `range` / `cross` / `xross` 五个模块方法，内部按地址串是否含 `.` `:` 自动分派到 `IPv4` / `IPv6`。

### `IP.v4(string)` — 解析 IPv4 或 CIDR

```ruby
require 'network'

# 单地址 → 返回 IPv4 对象
ip = IP.v4('10.37.214.42')
ip.to_d          # => "10.37.214.42"   十进制点分
ip.number        # => 173185606        32位整数
ip.class_a?      # => true
ip.private?      # => true

# CIDR → 返回 [IPv4, IPv4Mask]
ip2, mask = IP.v4('10.37.214.42/17')
mask.to_d            # => "255.255.128.0"
mask.mask_counter    # => 17            前缀长度
```

### `IP.v6(string)` — 解析 IPv6 或 CIDR

```ruby
# 单地址 → 返回 IPv6 对象
ip = IP.v6('2001:db8::1')
ip.to_s          # => "2001:db8::1"           压缩形式
ip.to_s_full     # => "2001:0db8:0000:...0001" 完整 8 段
ip.number        # => 42540488161975842760550356425300241409  128位整数

# CIDR → 返回 [IPv6, IPv6Mask]
ip6, mask = IP.v6('2001:db8::/32')
mask.mask_counter    # => 32
```

### `IP.range(addr)` — 展开地址区间

支持三种输入，统一返回 `[start, end]`：

```ruby
# CIDR → [网络地址, 广播地址]
start_ip, end_ip = IP.range('1.0.4.0/22')
start_ip.to_d    # => "1.0.4.0"
end_ip.to_d      # => "1.0.7.255"

# 区间串 → [起始, 结束]
s, e = IP.range('1.0.4.0-1.0.7.255')
s.to_d           # => "1.0.4.0"
e.to_d           # => "1.0.7.255"

# 单址 → [addr, addr]
s, e = IP.range('1.0.4.0')
[s.to_d, e.to_d] # => ["1.0.4.0", "1.0.4.0"]

# IPv6 同理
s6, e6 = IP.range('2001:db8::/64')
[s6.to_s, e6.to_s]  # => ["2001:db8::", "2001:db8::ffff:ffff:ffff:ffff"]
```

### `IP.cross(range1, range2)` — 判断两区间是否相交

```ruby
r1 = IP.range('10.0.0.0/24')   # [10.0.0.0, 10.0.0.255]
r2 = IP.range('10.0.0.128/25') # [10.0.0.128, 10.0.0.255]
r3 = IP.range('10.0.1.0/24')   # [10.0.1.0, 10.0.1.255]

IP.cross(r1, r2)  # => true   相交
IP.cross(r1, r3)  # => false  不相交
```

### `IP.xross(range1, range2, option)` — 求两区间合并端点

返回排序去重后的端点序列，从 0 地址起算转换为 IP 对象：

```ruby
r1 = IP.range('10.0.0.0/24')
r2 = IP.range('10.0.0.128/25')

IP.xross(r1, r2, :v4).map(&:to_d)
# => ["10.0.0.0", "10.0.0.128", "10.0.0.255"]

# IPv6 用 :v6
r1v6 = IP.range('2001:db8::/64')
r2v6 = IP.range('2001:db8::8000:0/113')
IP.xross(r1v6, r2v6, :v6).map(&:to_s)
```

---

## IPv4 对象方法

### 创建

```ruby
ip = IPv4.new('10.37.214.42')
ip2, mask = IP.v4('192.168.1.0/24')   # 推荐：通过 IP.v4 解析 CIDR

# IPv4 接受十六进制 / 二进制前缀
IPv4.new('0x0a.0x25.0xd6.0x2a').to_d  # => "10.37.214.42"
IPv4.new('0b00001010.0.0.1').to_d     # => "10.0.0.1"
```

### 输出格式

```ruby
ip = IPv4.new('10.37.214.42')

ip.to_a    # => [10, 37, 214, 42]     四段整数数组
ip.to_d    # => "10.37.214.42"        十进制点分
ip.to_h    # => "0a.25.d6.2a"         十六进制点分
ip.to_b    # => "00001010.00100101.11010110.00101010"  二进制点分
ip.to_s    # => "10.37.214.42"        同 to_d
ip.number  # => 173185606             32位整数
```

### 算术运算

```ruby
ip = IPv4.new('10.0.0.1')

(ip + 5).to_d     # => "10.0.0.6"     加偏移量
(ip - 1).to_d     # => "10.0.0.0"     减偏移量

# 按位与：可传 IPv4、IPv4Mask 或前缀长度
ip & IPv4.new('255.255.255.0')   # 网络地址
ip & 24                           # 同上，等价写法
```

### 地址分类

```ruby
IPv4.new('10.0.0.1').class_a?    # => true   A 类 (10-126)
IPv4.new('128.1.0.0').class_b?   # => true   B 类 (128-191)
IPv4.new('192.0.1.0').class_c?   # => true   C 类 (192-223)
IPv4.new('224.0.0.1').class_d?   # => true   D 类 (224-239) 组播
IPv4.new('240.0.0.1').class_e?   # => true   E 类 (240-255) 保留

IPv4.new('10.0.0.1').private?    # => true   私有地址 (10/172.16-31/192.168)
IPv4.new('8.8.8.8').private?     # => false
IPv4.new('127.0.0.1').loopback?  # => true   环回地址
IPv4.new('0.0.0.0').special?     # => true   特殊地址
```

### 掩码与网络

```ruby
ip, mask = IP.v4('10.37.214.42/17')

# 掩码属性
mask.to_d             # => "255.255.128.0"
mask.mask?            # => true       是否合法网络掩码
mask.mask_counter     # => 17         前缀长度
mask.anti_mask        # => 反掩码对象

# 网络地址
net = ip.network_with(mask)
net.to_d              # => "10.37.128.0"

# 网段完整区间
start_ip, end_ip = ip.range_with(mask)
start_ip.to_d         # => "10.37.128.0"    网络地址
end_ip.to_d           # => "10.37.255.255"  广播地址

# 判断是否为该网段的网络地址
ip.network_with?(mask)  # => false
net.network_with?(mask) # => true

# 最长公共前缀长度
IPv4.new('10.0.0.1').prefix_with(IPv4.new('10.0.1.1'))  # => 23
```

### 子网划分 `delegation`

```ruby
# 把 10.0.0.0/24 划分为 /26 子网 → 4 个子网
base = IPv4.new('10.0.0.0')
subnets = base.delegation(24, 26)
subnets.map { |ip, m| "#{ip.to_d}/#{m.mask_counter}" }
# => ["10.0.0.0/26", "10.0.0.64/26", "10.0.0.128/26", "10.0.0.192/26"]

# 也可传 IPv4/IPv4Mask 作为参数
base.delegation(IPv4Mask.number(24), IPv4Mask.number(27))
```

### 排序比较

```ruby
addrs = [IPv4.new('10.0.0.3'), IPv4.new('10.0.0.1'), IPv4.new('10.0.0.2')]
addrs.sort.map(&:to_d)   # => ["10.0.0.1", "10.0.0.2", "10.0.0.3"]
addrs.min.to_d           # => "10.0.0.1"
```

---

## IPv6 对象方法

接口与 IPv4 对称，区别在于 128 位、8 段十六进制。

```ruby
ip6, mask6 = IP.v6('2001:db8::1/64')

# 输出
ip6.to_a       # => [8193, 3512, 0, 0, 0, 0, 0, 1]
ip6.to_h       # => "2001:0db8:0000:0000:0000:0000:0000:0001"
ip6.to_s       # => "2001:db8::1"            压缩形式
ip6.to_s_full  # => "2001:0db8:0000:...0001" 完整形式
ip6.number     # => 42540488161975842760550356425300241409

# 算术 / 掩码 / 网络（同 IPv4）
ip6 & 64                              # 网络地址
ip6.network_with(mask6).to_s          # => "2001:db8::"
ip6.range_with(mask6).map(&:to_s)     # => ["2001:db8::", "2001:db8::ffff:ffff:ffff:ffff"]

# 子网划分
base6 = IPv6.new('2001:db8::')
subnets6 = base6.delegation(64, 66)
subnets6.map { |ip, m| "#{ip.to_s}/#{m.mask_counter}" }
# => ["2001:db8::/66", "2001:db8:0:0:4000::/66", "2001:db8:0:0:8000::/66", "2001:db8:0:0:c000::/66"]
```

---

## IPv4Mask / IPv6Mask 工厂

```ruby
# 按前缀长度创建网络掩码
IPv4Mask.number(24).to_d     # => "255.255.255.0"
IPv4Mask.number(17).to_d     # => "255.255.128.0"
IPv6Mask.number(64).to_h     # => "ffff:ffff:ffff:ffff:0000:0000:0000:0000"

# 按字符串创建（校验合法性）
IPv4Mask.string('255.255.0.0').mask_counter   # => 16

# 反掩码
IPv4Mask.anti_number(24).to_d    # => "0.0.0.255"
IPv4Mask.anti_string('0.0.0.255').anti_mask_counter  # => 24
```

---

## 典型业务场景

### 1. 判断 IP 是否在某个网段内

```ruby
ip = IP.v4('10.37.214.42')
net_start, net_end = IP.range('10.37.128.0/17')
ip.number.between?(net_start.number, net_end.number)  # => true
```

### 2. CIDR 转区间 → 整数范围（geo-api 内部用法）

```ruby
# geodb.rb 把 CIDR 转为 [start_num, end_num] 作为 JSON 键
range = IP.range('1.0.4.0/22').map(&:number)  # => [16777984, 16778239]
```

### 3. 合并重叠网段

```ruby
ranges = [
  IP.range('10.0.0.0/24'),
  IP.range('10.0.0.128/25'),
  IP.range('10.0.1.0/24')
]

# 去重合并
merged = [ranges.first]
ranges[1..].each do |r|
  if IP.cross(merged.last, r)
    merged[-1] = [merged.last.first, [merged.last.last, r.last].max]
  else
    merged << r
  end
end

merged.map { |s, e| "#{s.to_d} - #{e.to_d}" }
# => ["10.0.0.0 - 10.0.1.255"]
```

### 4. 子网规划

```ruby
# 从 172.16.0.0/16 中分配 /24 子网，取前 4 个
base = IPv4.new('172.16.0.0')
all_subnets = base.delegation(16, 24)
allocated = all_subnets.first(4)
allocated.map { |ip, m| ip.to_d + "/#{m.mask_counter}" }
# => ["172.16.0.0/24", "172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]
```
