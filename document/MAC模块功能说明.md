
# MAC 模块功能说明

> 源码位置：`support/basic/mac_address.rb`
> 加载方式：`require 'network'` 自动加载，或单独 `require_relative 'support/basic/mac_address'`

## MAC 地址背景

MAC 地址是数据链路层 48 位硬件地址，通常用 6 组或 3 组十六进制表示。

### 支持的输入格式

| 分隔符 | 分组数 | 示例                | 说明             |
| ------ | ------ | ------------------- | ---------------- |
| `-`    | 6      | `00-1A-2B-3C-4D-5E` | Windows 常用     |
| `:`    | 6      | `00:1A:2B:3C:4D:5E` | Linux/Cisco 常用 |
| `.`    | 3      | `001A.2B3C.4D5E`    | 点分格式         |
| `-`    | 3      | `001A-2B3C-4D5E`    | 部分设备 3 段横杠 |
| 无     | —      | `001A2B3C4D5E`      | 无分隔符         |

### 特殊位

| 位     | 位置        | 说明                          |
| ------ | ----------- | ----------------------------- |
| I/G 位 | 首字节 bit0 | 0=单播（个体），1=组播        |
| U/L 位 | 首字节 bit1 | 0=全球分配（OUI），1=本地分配 |

### EUI-64

MAC → EUI-64：在 OUI（前 3 字节）和 NIC（后 3 字节）之间插入 `FF:FE`。

```
00-1A-2B-3C-4D-5E → 00:1A:2B:FF:FE:3C:4D:5E
```

IPv6 SLAAC 接口标识符在此基础上翻转 U/L 位（首字节 XOR `0x02`）。

---

## 统一入口 `MAC`

`MAC.address` 接受 String、Array 或 Integer，返回 `MacAddress` 对象：

```ruby
require 'network'

MAC.address("00:1A:2B:3C:4D:5E")      # 6 段冒号
MAC.address("001A.2B3C.4D5E")          # 3 段点分
MAC.address("001A-2B3C-4D5E")          # 3 段横杠
MAC.address("001A2B3C4D5E")            # 无分隔符
MAC.address(0x001A2B3C4D5E)            # Integer
MAC.address([0x00, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])  # Array
```

也可直接用 `MacAddress.new`，参数同上。

不同格式的同一地址等价：

```ruby
a = MAC.address("00:1A:2B:3C:4D:5E")
b = MAC.address("001A.2B3C.4D5E")
a == b          # => true
a.number == b.number  # => true
```

---

## 属性

```ruby
mac = MacAddress.new("00-1A-2B-3C-4D-5E")

mac.numbers  # => [0, 26, 43, 60, 77, 94]   6 字节整数数组
mac.number   # => 112394521950               48 位整数
```

---

## 输出格式

### `to_hex(separator, groups)` — 通用格式化

`separator` 控制分隔符，`groups` 控制分组数（1 / 2 / 3 / 6）：

```ruby
mac = MacAddress.new("00-1A-2B-3C-4D-5E")

mac.to_hex("-", 6)  # => "00-1a-2b-3c-4d-5e"   6 组（默认）
mac.to_hex(":", 6)  # => "00:1a:2b:3c:4d:5e"   Linux 格式
mac.to_hex(".", 3)  # => "001a.2b3c.4d5e"       Cisco 点分
mac.to_hex("", 1)   # => "001a2b3c4d5e"         无分隔符
mac.to_hex("", 6)   # => "001a2b3c4d5e"         无分隔符（6 组拼合）
```

### 其他格式方法

```ruby
mac.to_s             # => "00-1a-2b-3c-4d-5e"   默认 6 组 - 分隔
mac.to_upcase(":", 6) # => "00:1A:2B:3C:4D:5E"  大写
mac.to_downcase       # => "00-1a-2b-3c-4d-5e"  小写
mac.inspect           # => "00-1a-2b-3c-4d-5e"  同 to_s

mac.to_a  # => [0, 26, 43, 60, 77, 94]          6 字节整数数组
```

---

## 属性判定

### 单播 / 组播（I/G 位）

```ruby
MacAddress.new("00-1A-2B-3C-4D-5E").multicast?  # => false  单播
MacAddress.new("01-00-5E-00-00-01").multicast?  # => true   组播

# 别名
mac.group?       # 等价 multicast?
```

### 全球 / 本地分配（U/L 位）

```ruby
MacAddress.new("00-1A-2B-3C-4D-5E").locally_administered?  # => false  全球分配
MacAddress.new("02-00-00-00-00-01").locally_administered?  # => true   本地分配

MacAddress.new("00-1A-2B-3C-4D-5E").universally_administered?  # => true
```

### 特殊地址

```ruby
MacAddress.new("FF-FF-FF-FF-FF-FF").broadcast?  # => true  全 1 广播
MacAddress.new("00-00-00-00-00-00").zero?       # => true  全 0 空地址
```

### OUI / NIC 分段

```ruby
mac = MacAddress.new("00-1A-2B-3C-4D-5E")

mac.oui  # => "00-1a-2b"   前 3 字节（组织唯一标识符）
mac.nic  # => "3c-4d-5e"   后 3 字节（网卡标识）
```

---

## EUI-64 / IPv6 SLAAC

### `to_eui64` — 扩展为 8 字节

在 OUI 和 NIC 之间插入 `FF:FE`，返回 8 字节整数数组：

