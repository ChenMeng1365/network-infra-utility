
# Geo 命令工具使用方法

> 命令文件：`bin/geo-load` / `bin/geo-api` / `bin/geo-get`
> 安装方式：`gem install` 后三个命令自动进入 PATH，直接全局可用

三个命令构成完整工作流：

```
geo-load (CSV→JSON)  →  geo-api (启动查询服务)  →  geo-get (查询 IP 归属)
```

---

## 一、命令行用法

### 1. `geo-load` — GeoLite2 CSV 转 JSON

把 GeoLite2 解压后的 CSV 目录转换为 geo-api 可用的 JSON 数据文件。一次调用依次执行 ASN / City / Country 三类转换，生成 7 个 JSON 文件。

**用法：**

```
geo-load [RAW_DIR] [DOC_DIR] [options]
```

**参数：**

| 参数 | 说明 |
|------|------|
| `RAW_DIR` | GeoLite2 CSV 目录（可省，省则在当前目录查找） |
| `DOC_DIR` | JSON 输出目录（可省，省则输出到 `./geodb/`） |

**参数规则：**

- **RAW_DIR 不写**：在当前工作目录下递归查找 `GeoLite2-ASN-CSV_*` / `GeoLite2-City-CSV_*` / `GeoLite2-Country-CSV_*` 目录，找不到则报错退出
- **RAW_DIR 写了但路径不存在**：报错退出
- **DOC_DIR 不写**：在当前工作目录下生成 `geodb/` 子目录
- **DOC_DIR 写了但路径不存在**：自动创建该目录；创建不了则报错退出
- **DOC_DIR 写了且路径已存在**：直接往里写（覆盖同名文件）

**选项：**

| 选项 | 说明 |
|------|------|
| `--asn-only` | 仅转换 ASN 数据 |
| `--city-only` | 仅转换 City 数据 |
| `--country-only` | 仅转换 Country 数据 |
| `-h, --help` | 显示帮助 |
| `-v, --version` | 显示版本 |

不指定 `--*-only` 时三类全转。

**生成的文件：**

```
asn.json          city-IPv4.json    city-IPv6.json
country-IPv4.json country-IPv6.json
geo-city.json     geo-country.json
```

**示例：**

```bash
# 当前目录下有 GeoLite2 CSV 解压包，输出到 ./geodb/
geo-load

# 指定 CSV 目录，输出到默认 ./geodb/
geo-load /data/GeoLite2-CSV

# 指定输入和输出
geo-load /data/GeoLite2-CSV /var/lib/geodb

# 只转 ASN（最轻量，约 30 秒）
geo-load /data/GeoLite2-CSV --asn-only

# 只转 Country
geo-load /data/GeoLite2-CSV --country-only
```

**输出目录结构要求：**

RAW_DIR 期望包含以下子目录之一（或全部），每个子目录内含对应 CSV 文件：

```
GeoLite2-ASN-CSV_*/
  ├── GeoLite2-ASN-Blocks-IPv4.csv
  └── GeoLite2-ASN-Blocks-IPv6.csv

GeoLite2-City-CSV_*/
  ├── GeoLite2-City-Locations-zh-CN.csv
  ├── GeoLite2-City-Blocks-IPv4.csv
  └── GeoLite2-City-Blocks-IPv6.csv

GeoLite2-Country-CSV_*/
  ├── GeoLite2-Country-Locations-zh-CN.csv
  ├── GeoLite2-Country-Blocks-IPv4.csv
  └── GeoLite2-Country-Blocks-IPv6.csv
```

工具会递归扫描 RAW_DIR 下的 `**/GeoLite2-*-CSV_*/` 目录，不要求三类目录都在。

---

### 2. `geo-api` — 启动 IP 归属查询服务

把 JSON 数据文件加载到内存，启动 HTTP 服务供 geo-get 或其他客户端查询。

**用法：**

```
geo-api [options]
```

