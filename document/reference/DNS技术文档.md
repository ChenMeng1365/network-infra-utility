# DNS 技术文档

> 关联工具：`bin/dns-query`（跨平台统一域名查询工具）

> 配套文档：`document/DNSQuery工具使用方法.md`

DNS（Domain Name System，域名系统）是互联网的基础寻址服务，负责域名与 IP 地址之间的映射。绝大多数通讯业务在建立连接前都要先经过 DNS 解析，DNS 一旦异常，业务表现往往不是"完全不可用"，而是"时好时坏、部分区域不可用"，排查难度较高。

本文从三个角度展开：**哪些通讯业务依赖 DNS**、**DNS 请求与响应报文结构**、**DNS 查询可以查到哪些信息**，最后给出常见问题的研判思路。

---

## 一、哪些通讯业务与 DNS 有关系

### 1. 固定语音（IMS / VoLTE / VoIP）

- 呼叫信令 SIP 消息中的 `Request-URI`、`Route`、`Contact` 等字段携带域名（如 `sip.example.com`），主被叫域归属、呼叫路由都依赖 DNS。

- IMS 网络中 P-CSCF / I-CSCF / S-CSCF 通过 **ENUM（E.164 号码映射）查询** 将电话号码转换为 SIP URI 再路由；ENUM 本质就是基于 `e164.arpa` 的 **NAPTR 记录查询**。

- 被叫号码若处于跨网或异运营商场景，需通过 DNS 查询对端域的 NS / SRV / NAPTR 记录确定信令入口。

- 视频通话、彩铃、呼叫转移等增值业务，媒体协商（SDP）与 AS（应用服务器）寻址同样依赖 DNS。

**DNS 异常表现**：呼损率上升、呼叫建立时间变长、跨网呼叫失败、呼叫路由到错误局点。

### 2. 短信（SMS / MMS）

- 短信中心（SMSC）之间的互通、异网短信下发，依赖对端域名的解析（如 `smsc.example.com`）。
- 彩信（MMS）需要 **URL 回源**，终端通过 DNS 解析彩信中心域名。
- 短信平台与上游/下游网关对接时，若对方域名解析失败，会导致短信排队、下发延迟或失败。

**DNS 异常表现**：短信下发延迟、短信积压、个别用户收不到（尤其是跨运营商互通）。

### 3. 移动数据与 APN



- 手机数据业务通过 **APN（接入点名称）** 接入（如 `cmnet`、`cmwap`、`ims`），核心网（GGSN / PGW / UPF）需解析 APN 对应的 **PDN 网关域名**。
- 用户上网产生的所有域名解析请求，由运营商侧 DNS（或用户配置的 DNS）承载，DNS 解析质量直接决定网页/APP 打开速度。
- 4G/5G 网络中的 **DNS over HTTPS/TLS（DoH/DoT）** 流量日趋增多，对链路管控提出了新要求。

**DNS 异常表现**：APN 拨号失败、上网断断续续、下载速率低、游戏/视频卡顿。



### 4. 专线与政企客户业务



- **MPLS VPN / 云专线 / 组网专线** 客户侧 CPE 设备通常配置 DNS 解析，企业内部域名（如 `oa.company.com`）依赖运营商侧或客户自建 DNS。
- 政企客户通过 DNS 访问云上应用、IDC 机房业务（如 `idc.company.com`），解析策略决定访问路径。
- 客户组网切换、DNS 变更割接时，若解析不生效，业务立即中断。



**DNS 异常表现**：专线拨号失败、政企内网应用无法访问、跨区域访问走远路（解析到异区域 IP）。



### 5. CDN 内容分发网络



- CDN 调度的核心是 **DNS 智能调度（GSLB）**：根据用户来源 IP 归属、运营商、时延，把域名解析到最近的边缘节点 IP。
- CDN 故障或调度策略异常时，通过对比 **权威 DNS** 与 **递归 DNS** 的解析结果，可快速定位调度链路。
- 视频点播、直播拉流、网页加速、下载分发等业务全部依赖 CDN 的 DNS 调度链路。



