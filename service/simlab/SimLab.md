# coding: utf-8
# frozen_string_literal: true

=begin HELP
SimLab - 路由交换模拟仿真

= 概述

SimLab 是 network-infra-utility 的路由交换仿真子系统，
位于 service/simlab/ 下。它将 support 层的路由/交换原子能力
组合成可运行的虚拟网络，并提供场景加载、事件驱动、观测导出等功能。

= 架构分层

  support/                     ← 原子原理层（纯内存，无 IO）
    basic/packet.rb             ← EthernetFrame / IPPacket / ARP / ICMP
    routing/
      prefix.rb                 ← CIDR 前缀解析/比较
      lpm_trie.rb               ← 最长前缀匹配 Trie
      rib.rb                    ← 路由信息库 RIB
      static_route.rb           ← 静态路由
      rip.rb                    ← 距离矢量协议 RIP
      ospf.rb                   ← 链路状态协议 OSPF
      bgp.rb                    ← 路径矢量协议 BGP
    switching/
      mac_table.rb             ← MAC 地址表
      frame_forward.rb          ← 帧转发决策
      vlan.rb                   ← 802.1Q VLAN
      stp.rb                   ← 生成树协议

  service/simlab/               ← 仿真服务层（编排+IO）
    lib/simlab.rb                ← 组合根入口
    lib/simlab_topology.rb       ← 拓扑模型
    lib/simlab_engine.rb         ← 离散事件引擎
    lib/simlab_router.rb         ← 虚拟路由器
    lib/simlab_switch.rb         ← 虚拟交换机
    lib/simlab_traffic.rb        ← 流量注入
    lib/simlab_observer.rb       ← 观测导出
    lib/simlab_scenario.rb       ← YAML 场景加载
    bin/simctl                   ← Thor CLI

= 分层纪律

1. support 层：纯内存、无 IO、无 Time.now、无全局状态
2. service 层：负责编排、生命周期、事件调度、文件/CLI
3. 协议出口唯一：所有协议通过 RIB#add 安装路由
4. 组件通过 tick(now) 被动推进，不自己计时
5. device 间不直接互调，由 engine 按链路投递

= 快速开始

  # 运行场景
  ruby service/simlab/bin/simctl simulate example/simlab/ospf_basic.yml

  # 导出 RIB
  ruby service/simlab/bin/simctl dump --rib R1 example/simlab/ospf_basic.yml

  # 路径追踪
  ruby service/simlab/bin/simctl trace --from R1 --to 192.168.2.1 example/simlab/ospf_basic.yml

  # 列出场景
  ruby service/simlab/bin/simctl list example/simlab/ospf_basic.yml

= 场景 YAML 格式

  ---
  topology:
    routers:
      R1:
        interfaces: {Gi0/0: 10.0.0.1/24}
        ospf: {router_id: 1.1.1.1}
    switches:
      S1:
        ports: [Gi0/1, Gi0/2]
        access_ports: {Gi0/1: 10}
    links:
      - [R1:Gi0/0, R2:Gi0/0, {bandwidth: 100000, delay: 10}]
    hosts:
      H1: {ip: 192.168.1.2/24, gateway: 192.168.1.1}
  protocols:
    ospf:
      neighbors:
        - {router: R1, neighbor_rid: 2.2.2.2, port: Gi0/0, cost: 10}
  simulation:
    until: 100
    protocol_interval: 10
  traffic:
    - {type: ping, from: R1, to: 192.168.2.1, at: 50}
    - {type: link_down, device: R1, port: Gi0/0, at: 80}
  expect:
    - rib_converged: [R1, R2]

= 已实现功能清单

== Support 路由层
- [x] CIDR 前缀解析/规范化/包含比较
- [x] 最长前缀匹配 Trie (IPv4/IPv6)
- [x] RIB 路由信息库（多协议共存/优选排序）
- [x] 静态路由（增删/递归解析）
- [x] RIP 距离矢量（Bellman-Ford/水平分割/毒性反转/hold-down）
- [x] OSPF 链路状态（LSA 泛洪/Dijkstra SPF）
- [x] BGP 路径矢量（AS_PATH 防环/LOCAL_PREF/MED 优选/policy 钩子）

== Support 交换层
- [x] MAC 地址表（学习/老化/静态表项）
- [x] 帧转发决策（泛洪/转发/丢弃/hairpin 过滤/ACL 钩子）
- [x] 802.1Q VLAN（access/trunk 端口/native VLAN/白名单）
- [x] STP 生成树（BPDU/根桥选举/端口角色/状态机）

== Service 仿真层
- [x] 拓扑模型（节点/链路/邻接关系）
- [x] 离散事件引擎（虚拟时钟/事件队列/延迟事件）
- [x] 虚拟路由器（RIB+LPM+Static+RIP/OSPF/BGP 组合）
- [x] 虚拟交换机（MAC+Forward+VLAN+STP 流水线）
- [x] 流量注入（ping/链路故障/节点故障/协议交换）
- [x] 观测导出（RIB/MAC/trace/收敛检测）
- [x] YAML 场景加载器
- [x] Thor CLI (simctl)

= 扩展路线（文档已设计，待实现）

  support/
    routing/isis.rb             ← IS-IS 链路状态 IGP
    mpls/                       ← MPLS 标签/LDP/RSVP-TE/VRF/L3VPN
    segment/                    ← SR/SRv6 SID
    evpn/                       ← EVPN NLRI/VXLAN
    te/                         ← TED/CSPF/TE Tunnel
    flexe/                      ← FlexE 时隙化 shim
    vpdn/                       ← L2TP/PPP/VPDN 会话
  service/simlab/
    capability.rb               ← 设备能力声明
    profile.rb                  ← 节点 profile
    pipeline.rb                 ← 统一转发流水线
    service_model.rb             ← L3VPN/L2VPN/EVPN 业务实例
    segment_policy.rb           ← SR/SRv6 policy
    telemetry.rb                ← 额外观测
    scenario_schema.rb          ← YAML DSL 扩展
=end

> AI生成