**选项：**

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `-d, --data-dir DIR` | `./geodb/` | JSON 数据文件目录（或环境变量 `GEODB_DATA_DIR`） |
| `-b, --host HOST` | `0.0.0.0` | 监听地址 |
| `-p, --port PORT` | `9292` | 监听端口 |
| `-s, --server NAME` | `puma` | Rack 服务器 |
| `-h, --help` | | 显示帮助 |
| `-v, --version` | | 显示版本 |

**启动前校验：** 目录不存在或目录下没有任何 `.json` 文件会直接报错退出。

**示例：**

```bash
# 默认配置（读取 ./geodb/，监听 0.0.0.0:9292）
geo-api

# 指定数据目录
geo-api -d /var/lib/geodb

# 指定数据和端口
geo-api -d /var/lib/geodb -p 8080

# 仅本机访问
geo-api -b 127.0.0.1 -d ./geodb

# 通过环境变量指定数据目录
GEODB_DATA_DIR=/data/geodb geo-api
```

**HTTP 接口一览：**

| 接口 | 参数 | 说明 |
|------|------|------|
| `GET /` | 无 | 服务信息与接口清单 |
| `GET /geo/asn?num=XXX` | AS 编号 | 查该 AS 名下所有地址段 |
| `GET /geo/asn?addr=X.X.X.X` | IP 地址 | 按 IP 反查所属 AS |
| `GET /geo/city?id=XXX` | geoname_id | 查城市级定位信息 |
| `GET /geo/city?addr=X.X.X.X` | IP 地址 | 按 IP 查城市归属 |
| `GET /geo/country?id=XXX` | geoname_id | 查国别信息 |
| `GET /geo/country?addr=X.X.X.X` | IP 地址 | 按 IP 查国家归属 |

完整接口文档见 `service/geodb/GeoAPI.md`。

---

### 3. `geo-get` — 查询单个 IP 的归属信息

向运行中的 geo-api 服务发起查询，一次输入 IP，同时拉取 country / city / asn 三类信息并汇总输出。

**用法：**

```
geo-get [IP] [options]
```

**选项：**

| 选项 | 说明 |
|------|------|
| `-t, --text` | 文字格式输出（默认） |
| `-j, --json` | JSON 格式输出 |
| `--country` | 仅查询国家接口 |
| `--city` | 仅查询城市接口 |
| `--asn` | 仅查询 ASN 接口 |
| `-h, --help` | 显示帮助 |
| `-v, --version` | 显示版本 |

不指定 `--country` / `--city` / `--asn` 时三接口齐查。不指定 IP 时用默认演示 IP `1.181.240.251`。

默认连 `http://127.0.0.1:9292`（geo-api 默认监听）。服务未运行时给出提示与启动命令。

**示例：**

```bash
# 默认：三接口齐查，文字格式
geo-get 1.181.240.251

# JSON 格式（适合管道处理）
geo-get 8.8.8.8 -j

# 仅查 ASN
geo-get 8.8.8.8 --asn

# 仅查国家，JSON 格式
geo-get 1.1.1.1 --country --json

# 不给 IP，用默认演示 IP
geo-get
```

**文字格式输出示例：**

```
查询 IP: 1.181.240.251    范围: country / city / asn 三接口齐查    服务: http://127.0.0.1:9292
------------------------------------------------------------
1.181.240.251 的归属信息:
  [国家] 中国 (CN)  网段 1.180.0.0/14
  [城市] 未知    坐标 无    网段 1.180.0.0/14
  [ASN]  AS4134 Chinanet    网段 1.180.0.0/15
```

**JSON 格式输出示例：**

```json
{
  "country": { ... },
  "city": { ... },
  "asn": { ... }
}
```

某个接口未命中（404）时，JSON 中对应字段为 `null`，不逐条报错。三个接口全未命中时，文字格式给一行提示。

---

### 完整工作流示例