**DNS 异常表现**：部分区域打开慢、跨省流量突增、源站直接暴露、部分用户访问到错误节点。



### 6. 云服务 / IDC / 应用托管

- 云主机公网 IP、负载均衡（SLB/ELB）的访问入口、数据库与缓存的内网域名，全靠 DNS 对外发布。
- 微服务/容器（K8s）场景下，**服务发现**依赖内部 DNS（CoreDNS / KubeDNS），服务间调用、注册中心地址、配置中心域名都经过 DNS。
- 混合云/多云架构中，DNS 是打通各环境寻址的公共纽带。

**DNS 异常表现**：K8s 服务间调用失败、配置中心不可达、公网域名解析出内网 IP。



### 7. 域名注册 / 邮箱 / 企业应用

- 域名注册局与注册商之间通过 **WHOIS/EPP** 管理域名，续费、转移、过期直接影响解析。
- 企业邮箱（如 `mail.company.com`）依赖 **MX 记录** 确定收件服务器；**SPF / DKIM / DMARC（TXT 记录）** 决定邮件反垃圾信用。
- 企业官网、OA、ERP 等应用全部依赖公网域名解析。

**DNS 异常表现**：收不到外部邮件、发信被退、官网无法访问、域名过期导致全线业务中断。



### 8. 物联网（IoT）与 M2M

- 物联网卡（eSIM / 实体卡）平台通过域名接入 IoT 平台，设备上报/下发依赖域名解析。
- 设备数量庞大，且部分设备固件不会缓存解析结果，每次连接都发起 DNS 查询，产生大量 DNS 流量。
- 车联网 TSP、智能家居云平台同样依赖 DNS 完成设备接入。



**DNS 异常表现**：设备频繁掉线、数据上报延迟、批量设备无法激活。



### 9. 网络安全与防护（DNS 反查/溯源）

- **DNS 即攻击面**：基于 DNS 的放大反射攻击（利用 open 递归 DNS）、DGA 域名（恶意程序随机生成域名）逃避、DNS 隧道（隐蔽 C2 通道）、域名劫持 / 缓存投毒。
- 安全防护中，通过 **DNS 日志/解析行为分析** 可发现僵尸网络（Botnet）、挖矿木马（矿池）、钓鱼、恶意软件回连等威胁。
- 运营商 / IDC 常对异常域名解析做监控与阻断。

**DNS 异常表现**：频繁出现未知域名解析、疑似 DGA 域名、特定域名解析异常，或存在大量无业务背景的 DNS 查询。



### 10. 其他网络业务（常用基础）

- 故障排查基础：任何"域名访问失败但 IP 可访问"的场景，第一排查点都是 DNS。
- 内容合规（内容安全）、域名备案管理、日志审计（记录用户解析记录）均与 DNS 数据有关。
- 运营商出口、防火墙、上网行为管理对域名做分流/封堵策略，同样需要与 DNS 联动。

---

## 二、DNS 查询可查哪些信息

### 1. 常见记录类型（正查）

