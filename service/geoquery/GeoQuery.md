---
AIGC:
  ContentProducer: '001191110102MAD55U9H0F10002'
  ContentPropagator: '001191110102MAD55U9H0F10002'
  Label: '1'
  ProduceID: 'e59331b0-4f63-4be7-b8b5-599344ba18fa'
  PropagateID: 'e59331b0-4f63-4be7-b8b5-599344ba18fa'
  ReservedCode1: 'cf064bd5-6507-42df-811c-57fc0e687f73'
  ReservedCode2: 'cf064bd5-6507-42df-811c-57fc0e687f73'
---

# GeoQuery 综合查询接口

> 模块目录：`service/geoquery/`  
> 命令行入口：`bin/gen-get`（纯互联网）、`bin/ngeo-get`（本地 + 互联网综合）  
> 设计蓝本：`ip_geo_lookup.py`（多级回退 + 缓存 + 归一化），按"叠加综合"需求重构为 Ruby 实现

## 一、命令总览

| 命令 | 数据源 | 说明 |
|------|--------|------|
| `geo-get` | 本地 geo-api (GeoLite2) | 三接口齐查，纯本地；为 `GeoQuery::LocalClient` 的瘦封装（三接口拉取与汇总逻辑收口在 geoquery）|
| `gen-get` | 互联网 ip-api.com | 免费接口（限 45 req/min，无需 Key） |
| `ngeo-get` | 本地 + 互联网 | geo-get 优先，归属不满意时补 gen-get，字段级叠加 |

三个查询命令共享同一套客户端实现（`GeoQuery::LocalClient` / `GeoQuery::OnlineClient`），无双实现。

## 二、ngeo-get 查询模型

```
1. 缓存命中 → 直接返回
2. 本地 geo-api 可用 → 使用 geo-get 数据源查询
3. 归属满意 (省 / 市 / ASN 齐全) → 直接采用本地结果
4. 归属不满意 → 调 gen-get (ip-api.com) 补互联网结果
5. 互联网不通 → 标注"互联网查询不可达"; 本地部分结果仍然保留
```

### 结果状态 (state) 可信度排序

**`unreachable` < `local-partial` < `empty` < `local` < `online` < `merged`**

| state | 含义 | 触发条件 |
|-------|------|----------|
| `unreachable` | 互联网查询不可达空结果状态 (最低) | 本地无可用结果 + 互联网不通 |
| `local-partial` | 本地部分结果 | 本地归属不满意 + 互联网不可达/无补充，保留本地字段 |
| `empty` | 两方均确认无归属 | 如私有/保留地址 (ip-api 返回 `private range`) |
| `local` | 本地结果满意 | 省/市/ASN 齐全，无需互联网 |
| `online` | 纯互联网结果 | 本地无结果或 geo-api 未启动，互联网查询成功 |
| `merged` | 本地 + 互联网叠加综合 (最高) | 本地部分结果 + 互联网补全，字段级择优 |

### 字段叠加规则 (Merge)

重点准确字段：**省 (Province) / 城市 (City) / 用途 (IDC、云)**，越准确越好。

| 字段 | 择优规则 |
|------|----------|
| country / province / city / asn / asn_org | 本地优先，本地空取互联网 (GeoLite2 网段级数据有值时可信；本地省市缺失率高，由 ip-api.com 补全) |
| network (网段 CIDR) | 仅本地有，原样保留 |
| isp | 按合并后的 asn_org 重新归一化 (长名 → 电信/联通/移动/腾讯云… 简称) |
| usage | 两方组织名综合推断: 云 / IDC / CDN / 教育网 / 运营商 / 企业 / 未知 |

## 三、gen-get 接口与参数

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

## 四、命令行用法

```sh
# gen-get — 互联网查询
gen-get 8.8.8.8                     # 文字格式
gen-get 8.8.8.8 -j                  # JSON 格式
gen-get 1.1.1.1 8.8.8.8            # 多 IP (自动限速)
cat ips.txt | gen-get -j            # stdin 逐行读 IP
gen-get 8.8.8.8 --refresh           # 忽略缓存强刷
gen-get --cache-stats               # 缓存统计

# ngeo-get — 综合查询
ngeo-get 111.8.44.6                 # 本地优先 → 不满意补互联网
ngeo-get 111.8.44.6 -j              # JSON
ngeo-get 111.8.44.6 --no-local      # 跳过本地, 仅互联网
ngeo-get 111.8.44.6 --geoapi http://127.0.0.1:9292   # 覆盖本地服务地址
ngeo-get 111.8.44.6 --api "http://ip-api.com/json/{ip}?lang=zh-CN&fields=..."  # 覆盖互联网接口
ngeo-get --cache-stats
```

