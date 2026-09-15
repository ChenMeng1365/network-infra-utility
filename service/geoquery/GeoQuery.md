---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'aacf6d8c-3f16-44a6-ad5e-9dec92704459'
  PropagateID: 'aacf6d8c-3f16-44a6-ad5e-9dec92704459'
  ReservedCode1: 'c7410cd1-7a15-4cf5-b8f2-5c2ed30d33f1'
  ReservedCode2: 'c7410cd1-7a15-4cf5-b8f2-5c2ed30d33f1'
---

# GeoQuery 综合查询接口

> 模块目录：`service/geoquery/`  
> 命令行入口：`bin/gen-get`（纯互联网）、`bin/ngeo-get`（缓存 + 本地 + 互联网综合）  
> 设计蓝本：`ip_geo_lookup.py`（多级回退 + 缓存 + 归一化），按"叠加综合"需求重构为 Ruby 实现

## 一、命令总览

| 命令 | 数据源 | 说明 |
|------|--------|------|
| `geo-get` | 本地 geo-api (GeoLite2) | 三接口齐查，纯本地；为 `GeoQuery::LocalClient` 的瘦封装（三接口拉取与汇总逻辑收口在 geoquery）|
| `gen-get` | 互联网 ip-api.com | 免费接口（限 45 req/min，无需 Key） |
| `ngeo-get` | 缓存 + 本地 + 互联网 | 按 `-p` 顺位逐源查询（默认 cache→local→internet），满意即停，字段级叠加 |

三个查询命令共享同一套客户端实现（`GeoQuery::LocalClient` / `GeoQuery::OnlineClient` /
`GeoQuery::GeoCache`），无双实现。

## 二、ngeo-get 查询模型（三源顺位）

```
1. 会话缓存 (ngeo-cache.json) 命中 → 直接返回
2. 按 -p 顺位逐源查询 (默认 cache → local → internet):
     cache    GEO_CACHE 外带缓存目录 (geocacheYYYYMMDD.json, -a 指定)
     local    本地 geo-api 服务 (GeoLite2)
     internet 互联网 ip-api.com (限速 + 熔断保护)
3. 每源结果按顺位折叠: 先查的源字段优先, 后查的补空缺
4. 折叠后归属满意 (省/市/ASN 齐全) → 提前终止, 不再查后续源
5. 全部源查完仍不满意 → 组装终态 (叠加/部分/空/不可达)
```

### 结果状态 (state) 可信度排序

**`unreachable` < `local-partial` < `cache-partial` < `empty` < `cache` < `local` < `online` < `merged`**

| state | 含义 | 触发条件 |
|-------|------|----------|
| `unreachable` | 各源均无结果且有不联通 (最低) | 本地无结果 + 互联网不可达 + 缓存未命中 |
| `local-partial` | 本地部分结果 | 本地归属不满意 + 其余源无补充，保留本地字段 |
| `cache-partial` | 缓存部分结果 | 缓存归属不满意 + 其余源无补充，保留缓存字段 |
| `empty` | 各源均确认无归属 | 如私有/保留地址 (ip-api 返回 `private range`) |
| `cache` | 缓存命中且满意 | GEO_CACHE 内记录省市 ASN 齐全 |
| `local` | 本地结果满意 | 省/市/ASN 齐全，无需互联网 |
| `online` | 纯互联网结果 | 本地无结果或 geo-api 未启动，互联网查询成功 |
| `merged` | 多源叠加综合 (最高) | 缓存/本地部分结果 + 互联网或其他源补全，字段级择优 |

### 字段叠加规则 (Merge)

重点准确字段：**省 (Province) / 城市 (City) / 用途 (IDC、云)**，越准确越好。
按顺位折叠：先查的源为 base，后查的源为 supp。

| 字段 | 择优规则 |
|------|----------|
| country / province / city / asn / asn_org | base 优先，base 空取 supp (GeoLite2 网段级数据有值时可信；本地省市缺失率高，由 ip-api.com / GEO_CACHE 补全) |
| network (网段 CIDR) | base 优先，base 空取 supp (互联网源无网段，实际补给来自本地库与缓存) |
| isp | 按合并后的 asn_org 重新归一化 (长名 → 电信/联通/移动/腾讯云… 简称) |
| usage | 两方组织名综合推断: 云 / IDC / CDN / 教育网 / 运营商 / 企业 / 未知 |