| 记录类型 | 全称 | 查询结果（返回内容） | 典型用途 |
|---------|------|----------------------|---------|
| A | 地址记录 | 域名对应的 IPv4 地址（如 `www.baidu.com → 39.156.70.46`） | 网站访问、应用寻址 |
| AAAA | IPv6 地址记录 | 域名对应的 IPv6 地址 | IPv6 环境访问 |
| CNAME | 别名记录 | 域名的另一域名（如 `www.baidu.com → www.a.shifen.com`） | CDN 调度、多域名统一入口 |
| MX | 邮件交换记录 | 邮件服务器域名及优先级（如 `qq.com → mx3.qq.com（30）`） | 邮件收发路由 |
| NS | 域名服务器记录 | 该域名的权威 DNS 服务器（如 `baidu.com → ns3.baidu.com`） | 域名托管、权威服务器判断 |
| PTR | 指针记录 | IP 对应的反向域名（如 `8.8.8.8 → dns.google`） | IP 反查域名、归属确认 |
| SOA | 起始授权记录 | 主服务器、管理员邮箱、序列号、刷新/重试/过期/TTL | 区域信息与同步状态 |
| TXT | 文本记录 | 任意文本（如 `v=spf1`、`_dmarc`、`_acme-challenge`） | SPF/DKIM/DMARC 反垃圾、域名验证 |
| SRV | 服务定位记录 | 服务名、端口、优先级、权重、目标主机 | SIP、IM、K8s 服务发现 |
| NAPTR | 名称权威指针 | 规则匹配后的 URI 模板 | ENUM（号码转 SIP URI）、SIP 路由 |
| CAA | 证书授权记录 | 允许签发证书的 CA（如 `0 issue "digicert.com"`） | HTTPS 证书签发白名单 |
| ANY | 全部记录 | 上述所有类型的汇总 | 一次性查看该域名全部信息 |
| AXFR | 区域传送 | 整个域的所有记录（通常被禁止公开） | 权威 DNS 配置审计 |
| DNSSEC 相关 | DNSKEY / DS / RRSIG / NSEC | 密钥与签名记录 | 验证 DNS 数据来源真实性与完整性 |

### 2. 反向查询（PTR）



- 由 IP 查域名（`in-addr.arpa` / `ip6.arpa` 反向区域）。

- 用途：确认 IP 归属（如 `dns.google`）、反查钓鱼/恶意 IP、验证邮件服务器 IP 与域名是否匹配（反垃圾邮件）、机房 IP 对运营域名的映射。

- 例：`dns-query 8.8.8.8` → `8.8.8.8.in-addr.arpa name = dns.google`。



### 3. 服务器与解析链路信息



| 查询项 | 说明 |

|--------|------|

| 解析到的 IP | 当前递归 DNS 返回的 IP 列表（可能有多个，负载均衡） |

| 权威/非权威应答 | 判断应答来源是权威 DNS 还是本地缓存（递归） |

| 响应 TTL | 记录缓存时长，可判断该记录刚更新/持久（用于校验） |

| 服务器地址 | 本次查询使用的 DNS 服务器 IP（可指定 `-s` 切换） |

| CNAME 链 | 从原始域名到最终 A 记录的完整别名链（对 CDN 场景很重要） |

| 返回时间 | 解析耗时，可用于判断 DNS 服务是否卡顿、超时 |



### 4. 其他可查信息



| 信息 | 说明 |

|------|------|

| WHOIS 信息 | 注册人、注册机构、注册时间、到期时间、联系邮箱（通过 WHOIS 服务） |

| 域名注册/到期时间 | 判断域名是否临期、是否被注册局回收 |

| 历史解析记录 | 该域名历史上解析过的 IP（用于溯源、取证） |

| DNS 安全状态 | 是否启用 DNSSEC、CAA 是否收紧、是否被挂黑名单（SBL） |

| 解析一致性 | 不同 DNS 服务器（本地/公共/权威）对同一域名的解析结果是否一致（检查污染/劫持） |

| DNS 服务可用性 | 指定 DNS 服务器的可达性、响应时间、丢包率 |



---



## 三、DNS 请求与响应报文结构



DNS 报文采用固定格式，无论请求还是响应，结构完全一致，仅在 **标志位** 与 **区段填充内容** 上体现差异。报文在 UDP（默认 53 端口，最大 512 字节，超出用 TC 位截断）或 TCP（超长响应）上传输，共分为 **5 个区段**：



```

+---------------------+

|       报文头        |   Header（固定 12 字节）

+---------------------+

|      问题区段        |   Question（请求的域名与类型）

+---------------------+

|      回答区段        |   Answer（RR 记录）

+---------------------+

|     权威区段        |   Authority（NS 记录）

+---------------------+

|     附加区段        |   Additional（附加记录）

+---------------------+

```