退出码：`0` 查询完成（含 `empty` / `local-partial`）；`1` IP 不合法；`2` 互联网查询不可达（且本地无结果）。

## 五、结果 schema（ngeo-get -j）

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
    "local":  { "state": "ok", "verdict": "不满意" },
    "online": { "state": "ok" }
  },
  "ts": 1789370023
}
```

## 六、测试用例

### 6.1 ngeo-get 状态机

| # | 命令 | 预期结果 |
|---|------|----------|
| 6.1.1 | `ngeo-get 219.140.0.1 -j` | `state: local`（本地省市 ASN 齐全，`online: skipped`） |
| 6.1.2 | `ngeo-get 111.8.44.6 -j` | `state: merged`，省/市来自互联网，`network` 保留本地网段 |
| 6.1.3 | `ngeo-get 219.140.0.1 --geoapi http://127.0.0.1:9999 -j` | `state: online`（本地不可用，纯互联网） |
| 6.1.4 | `ngeo-get 111.8.44.6 --api http://192.0.2.1/x/{ip} --timeout 2` | `state: local-partial`，message 含"互联网查询不可达"，本地 ASN/网段保留 |
| 6.1.5 | `ngeo-get 10.20.30.40 --api http://192.0.2.1/x/{ip} --timeout 2 -j` | `state: unreachable`，全部字段为空，退出码 2 |
| 6.1.6 | `ngeo-get 10.20.30.40 -j` | `state: empty`（`private range`） |
| 6.1.7 | `ngeo-get 999.1.1.1 -j` | `state: invalid`，退出码 1 |
| 6.1.8 | 连续查询同一 IP 两次 | 第二次 `cached: true`（JSON）或"缓存命中"（文字） |

### 6.2 gen-get

| # | 命令 | 预期结果 |
|---|------|----------|
| 6.2.1 | `gen-get 8.8.8.8` | `state: ok`，国家/省/市/ASN 齐全，`usage: 云` |
| 6.2.2 | `gen-get 10.20.30.40 -j` | `state: empty`，message 为 `private range` |
| 6.2.3 | `gen-get 8.8.8.8 --api http://192.0.2.1/x/{ip} --timeout 2` | `state: unreachable`，退出码 2 |
| 6.2.4 | `echo 8.8.4.4 \| gen-get -j` | stdin 输入，正常查询 |

## 七、缓存与配置

| 项 | 说明 |
|----|------|
| 缓存目录 | `ENV["NGEO_CACHE_DIR"]`，默认 `~/.network-infra-utility/` |
| 缓存文件 | `gen-cache.json`（gen-get 互联网层）/ `ngeo-cache.json`（ngeo 综合层） |
| 缓存策略 | `ok` / `empty` / `local` / `merged` / `online` 落盘；`unreachable` / `local-partial` 不落盘（下次重查，互联网恢复后自动补全）；`--refresh` 强制重查 |
| 本地服务地址 | `--geoapi` 或 `ENV["GEO_API_BASE"]`，默认 `http://127.0.0.1:9292` |
| 互联网接口 | `--api`（`{ip}` 占位符），默认 ip-api.com 免费接口 |
| 熔断 | 连续 3 次互联网不可达后，60s 内跳过在线查询直接返回 unreachable |

## 八、代码级用法

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

# 综合
ngeo = GeoQuery::NGeo.new
r = ngeo.lookup("111.8.44.6")         # → 统一 schema (见第五节)
ngeo.lookup("1.2.3.4", refresh: true, no_local: false)
ngeo.save_cache

# 归一化工具
GeoQuery::Normalize.isp_from_asn("CHINATELECOM Hubei province 5G network")  # => "电信"
GeoQuery::Normalize.usage_from_asn("Tencent cloud")                         # => "云"
GeoQuery::Merge.fields(local_result, online_result)                         # => 字段叠加
```

## 备注

1. **gen-get 的 `unreachable` 语义**：表示"互联网查询不可达"（网络不通/超时/限速），区别于 `empty`（互联网确认无归属，如私有地址）。不可达结果不缓存，恢复后重查即可。
2. **`local-partial` 的取舍**：体现优先级链"互联网空 < 本地空"——互联网不可达时，本地部分结果（如 ASN/网段）仍有价值，予以保留并标注；完全无数据时才降级为 `unreachable` 空状态。
3. **本地 geo-api 未启动**：ngeo-get 不视为错误（`local: unavailable`），自动走纯互联网路径，返回 `state: online`；geo-get 则直接报错并提示启动命令（可用 `GEO_API_BASE` 环境变量覆盖服务地址）。
4. **ip-api.com 免费接口限制**：45 req/min、仅 HTTP（无 HTTPS）、仅限自用。批量场景已内置 1.4s 最小间隔；更高需求可 `--api` 切换付费批量接口（pro.ip-api.com）。

> AI生成