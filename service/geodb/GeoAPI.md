# GeoAPI 测试用例

> 接口服务文件：`api.rb`  
> 默认地址：`http://localhost:9292`（实际使用时替换 `localhost:9292` 为你的 `HOST:PORT`）  

## 返回约定

| 状态码 | 含义 | 响应体 |
|--------|------|--------|
| 200 | 成功 | 各接口对应的数据结构 |
| 400 | 参数不合法 | `{"error":"IP不合法"}` / `{"error":"id不合法"}` / `{"error":"缺少参数 ..."}` |
| 404 | 无结果 | `{"error":"无结果"}` |

IP 合法性说明：含 `:` 按 IPv6 解析，否则按 IPv4 解析；非法地址统一返回 `IP不合法`。

---

## (1) ASN — `/geo/asn`

### 1.1 `num` 查询（按 ASN 编号查所有地址段）

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 1.1.1 | `curl -s "localhost:9292/geo/asn?num=13335"` | 200，`asn:"13335"`，`count:2480`，含 `1.0.0.0/24`、`1.1.1.0/24` 等（Cloudflare）|
| 1.1.2 | `curl -s "localhost:9292/geo/asn?num=38803"` | 200，含 `1.0.4.0/22`（Gtelecom）|
| 1.1.3 | `curl -s "localhost:9292/geo/asn?num=999999999"` | 200，`count:0`，`results:[]`（无此 ASN）|
| 1.1.4 | `curl -s "localhost:9292/geo/asn?num=abc"` | 200，`count:0`，`results:[]`（非数字按空结果返回）|

### 1.2 `addr` 查询（按 IP 查所属 AS）

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 1.2.1 | `curl -s "localhost:9292/geo/asn?addr=1.0.0.5"` | 200，`network:"1.0.0.0/24"`，`autonomous_system_number:"13335"` |
| 1.2.2 | `curl -s "localhost:9292/geo/asn?addr=2606:4700:4700::1111"` | 200，命中 Cloudflare AS13335 的 IPv6 段 |
| 1.2.3 | `curl -s "localhost:9292/geo/asn?addr=0.0.0.0"` | 404，`{"error":"无结果"}` |
| 1.2.4 | `curl -s "localhost:9292/geo/asn?addr=999.1.1.1"` | 400，`{"error":"IP不合法"}` |
| 1.2.5 | `curl -s "localhost:9292/geo/asn?addr=nonip"` | 400，`{"error":"IP不合法"}` |

### 1.3 缺参

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 1.3.1 | `curl -s "localhost:9292/geo/asn"` | 400，`{"error":"缺少参数 num 或 addr"}` |

---

## (2) City — `/geo/city?id=`

### 2.1 id 命中

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 2.1.1 | `curl -s "localhost:9292/geo/city?id=11797"` | 200，伊朗（`country_iso_code:"IR"`，`time_zone:"Asia/Tehran"`）|
| 2.1.2 | `curl -s "localhost:9292/geo/city?id=1814991"` | 200，中国（`country_iso_code:"CN"`，`time_zone:"Asia/Shanghai"`）|

### 2.2 id 不合法

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 2.2.1 | `curl -s "localhost:9292/geo/city?id=abc"` | 400，`{"error":"id不合法"}` |
| 2.2.2 | `curl -s "localhost:9292/geo/city?id=12a3"` | 400，`{"error":"id不合法"}` |
| 2.2.3 | `curl -s "localhost:9292/geo/city?id="` | 400，`{"error":"id不合法"}`（空串不匹配 `\d+`）|

### 2.3 id 无结果

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 2.3.1 | `curl -s "localhost:9292/geo/city?id=999999999"` | 404，`{"error":"无结果"}` |

---

## (3) City — `/geo/city?addr=`