### 1. 报文头 Header（固定 12 字节）



| 字段 | 长度 | 说明 |

|------|------|------|

| ID（标识） | 2 字节 | 请求与响应 **必须相同**，用于请求/响应匹配、防串包 |

| QR | 1 位 | 0=请求，1=响应 |

| Opcode | 4 位 | 0=标准查询，1=反向查询，2=服务器状态请求等 |

| AA（授权回答） | 1 位 | 响应是否来自权威 DNS |

| TC（截断） | 1 位 | 响应被截断（UDP 放不下，需用 TCP 重查） |

| RD（期望递归） | 1 位 | 请求方希望递归解析 |

| RA（可用递归） | 1 位 | 响应方是否支持递归 |

| Z（保留） | 3 位 | 保留位，通常为 0（EDNS0 会用到部分） |

| RCODE（响应码） | 4 位 | 0=NOERROR，1=FORMERR，2=SERVFAIL，3=NXDOMAIN，4=NOTIMP，5=REFUSED |

| QDCOUNT | 2 字节 | 问题区段数量（通常为 1） |

| ANCOUNT | 2 字节 | 回答区段数量 |

| NSCOUNT | 2 字节 | 权威区段数量 |

| ARCOUNT | 2 字节 | 附加区段数量 |



### 2. 问题区段 Question（请求的核心内容）



一条请求通常只含一个问题：



| 字段 | 说明 |

|------|------|

| QNAME（查询名） | 要查询的域名，每段用长度+字节编码，以 0 结尾 |

| QTYPE（查询类型） | 1=A，2=NS，5=CNAME，6=SOA，15=MX，16=TXT，28=AAAA，33=SRV，35=NAPTR，255=ANY |

| QCLASS（查询类） | 通常为 1（IN，Internet） |



例如查询 `www.baidu.com` 的 A 记录，QNAME 编码为：`03www 05baidu 03com 00`。



### 3. 回答区段 Answer（查询结果 RR 记录）



每个资源记录（RR）包含：



| 字段 | 说明 |

|------|------|

| NAME | 资源记录对应的域名（可能是指针压缩） |

| TYPE | 记录类型（同 QTYPE 编号） |

| CLASS | 类，通常为 IN |

| TTL | 缓存存活时间（秒） |

| RDLENGTH | RDATA 的长度 |

| RDATA | 记录数据（A 记录为 4 字节 IPv4，AAAA 为 16 字节 IPv6，MX 含优先级+交换域名等） |



### 4. 权威区段 Authority



- 返回该域名的 **NS 记录**（权威服务器信息），多用于迭代解析时的下一步指引。

- 权限区可告知查询者"谁才是这个域的权威 DNS"，是区分 **递归应答** 与 **权威应答** 的重要依据。



### 5. 附加区段 Additional



- 补充相关记录，如 NS 对应的 A/AAAA 记录（glue records）、EDNS0 选项、DNSSEC 相关记录。

- 权限与附加区段在普通查询中常为空，仅部分场景（区域传送、DNSSEC）才会完整填充。



### 6. 报文标志位速记



| 位 | 含义 | 排查要点 |

|----|------|---------|

| QR | 请求/响应 | 抓包时判断方向 |

| TC | 截断 | 出现 → 响应过大，检查是否走 TCP 重查 |

| RD/RA | 递归请求/可用 | 递归服务是否开启 |

| RCODE | 响应码 | `SERVFAIL`（服务器故障）≠ `NXDOMAIN`（域名不存在） |



> 示例：一个标准 `A` 查询（`www.baidu.com`）的响应中，RCODE=0（NOERROR）、AA=0（非权威，来自递归缓存）、ANCOUNT=1（返回 1 条 A 记录）是常见形态。



---