```bash
# 1. 下载 GeoLite2 CSV 包并解压
cd /data
tar xzf GeoLite2-CSV.zip

# 2. 转换为 JSON（当前目录找 CSV，输出到 ./geodb/）
geo-load

# 3. 启动查询服务
geo-api -d ./geodb -p 9292 &

# 4. 另一个终端查询
geo-get 8.8.8.8
geo-get 1.1.1.1 -j
```

---

## 二、代码级用法

### 1. GeoDB 模块 — CSV 加载（对应 geo-load）

> 源码位置：`service/geodb/geodb.rb`
> 加载方式：`require 'network'` 后 `require 'geodb'`

三个模块方法，各自处理一类数据，均可单独调用：

```ruby
require 'network'
require 'geodb'

# 把 GeoLite2 ASN CSV 转成 asn.json
# 第一个参数: CSV glob 模式 (相对调用目录或绝对路径)
# 第二个参数: 输出目录 (必须以 / 结尾)
GeoDB.load_asn(
  '/data/GeoLite2-ASN-CSV_20260725/*.csv',
  '/var/lib/geodb/'
)

# City: 生成 geo-city.json + city-IPv4.json + city-IPv6.json
# 内部按文件名 Location-zh-CN / Blocks-IPv4 / Blocks-IPv6 分流
GeoDB.load_city(
  '/data/GeoLite2-City-CSV_20260724/*.csv',
  '/var/lib/geodb/'
)

# Country: 生成 geo-country.json + country-IPv4.json + country-IPv6.json
GeoDB.load_country(
  '/data/GeoLite2-Country-CSV_20260724/*.csv',
  '/var/lib/geodb/'
)
```

**方法签名：**

```ruby
GeoDB.load_asn(dir_path, out_path)     →  Hash  { range => record }
GeoDB.load_city(dir_path, out_path)    →  [city_Hash, geo_Hash]
GeoDB.load_country(dir_path, out_path) →  [country_Hash, geo_Hash]
```

**JSON 键格式（范围型）：**

geodb.rb 把 CIDR 通过 `IP.range` 展开为 `[start_num, end_num]`，作为 JSON 的键：

```ruby
# CSV 中的 network 字段 "1.0.4.0/22"
# 转换后 JSON 键为 Ruby 数组序列化字符串:
#   "[16777984, 16778239]"
# 值为原始 CSV 记录 (行头映射的 Hash)
```

**内部实现要点：**

- `Dir[glob]` 匹配 CSV 文件，多个文件依次处理
- `CSV.parse File.read(path)` 读入后用 `table.first` 作表头，`mapping` 方法把每行映射为 `{列名=>值}` 的 Hash
- `IP.range(record['network'])` 把 CIDR 展开为 `[start_ip, end_ip]`，再 `.map(&:number)` 转整数
- City / Country 的 Locations 文件单独提取为 geo 表（按 `geoname_id` 索引），Blocks 文件按 IPv4/IPv6 分两份输出

---

### 2. GeoAPI 服务 — 启动与接口（对应 geo-api）

> 源码位置：`service/geodb/api.rb`
> 加载方式：`require 'network'` 后 `require 'api'`（需把 `service/geodb` 加入 `$LOAD_PATH`）

#### 启动服务

```ruby
require 'network'
$LOAD_PATH.unshift File.join(__dir__, 'service', 'geodb')
require 'api'

ENV['GEODB_DATA_DIR'] = '/var/lib/geodb'  # 指定数据目录

require 'rackup'
Rackup::Server.start(
  app:    GeoAPI.app,
  server: 'puma',
  Host:   '0.0.0.0',
  Port:   9292
)
```

#### GeoDB 模块方法（接口内部逻辑，也可代码调用）

