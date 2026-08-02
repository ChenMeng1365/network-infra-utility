
# ASNum 模块功能说明

> 源码位置：`support/basic/as_num.rb`
> 加载方式：`require 'network'` 自动加载，或单独 `require_relative 'support/basic/as_num'`

## AS 号背景

AS（自治系统）号是 BGP 路由中标识独立路由域的编号，分 16 位传统号和 32 位扩展号两个区间，每个区间内再分公有、私有、保留三类。

### 号段一览

| 位宽     | 类型   | 范围                              | 说明                     |
| -------- | ------ | --------------------------------- | ------------------------ |
| 16 位    | 公有   | 1 – 64511                         | 全球可路由，需向 RIR 申请 |
| 16 位    | 私有   | 64512 – 65534                     | 内部网络，不可通告公网   |
| 16 位    | 保留   | 0, 23456, 65535                   | AS 0 / AS_TRANS / 文档   |
| 32 位    | 公有   | 65536 – 4,199,999,999             | 全球可路由               |
| 32 位    | 私有   | 4,200,000,000 – 4,294,967,294     | 内部使用                 |
| 32 位    | 保留   | 4,294,967,295                     | 32 位全 1                |

> AS_TRANS（23456）用于 16 位与 32 位 BGP 互通过渡，归类为保留，不归公有。

### 两种记法

| 记法       | 示例        | 说明                            |
| ---------- | ----------- | ------------------------------- |
| **asplain** | `65546`     | 纯十进制整数                    |
| **asdot**   | `1.10`      | 高 16 位 . 低 16 位，各 0–65535 |

转换关系：`plain = high * 65536 + low`

---

## 创建

`ASNum.new` 接受 String（asplain 或 asdot）或 Integer：

```ruby
require 'network'

ASNum.new("65546")      # asplain 字符串
ASNum.new("1.10")       # asdot 字符串
ASNum.new(65546)        # Integer
ASNum.new("  65546  ")  # 自动去除前后空白
```

非法输入抛 `ArgumentError`：

```ruby
ASNum.new("abc")          # → ArgumentError (Invalid AS number)
ASNum.new("70000.1")      # → ArgumentError (asdot 段超 65535)
ASNum.new(4294967296)     # → ArgumentError (超 32 位范围)
ASNum.new(-1)             # → ArgumentError (负数)
```

---

## 属性

```ruby
as = ASNum.new("1.10")

as.number  # => 65546       32 位整数
as.high    # => 1           高 16 位
as.low     # => 10          低 16 位
```

---

## 输出格式

```ruby
as = ASNum.new("1.10")

as.to_i      # => 65546        十进制整数
as.to_plain  # => "65546"      asplain 字符串
as.to_dot    # => "1.10"       asdot 字符串（16 位范围内无点）
as.to_s      # => "1.10"       同 to_dot
as.inspect   # => "1.10"       同 to_dot
```

16 位号 `to_dot` 回退为纯数字：

```ruby
ASNum.new("100").to_dot    # => "100"
ASNum.new("65535").to_dot  # => "65535"
ASNum.new("65536").to_dot  # => "1.0"
```

### asplain ↔ asdot 互换

```ruby
ASNum.new("1.10").to_plain        # => "65546"
ASNum.new("65546").to_dot         # => "1.10"
ASNum.new("65000.20001").to_plain # => "4259860001"
ASNum.new("4259860001").to_dot    # => "65000.20001"
```

---

## 类型判定

```ruby
# 公有
ASNum.new("100").public?          # => true   (1 – 64511)
ASNum.new("65536").public?        # => true   (65536 – 4199999999)

# 私有
ASNum.new("64512").private?       # => true   (64512 – 65534)
ASNum.new("4200000000").private?  # => true   (4200000000 – 4294967294)

# 保留
ASNum.new("0").reserved?          # => true   AS 0
ASNum.new("23456").reserved?      # => true   AS_TRANS
ASNum.new("65535").reserved?      # => true   16 位文档保留
ASNum.new("4294967295").reserved? # => true   32 位全 1

# 一次性获取类型符号
ASNum.new("100").type          # => :public
ASNum.new("64512").type        # => :private
ASNum.new("23456").type        # => :reserved
```