## 四、DNS 信息在业务排查中的典型用法



### 1. 判断 DNS 污染 / 劫持



- 用**同一域名**分别查询**本地 DNS、权威 DNS、公共 DNS**（如 8.8.8.8、114.114.114.114），对比解析结果。

- 若本地 DNS 与公共 DNS 结果不一致，优先怀疑本地或链路中存在污染/劫持/缓存污染。



### 2. 判断 CDN 调度是否正常



- 查 `CNAME` 链，确认域名是否被 CNAME 到 CDN 平台域名。

- 查 `A` 记录，确认解析出的 IP 是否属于该 CDN 在本地运营商的节点（对照节点库）。

- 若解析 IP 与用户地域/运营商不匹配，说明调度策略异常或 CDN 配置错误。



### 3. 邮件服务器排查



- 查 `MX` 确认收件服务器；查 `SPF`/`DKIM`/`DMARC`（TXT）确认发件信用。

- 查反查 `PTR`，确认发信 IP 与主机名是否一致，避免被对方反垃圾拦截。



### 4. 安全威胁研判（基于 DNS 特征）



| 特征 | 可能的威胁 |

|------|-----------|

| 大量未知域名解析失败 | DGA 恶意软件、挖矿木马（域名轮换） |

| 高频重复查询固定恶意域名 | 恶意软件回连 C2（命令控制） |

| 特定域名解析结果漂移 / 篡改 | DNS 劫持、缓存污染 |

| 权威 DNS 应答异常 | 权威服务器被入侵、区域传送泄露 |

| NXDOMAIN 风暴 | 僵尸网络探测、域名枚举扫描 |



---



## 五、DNS 查询工具与用法（项目内）



> 完整用法见 `document/DNSQuery工具使用方法.md`



项目提供 `bin/dns-query` 统一命令，自动选择当前平台可用工具（dig / nslookup / host / Resolve-DnsName 等）执行查询：



```bash

# 正查 A 记录（默认）

ruby bin/dns-query www.baidu.com



# 反查 PTR（自动识别 IP）

ruby bin/dns-query 8.8.8.8



# 指定记录类型 / 指定 DNS 服务器

ruby bin/dns-query www.baidu.com -t CNAME

ruby bin/dns-query qq.com -t MX -s 8.8.8.8



# 全工具交叉查询

ruby bin/dns-query www.baidu.com -a

```



---



## 六、DNS 排查问题速查表



| 症状 | 排查方向 |

|------|---------|

| 域名访问失败但 IP 可访问 | 本地 DNS / 系统 DNS 配置；尝试公共 DNS 对比 |

| 部分用户/区域访问慢或失败 | 递归 DNS 就近/跨区域调度；CDN 节点覆盖 |

| 呼叫掉线、跨网失败 | SIP 域名的 A/NS 记录、E164 ENUM（NAPTR）解析 |

| 短信下发延迟 | 短信网关域名解析；确认 MX/NS 正常 |

| 邮件收不到 | MX / SPF / DKIM / DMARC / 反查 PTR |

| K8s 服务间调用失败 | CoreDNS 服务发现解析、DNS 策略 |

| 疑似被劫持 | 多 DNS 对比、检查本地 hosts、路由器 DNS 配置 |

| 疑似恶意域名 | 查询历史记录、DNS 日志、威胁情报平台 |



---



## 七、DNS 记录类型查询示例



以下示例以 `dig` 为主（Linux / WSL / macOS），Windows 可用等价的 `nslookup`。通用技巧：`dig @8.8.8.8 域名 类型` 指定服务器，`+short` 只看结果，`+noall +answer` 只看应答段。



### 1. A 记录（IPv4 地址）



**查询方法**：

```bash

dig example.com A

```



**返回结果**：

```

;; ANSWER SECTION:

example.com.		86400	IN	A	93.184.216.34

```