### 3.1 IPv4 查询

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 3.1.1 | `curl -s "localhost:9292/geo/city?addr=1.0.1.1"` | 200，`network:"1.0.1.0/24"`，`geoname` 嵌套"中国"，含 lat/lng/accuracy_radius |
| 3.1.2 | `curl -s "localhost:9292/geo/city?addr=1.0.0.5"` | 200，`1.0.0.0/24`，`geoname_id:null`→`geoname:null`，`registered_country` 关联出注册国 |
| 3.1.3 | `curl -s "localhost:9292/geo/city?addr=0.0.0.0"` | 404，`{"error":"无结果"}` |
| 3.1.4 | `curl -s "localhost:9292/geo/city?addr=999.1.1.1"` | 400，`{"error":"IP不合法"}` |

### 3.2 IPv6 查询

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 3.2.1 | `curl -s "localhost:9292/geo/city?addr=2606:4700:4700::1111"` | 200，命中 Cloudflare IPv6 段，`registered_country` 关联"美国"（US），`geoname`:null |

### 3.3 缺参

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 3.3.1 | `curl -s "localhost:9292/geo/city"` | 400，`{"error":"缺少参数 id 或 addr"}` |

---

## (4) Country — `/geo/country?id=`

### 4.1 id 命中

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 4.1.1 | `curl -s "localhost:9292/geo/country?id=49518"` | 200，`country_iso_code:"RW"`，`country_name:"卢旺达"` |
| 4.1.2 | `curl -s "localhost:9292/geo/country?id=6252001"` | 200，`country_iso_code:"US"`，`country_name:"美国"` |
| 4.1.3 | `curl -s "localhost:9292/geo/country?id=1814991"` | 200，`country_iso_code:"CN"`，`country_name:"中国"` |

### 4.2 id 不合法

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 4.2.1 | `curl -s "localhost:9292/geo/country?id=abc"` | 400，`{"error":"id不合法"}` |
| 4.2.2 | `curl -s "localhost:9292/geo/country?id=12.3"` | 400，`{"error":"id不合法"}` |
| 4.2.3 | `curl -s "localhost:9292/geo/country?id="` | 400，`{"error":"id不合法"}` |

### 4.3 id 无结果

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 4.3.1 | `curl -s "localhost:9292/geo/country?id=1"` | 404，`{"error":"无结果"}` |

---

## (5) Country — `/geo/country?addr=`

### 5.1 IPv4 命中

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 5.1.1 | `curl -s "localhost:9292/geo/country?addr=1.0.1.1"` | 200，`network:"1.0.1.0/24"`，`geoname`+`registered_country` 均关联"中国" |

### 5.2 IPv6 命中

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 5.2.1 | `curl -s "localhost:9292/geo/country?addr=2606:4700:4700::1111"` | 200，`network:"2606:4700:4700::/48"`，`registered_country`="美国"（US），`geoname`:null |
| 5.2.2 | `curl -s "localhost:9292/geo/country?addr=2001:200::1"` | 200，`network:"2001:200::/32"`，`geoname`+`registered_country`="日本"（JP）|

### 5.3 无结果

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 5.3.1 | `curl -s "localhost:9292/geo/country?addr=::1"` | 404，`{"error":"无结果"}` |
| 5.3.2 | `curl -s "localhost:9292/geo/country?addr=0.0.0.0"` | 404，`{"error":"无结果"}` |

### 5.4 IP 不合法

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 5.4.1 | `curl -s "localhost:9292/geo/country?addr=gggg::1"` | 400，`{"error":"IP不合法"}` |
| 5.4.2 | `curl -s "localhost:9292/geo/country?addr=nonip"` | 400，`{"error":"IP不合法"}` |

### 5.5 容错与缺参

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 5.5.1 | `curl -s "localhost:9292/geo/country?addr=%201.0.1.1"` | 200，命中"中国"（strip 容错）|
| 5.5.2 | `curl -s "localhost:9292/geo/country"` | 400，`{"error":"缺少参数 id 或 addr"}` |

---

## 附：响应结构示例

### ASN `num` 成功响应
```json
{
  "asn": "13335",
  "count": 2480,
  "results": [
    {
      "network": "1.0.0.0/24",
      "autonomous_system_number": "13335",
      "autonomous_system_organization": "Cloudflare, Inc."
    }
  ]
}
```