> 三类互斥：同一 AS 号只属于一类。AS_TRANS(23456) 虽落在 1–64511 范围内，但因属保留号，`public?` 返回 false。

### 兼容原接口别名

```ruby
as = ASNum.new("100")
as.is_public_as?    # => true   等价 public?
as.is_private_as?   # => false  等价 private?
as.is_reserved_as?  # => false  等价 reserved?
```

---

## 位宽判定

```ruby
ASNum.new("100").as2?    # => true   16 位传统号 (0 – 65535)
ASNum.new("65536").as4?  # => true   32 位扩展号 (≥ 65536)

ASNum.new("65535").as4?  # => false
ASNum.new("65536").as2?  # => false
```

---

## 排序比较

`ASNum` 包含 `Comparable`，按 32 位整数排序：

```ruby
ASNum.new("100") < ASNum.new("200")    # => true
ASNum.new("1.10") == ASNum.new("65546") # => true（不同记法等价）
ASNum.new("1.10") == ASNum.new(65546)   # => true

arr = [ASNum.new("300"), ASNum.new("100"), ASNum.new("200")]
arr.sort.map(&:to_i)   # => [100, 200, 300]
arr.min.to_i           # => 100
```

### 作为 Hash key

```ruby
h = { ASNum.new("100") => "AS100", ASNum.new("200") => "AS200" }
h[ASNum.new("100")]    # => "AS100"

# 不同记法、相同值 → hash 一致
ASNum.new("1.10").hash == ASNum.new("65546").hash  # => true
```

---

## 典型业务场景

### 1. 批量判断 AS 号归属

```ruby
as_list = ["100", "64512", "23456", "4294967295", "65536"]
as_list.each do |s|
  as = ASNum.new(s)
  puts "#{s} → #{as.type}"
end
# 100 → public
# 64512 → private
# 23456 → reserved
# 4294967295 → reserved
# 65536 → public
```

### 2. BGP 路由表 AS 号去重排序

```ruby
# 从 BGP 表中收集的 AS 号（asdot 与 asplain 混用）
raw = ["1.10", "65546", "100", "65000.20001", "100"]

unique_sorted = raw.map { |s| ASNum.new(s) }.uniq.sort
unique_sorted.map(&:to_plain)
# => ["100", "65546", "4259860001"]
```

### 3. asdot ↔ asplain 批量转换

```ruby
# Cisco 设备导出 asdot，需转为 asplain 做入库
["1.10", "65000.20001", "0.100"].map { |s| ASNum.new(s).to_plain }
# => ["65546", "4259860001", "100"]

# 反过来，asplain 转 asdot
["65546", "4259860001", "100"].map { |s| ASNum.new(s).to_dot }
# => ["1.10", "65000.20001", "100"]
```

### 4. 过滤私有和保留 AS 号

```ruby
as_paths = [100, 64512, 23456, 65536, 65000, 0]

announcable = as_paths.reject { |n| ASNum.new(n).private? || ASNum.new(n).reserved? }
# => [100, 65536]
```

---

## 内部常量

| 常量          | 值              | 说明            |
| ------------- | --------------- | --------------- |
| `AS2_MAX`     | 65535           | 16 位上限       |
| `AS4_MAX`     | 4294967295      | 32 位上限       |
| `PUB_16_MIN`  | 1               | 16 位公有下限   |
| `PUB_16_MAX`  | 64511           | 16 位公台上限   |
| `PRIV_16_MIN` | 64512           | 16 位私有下限   |
| `PRIV_16_MAX` | 65534           | 16 位私台上限   |
| `PUB_32_MIN`  | 65536           | 32 位公有下限   |
| `PUB_32_MAX`  | 4199999999      | 32 位公台上限   |
| `PRIV_32_MIN` | 4200000000      | 32 位私有下限   |
| `PRIV_32_MAX` | 4294967294      | 32 位私台上限   |
| `RESERVED_16` | [0, 23456, 65535] | 16 位保留号列表 |
| `RESERVED_32` | 4294967295      | 32 位保留号     |