**解释**：将域名解析到 IPv4 地址。`86400` 是 TTL（秒），`IN` 是类（Internet）。无配置时返回空应答（NOERROR 但无记录），查询不到不代表解析失败。



### 2. AAAA 记录（IPv6 地址）



**查询方法**：

```bash

dig google.com AAAA

```



**返回结果**：

```

;; ANSWER SECTION:

google.com.		120	IN	AAAA	2404:6800:4004:812::200e

```



**解释**：解析到 IPv6 地址。只有域名配置了 IPv6 才有此记录，无配置时返回空应答（NOERROR 但无记录），查询不到不代表解析失败。



### 3. CNAME 记录（别名）



**查询方法**：

```bash

dig www.github.com CNAME

```



**返回结果**：

```

;; ANSWER SECTION:

www.github.com.		3600	IN	CNAME	github.com.

```



**解释**：`www.github.com` 是 `github.com` 的别名，浏览器会再查询一次 `github.com` 的 A 记录。**关键规则（RFC 1034）**：CNAME 不能与同名的 A / AAAA / MX / NS / TXT 等任何其他记录共存，因为 CNAME 是"唯一真名"。排查域名劫持 / CDN 调度 / PCDN 调度时常靠 CNAME 链定位真实目标。



### 4. MX 记录（邮件服务器）



**查询方法**：

```bash

dig gmail.com MX

```



**返回结果**：

```

;; ANSWER SECTION:

gmail.com.		600	IN	MX	5 gmail-smtp-in.l.google.com.

gmail.com.		600	IN	MX	10 alt1.gmail-smtp-in.l.google.com.

```



**解释**：邮件投递目标，前置数字是优先级（越小越优先）。发信方先取优先级最小的服务器连接。可用 `dig +short gmail.com MX` 快速列出。



### 5. NS 记录（权威域名服务器）



**查询方法**：

```bash

dig example.com NS

```



**返回结果**：

```

;; ANSWER SECTION:

example.com.		86400	IN	NS	a.iana-servers.net.

example.com.		86400	IN	NS	b.iana-servers.net.

```



**解释**：声明该域名的权威 NS。排查域名转移、托管服务商、CDN 调度是否异常时，先看 NS 指向哪家。用 `dig @根服务器 example.com NS +trace` 可看完整委派链。



### 6. PTR 记录（反向解析，IP → 域名）



**查询方法**：

```bash

dig -x 8.8.8.8

# 等价于: dig 8.8.8.8.in-addr.arpa PTR

```



**返回结果**：

```

;; ANSWER SECTION:

8.8.8.8.in-addr.arpa.	3600	IN	PTR	dns.google.

```



**解释**：IPv4 反向域是 `in-addr.arpa`（IP 倒序）；IPv6 反向域是 `ip6.arpa`（如 `dig -x 2400:3200::1`）。用途：邮件反垃圾（PTR 校验）、流量日志里定位外网 IP 归属。注意很多运营商用户侧 PTR 为空或仅反解到宽带接入服务器。



### 7. SOA 记录（起始授权）



**查询方法**：

```bash

dig example.com SOA

```



**返回结果**：

```

;; ANSWER SECTION:

example.com.	86400	IN	SOA	ns.icann.org. noc.dns.icann.org. (

				2024010101 ; serial

				7200       ; refresh

				3600       ; retry

				1209600    ; expire

				3600 )     ; minimum

```



**解释**：域名的"源头档案"，字段依次为：主 NS、负责人邮箱（`noc.dns.icann.org` 表示 noc@dns.icann.org）、序列号（每改动 +1）、刷新周期（从 NS 同步主 NS）、重试间隔、过期时间、negative TTL。排查"为什么改了记录不生效"时先看 serial 有没有变。



### 8. TXT 记录（任意文本）



**查询方法**：

```bash

dig gmail.com TXT

```



**返回结果**：

```

;; ANSWER SECTION:

gmail.com.	3600	IN	TXT	"v=spf1 include:_spf.google.com ~all"

```