## 三、GEO_CACHE 外带缓存

ngeo-get 与 geo-api 均可外带一个缓存目录，目录内的定位信息作为缓存数据源。

### 3.1 格式

```sh
# 服务器端: GEO_CACHE 内的缓存定位信息作为 addr 查询兑底
geo-api -d GEODB_PATH -a GEO_CACHE

# 客户端: 查询时缓存目录数据纳入备选
ngeo-get X.X.X.X -a GEO_CACHE
```

缓存文件为 `geocacheYYYYMMDD.json`（XXXXXXXX 为 8 位日期时间标签），
内容与 `ngeo-cache.json` 同构：`{ "ip" => { 统一 schema 结果, "ts" => 时间戳 } }`。
目录内文件增删改自动感知，无需重启；多文件同 IP 冲突取 `ts` 最新。

### 3.2 顺位 (-p)

`-p` 决定本地库 (local) / 互联网库 (internet) / 缓存库 (cache) 的适用顺序：

```sh
ngeo-get X.X.X.X -a GEO_CACHE -p local,internet,cache  # 本地优先, 互联网次之, 缓存兑底
ngeo-get X.X.X.X -a GEO_CACHE                          # 默认 -p cache,local,internet
```

| 顺位 | 语义 |
|------|------|
| `cache,local,internet` (默认) | 优先缓存 → 本地库 → 互联网 |
| `local,internet,cache` | 本地优先，本地查不到才找互联网，互联网查不到或不通再查缓存 |

顺位即优先级：先查的源字段优先，后查的补空缺；折叠后满意 (省/市/ASN 齐全)
即停，不再查后续源。源不可用自动跳过（无 `-a` 时 cache 源不存在；
`--refresh` 跳过全部缓存；`--no-local` 跳过本地）。

服务端 `geo-api` 的顺位参数为 `--priority`（`-p` 已被端口占用），
仅支持 `local,cache` 排列，默认 `local,cache`。

### 3.3 产出 (-c / -nc)

每次查询的结果默认保存下来用于后续缓存：

```sh
ngeo-get 1.2.3.4 -a GEO_CACHE     # 查询结果默认保存到 GEO_CACHE/geocacheYYYYMMDD.json
ngeo-get 1.2.3.4 -a GEO_CACHE -nc # 不保存产出
```

- 保存位置：`-a` 指定的目录；未指定时为当前目录（可用环境变量 `GEO_CACHE_DIR` 覆盖）
- 命名：`geocacheYYYYMMDD.json`，同一天多次查询自动归并到同一文件，同 IP 以新结果覆盖
- 仅保存可缓存状态 (`local` / `merged` / `online` / `empty` / `cache`)；
  `unreachable` / `local-partial` / `cache-partial` 不落盘（下次重查自动补全）
- `-c` 为默认行为（显式指定等效），`-nc` 关闭

### 3.4 整理 (-m)

```sh
ngeo-get -m GEO_CACHE
# 合并完成: 3 个缓存文件 → 128 条记录
# 输出文件: /path/GEO_CACHE/geocacheYYYYMMDD.json (生成时间为时间标签)
```

将 GEO_CACHE 目录下所有 `geocacheYYYYMMDD.json` 格式的数据合并，生成一个新的
`geocacheYYYYMMDD.json`（新生成时间为合并生成时间），同 IP 冲突取 `ts` 最新。
源文件保留不删除，重复执行幂等。

## 四、gen-get 接口与参数

默认调用 ip-api.com 免费接口（与 `ip_geo_lookup.py` 的默认配置一致，`message` 字段为诊断扩展）：

```
http://ip-api.com/json/{ip}?lang=zh-CN&fields=status,message,country,regionName,city,isp,as,query
```