```ruby
# 数据目录 (读 ENV['GEODB_DATA_DIR'], 默认 ./geodb/)
GeoDB.data_dir     # => "/var/lib/geodb/"

# ASN 查询
GeoDB.asn_by_num('13335')      # 该 AS 名下所有地址段 (走反向索引, O(1))
GeoDB.asn_by_addr('1.0.0.5')   # 按 IP 查所属 AS → record 或 nil 或 :invalid

# City 查询
GeoDB.city_by_id('1814991')    # 按 geoname_id 查 → record / nil / :invalid
GeoDB.city_by_addr('1.0.1.1')  # 按 IP 查 → enriched record / nil / :invalid

# Country 查询
GeoDB.country_by_id('6252001')   # 按 geoname_id 查
GeoDB.country_by_addr('1.0.1.1') # 按 IP 查

# 预热 (后台异步加载, 避免首次查询卡顿)
GeoDB.preload('asn', 'country-IPv4', 'country-IPv6')
```

**返回值约定：**

| 场景 | 返回 |
|------|------|
| IP 不合法 | `:invalid` |
| 无结果 | `nil` |
| 命中 | 纯 Record (Hash) 或 enrich 后的 Hash（含 `geoname` / `registered_country` 嵌套对象） |

#### enrich 关联机制

`city_by_addr` / `country_by_addr` 命中后会调用 `enrich`，把范围记录里的三个 geoname_id 外键关联到 geo 表：

```ruby
record = {
  'network' => '1.0.1.0/24',
  'geoname_id' => '1814991',
  'registered_country_geoname_id' => '1814991',
  'represented_country_geoname_id' => nil,
  ...
}

GeoDB.enrich(record, 'geo-city')
# => {
#   ...原字段...,
#   'geoname'              => { geoname_id, country_name, city_name, ... },
#   'registered_country'   => { ... },
#   'represented_country'  => nil
# }
```

#### 加载与缓存机制

- 范围型 JSON（`asn` / `city-IPv4` 等）首次访问时全量加载、按 start 排序、缓存到 `@store`，后续走内存二分
- ASN 额外建 `@asn_index` 反向索引（`as_number → [record...]`），`num` 查询 O(1)
- 地理型 JSON（`geo-city` / `geo-country`）缓存为扁平 Hash，按 `geoname_id` 字符串键取值
- 文件缺失时 `@store[name] = nil`，对应接口返回 404 `无结果`，不影响其他接口

---

### 3. geo-get 的查询逻辑（HTTP 客户端代码）

> 源码位置：`bin/geo-get`
> geo-get 是纯 HTTP 客户端，不加载 GeoDB 模块，不依赖数据文件

```ruby
require 'net/http'
require 'json'

BASE = 'http://127.0.0.1:9292'

# 发起一次 GET, 返回 {code:, body:}
def fetch(base, path, params)
  uri = URI("#{base}#{path}")
  uri.query = URI.encode_www_form(params) unless params.empty?
  res = Net::HTTP.get_response(uri)
  { code: res.code.to_i, body: (JSON.parse(res.body) rescue res.body) }
end

# 三接口齐查
results = {}
results[:country] = fetch(BASE, '/geo/country', addr: '8.8.8.8')
results[:city]    = fetch(BASE, '/geo/city',    addr: '8.8.8.8')
results[:asn]     = fetch(BASE, '/geo/asn',     addr: '8.8.8.8')

# 命中提取
results.each do |key, r|
  puts key if r[:code] == 200
end
```

**查询顺序与错误处理：**

1. 依次（非并行）请求 country → city → asn 三个接口
2. 每个接口返回 200 时收集命中数据，404/400 等静默跳过
3. 三个接口全部未命中时统一输出一行提示，不逐条刷 404
4. 连接被拒（`Errno::ECONNREFUSED`）时直接 abort 并提示启动命令

**文字格式 vs JSON 格式：**

- 文字格式：从响应体中提取关键字段（国家名、城市名、ASN 组织、网段等）拼成可读行
- JSON 格式：把三个接口的响应体原样放进 `{country:, city:, asn:}` 结构，未命中的字段为 `null`，用 `JSON.pretty_generate` 输出