### ASN `addr` / IP 查所属 AS
```json
{
  "network": "1.0.0.0/24",
  "autonomous_system_number": "13335",
  "autonomous_system_organization": "Cloudflare, Inc."
}
```

### City / Country `addr` 成功响应（含 geo 关联）
```json
{
  "network": "1.0.1.0/24",
  "geoname_id": "1814991",
  "registered_country_geoname_id": "1814991",
  "represented_country_geoname_id": null,
  "is_anonymous_proxy": "0",
  "is_satellite_provider": "0",
  "is_anycast": null,
  "geoname": {
    "geoname_id": "1814991",
    "locale_code": "zh-CN",
    "continent_code": "AS",
    "continent_name": "亚洲",
    "country_iso_code": "CN",
    "country_name": "中国",
    "is_in_european_union": "0"
  },
  "registered_country": {
    "geoname_id": "1814991",
    "locale_code": "zh-CN",
    "continent_code": "AS",
    "continent_name": "亚洲",
    "country_iso_code": "CN",
    "country_name": "中国",
    "is_in_european_union": "0"
  },
  "represented_country": null
}
```

---

## (7) 兑底机制：GEO_CACHE 缓存与互联网 — `geo-api -a` / `--priority`

服务端以 `geo-api -d GEODB_PATH -a GEO_CACHE [--priority local,cache,online]` 启动后，
`addr` 类查询按顺位编排：先查本地 GeoLite2 库，再用 GEO_CACHE 目录内
`geocacheYYYYMMDD.json`（`ngeo-get -c` 产出）的缓存定位信息兑底，最后由互联网
（百度智能IP定位 → ip-api.com 链式）兜底。后两者统一 schema 转换为各接口的
GeoLite2 风格响应，分别附加 `"cached": true` / `"online": true` 标记。

**字段完整即停**：本地库常见"有网段但无省市"的记录（如 60.188.0.0/15 仅命中
国家），此时不视为命中，继续后续源兑底（百度智能IP定位可补齐省市）；各源均
不完整时返回首个有结果者（部分结果优于无结果）。`id` / `num` 类查询不适用
兑底（非 IP 键）。目录内文件增删改自动感知，无需重启。

互联网兑底说明：

- 链式：百度智能IP定位（qifu.baidu.com，国内省市/运营商/场景准）→ ip-api.com
  （百度查不出来才用，补 ASN 与国外城市）；
- 限速与熔断：每接口独立（百度 1 QPS / ip-api.com 45 req/min；连续 3 次不可达
  暂停 60s），多线程安全不阻塞（HTTP 在限速锁外执行）；
- asn 接口兑底直查 ip-api.com（百度无 ASN 数据）；
- 超时默认 8s（`--online-timeout` / `GEODB_ONLINE_TIMEOUT` 覆盖），服务端响应
  不宜久等；
- 离线环境用 `--priority local,cache` 关闭互联网兑底。

### 7.1 启动与根路由

| # | 命令 | 预期结果 |
|---|------|----------|
| 7.1.1 | `geo-api -d ./geodb -a ./GEO_CACHE` | 启动横幅显示缓存目录与文件数、查询顺位 `local,cache,online` 与互联网兑底信息 |
| 7.1.2 | `curl -s "localhost:9292/"` | 200，含 `cache_dir`、`cache_order:"local,cache,online"` 与 `online` 链路说明 |
| 7.1.3 | `geo-api -a ./不存在的目录` | 警告但继续启动（目录后续创建自动感知） |
| 7.1.4 | `geo-api --priority cache,local` | 兑底顺位改为缓存优先，无互联网兑底 |
| 7.1.5 | `geo-api --priority local,cache,online --online-timeout 5` | 互联网兑底超时改为 5s |

### 7.2 兑底查询

预置 `GEO_CACHE/geocache20260101.json`：

```json
{ "203.0.113.7": { "state": "local", "country": "中国", "province": "浙江",
  "city": "杭州", "asn": "4134", "asn_org": "Chinanet",
  "network": "203.0.113.0/24", "ts": 100 } }
```