| gen-get state | 触发条件 | 缓存 |
|---------------|----------|------|
| `ok` | `status: success` | 落盘 |
| `empty` | `status: fail` (如私有地址 `private range`) | 落盘 |
| `unreachable` | 网络异常 / 超时 / HTTP 429 限速 / 非 200 | 不落盘 (下次重试) |
| `invalid` | IP 参数不合法 | 不落盘 |

内置限速：两次请求间隔 ≥ 1.4s（对齐 45 req/min 免费限额）；`--timeout` 控制连接/读取超时（默认 10s）。

## 五、命令行用法

```sh
# gen-get — 互联网查询
gen-get 8.8.8.8                     # 文字格式
gen-get 8.8.8.8 -j                  # JSON 格式
gen-get 1.1.1.1 8.8.8.8            # 多 IP (自动限速)
cat ips.txt | gen-get -j            # stdin 逐行读 IP
gen-get 8.8.8.8 --refresh           # 忽略缓存强刷
gen-get --cache-stats               # 缓存统计

# ngeo-get — 综合查询 (三源顺位)
ngeo-get 111.8.44.6                 # 默认顺位 cache,local,internet
ngeo-get 111.8.44.6 -j              # JSON
ngeo-get 111.8.44.6 -a ./GEO_CACHE  # 外带缓存目录
ngeo-get 111.8.44.6 -p local,internet,cache -a ./GEO_CACHE   # 本地优先, 缓存兑底
ngeo-get 111.8.44.6 -nc             # 查询但不产出缓存文件
ngeo-get -m ./GEO_CACHE             # 合并目录下全部 geocache*.json
ngeo-get 111.8.44.6 --no-local      # 跳过本地, 仅互联网
ngeo-get 111.8.44.6 --geoapi http://127.0.0.1:9292   # 覆盖本地服务地址
ngeo-get 111.8.44.6 --api "http://ip-api.com/json/{ip}?lang=zh-CN&fields=..."  # 覆盖互联网接口
ngeo-get --cache-stats               # 会话缓存统计 (-a 时附加 GEO_CACHE 统计)
```

退出码：`0` 查询完成（含 `empty` / `local-partial` / `cache-partial`）；`1` IP 不合法或参数错误；`2` 互联网不可达（且其余源无结果）。

## 六、结果 schema（ngeo-get -j）

```json
{
  "ip": "111.8.44.6",
  "state": "merged",
  "message": "",
  "country": "中国",
  "province": "湖南",
  "city": "青园",
  "isp": "移动",
  "asn": "56047",
  "asn_org": "China Mobile communications corporation",
  "network": "111.8.0.0/15",
  "usage": "运营商",
  "source": "ngeo(geo-get+gen-get)",
  "sources": {
    "cache":  { "state": "miss", "message": "GEO_CACHE 缓存未命中" },
    "local":  { "state": "ok", "verdict": "不满意" },
    "online": { "state": "ok" }
  },
  "ts": 1789370023
}
```

`sources` 键：`cache` / `local` / `online`，未参与查询的源标 `skipped`；
`source` 字段按参与叠加的源组合，如 `ngeo(geo-cache+geo-get)`。

## 七、测试用例

### 7.1 ngeo-get 状态机

| # | 命令 | 预期结果 |
|---|------|----------|
| 7.1.1 | `ngeo-get 219.140.0.1 -j` | `state: local`（本地省市 ASN 齐全，`online: skipped`） |
| 7.1.2 | `ngeo-get 111.8.44.6 -j` | `state: merged`，省/市来自互联网，`network` 保留本地网段 |
| 7.1.3 | `ngeo-get 219.140.0.1 --geoapi http://127.0.0.1:9999 -j` | `state: online`（本地不可用，纯互联网） |
| 7.1.4 | `ngeo-get 111.8.44.6 --api http://192.0.2.1/x/{ip} --timeout 2` | `state: local-partial`，message 含"互联网查询不可达"，本地 ASN/网段保留 |
| 7.1.5 | `ngeo-get 10.20.30.40 --api http://192.0.2.1/x/{ip} --timeout 2 -j` | `state: unreachable`，全部字段为空，退出码 2 |
| 7.1.6 | `ngeo-get 10.20.30.40 -j` | `state: empty`（`private range`） |
| 7.1.7 | `ngeo-get 999.1.1.1 -j` | `state: invalid`，退出码 1 |
| 7.1.8 | 连续查询同一 IP 两次 | 第二次 `cached: true`（JSON）或"缓存命中"（文字） |