```ruby
mac = MacAddress.new("00-1A-2B-3C-4D-5E")

mac.to_eui64
# => [0, 26, 43, 255, 254, 60, 77, 94]

mac.to_eui64_s        # => "00:1a:2b:ff:fe:3c:4d:5e"   默认冒号分隔
mac.to_eui64_s("-")   # => "00-1a-2b-ff-fe-3c-4d-5e"
```

### `to_interface_id` — IPv6 SLAAC 接口标识符

在 EUI-64 基础上翻转 U/L 位（首字节 bit1 翻转），返回 8 字节整数数组：

```ruby
mac = MacAddress.new("00-1A-2B-3C-4D-5E")

mac.to_interface_id
# => [2, 26, 43, 255, 254, 60, 77, 94]

mac.to_interface_id_s        # => "02:1a:2b:ff:fe:3c:4d:5e"
mac.to_interface_id_s("-")   # => "02-1a-2b-ff-fe-3c-4d-5e"
```

> `00` 翻转后变 `02`，因为 U/L 位（bit1）从 0 变 1，表示本地生成。

---

## 排序比较

`MacAddress` 包含 `Comparable`，按 48 位整数排序：

```ruby
a = MacAddress.new("00-00-00-00-00-01")
b = MacAddress.new("00-00-00-00-00-02")
c = MacAddress.new("FF-FF-FF-FF-FF-FF")

a < b      # => true
a == a     # => true

[a, c, b].sort.map(&:number)
# => [1, 2, 281474976710655]
```

### 作为 Hash key

```ruby
h = {
  MacAddress.new("00-00-00-00-00-01") => "网关",
  MacAddress.new("00-00-00-00-00-02") => "终端"
}
h[MacAddress.new("00:00:00:00:00:01")]  # => "网关"（不同分隔符等价）

MacAddress.new("00:1A:2B:3C:4D:5E").hash == MacAddress.new("00-1A-2B-3C-4D-5E").hash
# => true
```

---

## 有效性检查

`MacAddress.valid?` 不抛异常，返回布尔值：

```ruby
MacAddress.valid?("00:1A:2B:3C:4D:5E")  # => true
MacAddress.valid?("GG:1A:2B:3C:4D:5E")  # => false
MacAddress.valid?("00-1A-2B-3C")        # => false  段数错误
```

---

## 兼容原接口

### `writing(groups, splitter)` — 原版格式化方法

```ruby
mac = MacAddress.new("00-1A-2B-3C-4D-5E")

mac.writing           # => "001a-2b3c-4d5e"        默认 3 组 - 分隔
mac.writing(6, ":")   # => "00:1a:2b:3c:4d:5e"     6 组冒号
mac.writing(10, "-")  # => "00-1a-2b-3c-4d-5e"     >=6 归为 6
```

> 推荐使用 `to_hex` 代替 `writing`，接口更清晰。

---

## 典型业务场景

### 1. 批量格式转换

```ruby
# 设备导出的 MAC 格式不统一，统一转为冒号格式
macs = ["00-1A-2B-3C-4D-5E", "001A.2B3C.4D5E", "001A-2B3C-4D5E", "001A2B3C4D5E"]
macs.map { |m| MAC.address(m).to_hex(":", 6) }
# => ["00:1a:2b:3c:4d:5e", "00:1a:2b:3c:4d:5e", "00:1a:2b:3c:4d:5e", "00:1a:2b:3c:4d:5e"]
```

### 2. 识别组播地址

```ruby
# 从抓包数据中筛出组播 MAC
mac_list = ["00-1A-2B-3C-4D-5E", "01-00-5E-00-00-01", "33-33-00-00-00-01"]

multicast = mac_list.select { |m| MAC.address(m).multicast? }
# => ["01-00-5E-00-00-01", "33-33-00-00-00-01"]
```

### 3. 提取 OUI 做厂商归类

```ruby
# 按 OUI 前缀分组统计设备厂商
devices = [
  "00-1A-2B-3C-4D-5E",   # OUI: 00-1a-2b
  "00-1A-2B-AA-BB-CC",   # OUI: 00-1a-2b
  "08-00-27-11-22-33",   # OUI: 08-00-27
]

devices.group_by { |m| MAC.address(m).oui }
# => {"00-1a-2b" => ["00-1A-2B-3C-4D-5E", "00-1A-2B-AA-BB-CC"],
#     "08-00-27" => ["08-00-27-11-22-33"]}
```

### 4. 生成 IPv6 SLAAC 地址

```ruby
# 已知 MAC 和 IPv6 前缀，生成 SLAAC 自动配置地址
mac = MAC.address("00-1A-2B-3C-4D-5E")
prefix = "2001:db8::"

interface_id = mac.to_interface_id_s(":")
slaac_address = "#{prefix}#{interface_id}"
# => "2001:db8::02:1a:2b:ff:fe:3c:4d:5e"
```

### 5. MAC 地址去重

```ruby
# 不同格式记录的同一 MAC 需要去重
raw = ["00:1A:2B:3C:4D:5E", "00-1A-2B-3C-4D-5E", "001A.2B3C.4D5E", "001A-2B3C-4D5E", "08-00-27-11-22-33"]

unique = raw.map { |m| MAC.address(m) }.uniq.map(&:to_s)
# => ["00-1a-2b-3c-4d-5e", "08-00-27-11-22-33"]
```