| # | curl 命令 | 预期结果 |
|---|-----------|----------|
| 7.2.1 | `curl -s "localhost:9292/geo/city?addr=203.0.113.7"` | 200，`geoname.subdivision_1_name:"浙江"`、`geoname.city_namezh:"杭州"`、`cached:true`（本地库无此 TEST-NET-3 地址，走缓存兑底）|
| 7.2.2 | `curl -s "localhost:9292/geo/asn?addr=203.0.113.7"` | 200，`autonomous_system_number:"4134"`、`cached:true` |
| 7.2.3 | `curl -s "localhost:9292/geo/country?addr=203.0.113.7"` | 200，`geoname.country_name:"中国"`、`cached:true` |
| 7.2.4 | `curl -s "localhost:9292/geo/asn?addr=8.8.8.8"` | 200，Google LLC，**无** `cached` 字段（本地库命中，不走缓存，local 优先）|
| 7.2.5 | 缓存记录 `state:"empty"` 的 IP 查 city | 404（缓存确认无归属，无兑底数据）|
| 7.2.6 | 缓存记录无 `asn` 字段的 IP 查 asn | 404（对应字段缺失，该接口无数据）|
| 7.2.7 | `curl -s "localhost:9292/geo/city?addr=60.188.84.0"`（无缓存时） | 200，`geoname.subdivision_1_name:"浙江省"`、`online:true`（本地库仅命中网段无省市 → 互联网兑底，百度补齐）|
| 7.2.8 | 无缓存目录启动时查本地库缺失的 IP | 互联网兑底（`online:true`）或 404（互联网也无归属）|

### 7.3 兑底响应结构

缓存命中（`cached:true`，与互联网兑底同构）：

```json
{
  "network": "203.0.113.0/24",
  "geoname": { "country_name": "中国", "subdivision_1_name": "浙江", "city_namezh": "杭州" },
  "cached": true
}
```

互联网兑底（`online:true`，network 为空——互联网源不提供网段）：

```json
{
  "network": "",
  "geoname": { "country_name": "中国", "subdivision_1_name": "浙江省", "city_namezh": "金华市" },
  "online": true
}
```

---

## 备注

1. **ASN 的 `num` 非数字**：需求第(1)点只要求 city/country 的 id 做数字校验，未规定 asn 的 num。当前实现在 `num=abc` 时返回 `count:0`（空结果，状态 200）。如需返回 `400 ASN编号不合法`，可在 `api.rb` 中加一行校验。

2. **city-IPv6.json**：当前 `geodb/` 目录下已生成此文件，IPv6 city 查询可正常命中。文件缺失时服务端会容错返回 `无结果`（404），不影响其他接口。

3. **加载耗时（首次，含 JSON 解析）**：asn 约 3.5s / country-IPv4 约 2.9s / country-IPv6 约 3.6s / city-IPv4 约 22.8s，之后常驻内存走缓存，查询耗时约 0ms。

4. **GEO_CACHE 与服务端缓存（`@store`）的区别**：`@store` 是数据文件加载内存缓存（进程内常驻）；GEO_CACHE 是外带定位信息缓存目录（ngeo-get 产出的查询结果），用于 addr 查询兜底，两者互不影响。

5. **geo-api 的顺位参数是 `--priority`**（不是 `-p`）：`-p` 已被监听端口占用。服务端支持 `local,cache,online` 排列（默认 `local,cache,online`，含互联网兑底）；客户端 `ngeo-get -p` 支持 `cache,local,internet` 三源排列。
6. **互联网兑底的请求开销**：兑底仅在本地库与 GEO_CACHE 均无完整结果时触发；百度接口限速 1 QPS，并发未命中查询按序排队（实测 4 线程并发约 3~4s 全部返回，互不阻塞）。服务端不产出 GEO_CACHE（产出由客户端 ngeo-get 负责，产出后可经 `-a` 供服务端兑底复用）。