### 7.2 gen-get

| # | 命令 | 预期结果 |
|---|------|----------|
| 7.2.1 | `gen-get 8.8.8.8` | `state: ok`，国家/省/市/ASN 齐全，`usage: 云` |
| 7.2.2 | `gen-get 10.20.30.40 -j` | `state: empty`，message 为 `private range` |
| 7.2.3 | `gen-get 8.8.8.8 --api http://192.0.2.1/x/{ip} --timeout 2` | `state: unreachable`，退出码 2 |
| 7.2.4 | `echo 8.8.4.4 \| gen-get -j` | stdin 输入，正常查询 |

### 7.3 GEO_CACHE 外带缓存

预置 `./GEO_CACHE/geocache20260101.json` 含某本地库没有的 IP（如 `203.0.113.7`）的完整定位记录。

| # | 命令 | 预期结果 |
|---|------|----------|
| 7.3.1 | `ngeo-get 203.0.113.7 -a ./GEO_CACHE -j` | `state: cache`，`cached: true`，`sources.local/online: skipped`（默认顺位缓存命中） |
| 7.3.2 | `ngeo-get 203.0.113.7 -p local,internet,cache -a ./GEO_CACHE --api http://192.0.2.1/x/{ip} --timeout 2 -j` | local 空 + internet 不通 + 缓存兑底，`state: cache` |
| 7.3.3 | `ngeo-get 203.0.113.7 -a ./GEO_CACHE -nc -j` | 查询正常，不修改产出文件（`-nc`） |
| 7.3.4 | `ngeo-get 1.2.3.4 -a ./GEO_CACHE -j` | 查询后 `./GEO_CACHE/geocacheYYYYMMDD.json` 生成，含本次结果 |
| 7.3.5 | `ngeo-get -m ./GEO_CACHE` | 合并目录内全部 geocache 文件，输出新文件，退出码 0 |
| 7.3.6 | `ngeo-get 1.2.3.4 -p bogus -j` | 报"无效顺位"退出码 1 |
| 7.3.7 | `geo-api -d ./geodb -a ./GEO_CACHE` 后 `curl "localhost:9292/geo/city?addr=203.0.113.7"` | 200，缓存兑底，`cached: true`（详见 GeoAPI.md 第 7 节） |

## 八、缓存与配置

| 项 | 说明 |
|----|------|
| 会话缓存目录 | `ENV["NGEO_CACHE_DIR"]`，默认 `~/.network-infra-utility/` |
| 会话缓存文件 | `gen-cache.json`（gen-get 互联网层）/ `ngeo-cache.json`（ngeo 综合层） |
| 会话缓存策略 | `local` / `merged` / `online` / `empty` / `cache` 落盘；`unreachable` / `local-partial` / `cache-partial` 不落盘（下次重查，互联网恢复后自动补全）；`--refresh` 强制重查 |
| GEO_CACHE 外带缓存 | `-a DIR` 指定；产出目录未指定时 `ENV["GEO_CACHE_DIR"]` > 当前目录 |
| GEO_CACHE 产出 | `-c` 默认开启：结果写入 `geocacheYYYYMMDD.json`；`-nc` 关闭 |
| GEO_CACHE 整理 | `-m DIR` 合并目录内全部缓存文件为新文件 |
| 本地服务地址 | `--geoapi` 或 `ENV["GEO_API_BASE"]`，默认 `http://127.0.0.1:9292` |
| 互联网接口 | `--api`（`{ip}` 占位符），默认 ip-api.com 免费接口 |
| 熔断 | 连续 3 次互联网不可达后，60s 内跳过在线查询直接返回 unreachable |

## 九、代码级用法