**解释**：TXT 承载 SPF（发信白名单）、DKIM（`dig default._domainkey.域名 TXT`）、DMARC（`dig _dmarc.域名 TXT`）、域名归属验证等。一条 TXT 可以有多个字符串片段（用引号分段拼接）。



### 9. SRV 记录（服务定位）



**查询方法**（格式为 `_服务._协议.域名`）：

```bash

dig _xmpp-server._tcp.gmail.com SRV

```



**返回结果**：

```

;; ANSWER SECTION:

_xmpp-server._tcp.gmail.com. 60 IN	SRV	20 0 5269 xmpp-server.l.google.com.

```



**解释**：定位特定服务的主机与端口。字段顺序为：**优先级 权重 端口 目标主机**（上例 20 是优先级，0 是权重，5269 是端口）。常见：`_sip._tcp`、`_ldap._tcp`、`_minecraft._tcp`。权重用于同优先级多台机器负载均衡。



### 10. ANY 记录（查询全部类型）



**查询方法**：

```bash

dig example.com ANY

```



**返回结果**：

```

;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 62201

;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:

; EDNS: version: 0, flags:; udp: 4096

```



**解释**：**不要依赖 ANY**。因 ANY 查询可被用于 DNS 反射放大攻击（一个小查询换来一个大响应），BIND 9.12+、大多数权威服务器按 **RFC 8482** 默认返回空应答（或只回一条 HINFO），即使是 example.com 也查不到完整记录。**想要全部记录就分开查**：`dig A`、`dig MX`、`dig TXT`……逐类型查询。



### 附：nslookup 等价写法（Windows）



```powershell

nslookup -type=A example.com

nslookup -type=AAAA example.com

nslookup -type=CNAME www.github.com

nslookup -type=MX gmail.com

nslookup -type=NS example.com

nslookup -type=PTR 8.8.8.8

nslookup -type=SOA example.com

nslookup -type=TXT gmail.com

nslookup -type=SRV _xmpp-server._tcp.gmail.com

nslookup -type=ANY example.com

```



**常用辅助选项**：`nslookup 域名 服务器IP`（指定 DNS，如 `nslookup example.com 8.8.8.8`，内网排查可指向运营商 DNS）；`dig +short` 只看答案；`dig +trace` 追完整解析链；`dig -x IP` 反向解析。



### 附：排查要点回顾



| 要点 | 说明 |

|------|------|

| CNAME 同名冲突 | CNAME 与 A / AAAA 等记录**不能同名共存**，出现"明明配了 A 却解析不出来"先查是不是配了同名 CNAME |

| SRV 格式 | 必须带 `_服务._协议.` 前缀，查询时域名格式写错会返回 NXDOMAIN |

| ANY 受限 | 受 RFC 8482 限制返回空应答是**正常行为**，不是故障 |

| 指定 DNS 排查 | 用 `dig @内网DNS 域名 类型` 直接指测目标服务器，对比公共 DNS 结果差异可定位递归缓存问题 |



---



## 八、总结



- DNS 是几乎所有通讯业务（语音、短信、数据、专线、CDN、云服务、IoT、安全）**公共的基础依赖**，排查时从 DNS 入手往往能最快定位瓶颈。

- DNS 查询能力覆盖：记录类型（A/AAAA/CNAME/MX/NS/PTR/SOA/TXT/SRV/NAPTR/CAA）、反向查询、权威/递归链路、一致性对比、WHOIS、安全威胁特征等多个维度，第七章给出了每种记录类型的完整查询示例（含 dig / nslookup 命令、返回结果与逐字段解释）。

- 日常运维建议把"多 DNS 对比、反查、记录类型全查"固化成例行动作，配合同一工具（如 `bin/dns-query`）快速验证，能大幅缩短定位时间。



---



*文档生成日期：2026-08-28*

*更新日期：2026-09-04（新增第七章：DNS 记录类型查询示例）*