```ruby
require "geoquery/geoquery"   # gem 安装后 (require_paths 含 service/)

# 纯互联网
online = GeoQuery::OnlineClient.new(timeout: 10)
r = online.lookup("8.8.8.8")          # → state: ok/empty/unreachable/invalid

# 本地原始接口查询 (bin/geo-get 底座)
local = GeoQuery::LocalClient.new     # base 默认 9292 (geo-get 另支持 ENV["GEO_API_BASE"])
raw = local.fetch_raw("8.8.8.8")      # → { country: body|nil, city: body|nil, asn: body|nil }
raw = local.fetch_raw("8.8.8.8", endpoints: %i[asn])  # → 单接口子集
# fetch_raw 返回 :unreachable 表示 geo-api 服务不可达

# 本地归一化查询 (ngeo 内部同款)
r = local.lookup("8.8.8.8")           # → 统一 schema, state: ok/empty/unavailable/invalid

# 综合 (三源顺位, 默认 cache,local,internet)
ngeo = GeoQuery::NGeo.new(geo_cache_dir: "./GEO_CACHE")   # -a 外带缓存
r = ngeo.lookup("111.8.44.6")         # → 统一 schema (见第六节)
ngeo.lookup("1.2.3.4", refresh: true, no_local: false)
ngeo.save_cache

# 顺位自定义 (等效 -p)
ngeo = GeoQuery::NGeo.new(geo_cache_dir: "./GEO_CACHE",
                          order: "local,internet,cache")

# GEO_CACHE 外带缓存 (service/geoquery/geo_cache.rb)
gc = GeoQuery::GeoCache.new("./GEO_CACHE")
gc.lookup("8.8.8.8")                  # → 缓存记录 (附加 cached: true) 或 nil
gc.put_batch([{ "ip" => "8.8.8.8", "state" => "merged", ... }])  # 产出
gc.merge!                             # → { "files" =>, "entries" =>, "output" => }
GeoQuery::GeoCache.parse_order("cache,local,internet")  # → 顺位数组或 nil
GeoQuery::GeoCache.to_geolite(:city, hit)  # 统一 schema → GeoLite2 风格 (服务端兑底)

# 归一化工具
GeoQuery::Normalize.isp_from_asn("CHINATELECOM Hubei province 5G network")  # => "电信"
GeoQuery::Normalize.usage_from_asn("Tencent cloud")                         # => "云"
GeoQuery::Merge.fields(local_result, online_result)                         # => 字段叠加
```

## 备注

1. **gen-get 的 `unreachable` 语义**：表示"互联网查询不可达"（网络不通/超时/限速），区别于 `empty`（互联网确认无归属，如私有地址）。不可达结果不缓存，恢复后重查即可。
2. **`local-partial` / `cache-partial` 的取舍**：互联网不可达时，本地/缓存的部分结果（如 ASN/网段）仍有价值，予以保留并标注；完全无数据时才降级为 `unreachable` 空状态。
3. **本地 geo-api 未启动**：ngeo-get 不视为错误（`local: unavailable`），自动走纯互联网路径，返回 `state: online`；geo-get 则直接报错并提示启动命令（可用 `GEO_API_BASE` 环境变量覆盖服务地址）。
4. **ip-api.com 免费接口限制**：45 req/min、仅 HTTP（无 HTTPS）、仅限自用。批量场景已内置 1.4s 最小间隔；更高需求可 `--api` 切换付费批量接口（pro.ip-api.com）。
5. **GEO_CACHE 与会话缓存的分工**：`ngeo-cache.json` 是进程自动维护的会话缓存（命中直接返回，不参与 `-p` 顺位）；GEO_CACHE 是用户显式外带的缓存目录（作为顺位中的 `cache` 数据源，产出可拷贝/合并/供服务端兑底）。`--refresh` 两者均跳过。
6. **服务端顺位参数为何是 `--priority`**：`geo-api -p` 已被监听端口占用，故服务端顺位用 `--priority`（仅 `local,cache` 排列）；客户端 `ngeo-get -p` 无冲突，支持三源排列。

> AI生成