# aethercloud-v6setup

AetherCloud dynamicv6 住宅 IPv6 一键部署，顺带修掉官方脚本的三个缺陷。

官方脚本能下发地址，但下发完常常不通、或者过几分钟又断。这个脚本在调用官方
下发之后补上它漏掉的步骤，并把「面板里填一次、地址变了自动跟随」做成常驻服务。

## 用法

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Kylin010/aethercloud-v6setup/main/v6setup.sh)
```

交互式，会列出拿到的所有出口（含国家和 ISP），让你选一个绑定固定地址。

```bash
v6setup.sh --prefix 2001:b011   # 非交互，直接绑指定前缀（这里是台湾 HiNet）
v6setup.sh --check              # 只体检，不改动任何东西
v6setup.sh --uninstall          # 卸载本脚本装的东西，不动官方的
```

## 它修了什么

**邻居发现失败后不重试。**官方脚本全文没有 `ip -6 neigh`。下发时上游未就绪，内核
把 ND 结果缓存成 `FAILED` 就永不重试，症状是「配置全对但 100% 丢包、
`time_connect=0.000000s`」。本脚本下发后主动 flush 一次。

**MTU 没应用到策略路由表。**官方的 `mtu_arg` 只用在主表（1541/1559/1571 行），
`apply_source_policy_routes` 的 865/946 行漏了。而源地址绑定的流量走的正是策略表，
所以住宅出口的路由上没有 MTU。住宅出口走 WireGuard 隧道，隧道开销吃掉约 100 字节，
网卡按 1500 发出的大包在隧道口被丢。

实测（`.212`，网卡还原 1500 vs 1400，每项 5 次，出站 2MB）：

| 出口 | 大包 ICMP (1400B) | 出站 2MB @1500 | @1400 |
|---|---|---|---|
| 日本 Sony | 100% 丢 | 5.58 ~ 7.61s | 0.83 ~ 0.96s |
| 新加坡 Starhub | 100% 丢 | 0.61 ~ 0.73s | 0.66 ~ 0.76s |
| 台湾 HiNet | 100% 丢 | 0.55 ~ 0.69s | 0.67 ~ 0.85s |
| 香港原生（非隧道） | 0% 丢 | 0.11 ~ 0.46s | 0.12 ~ 0.26s |

大包 ICMP 在三条住宅出口全丢，但**只有日本那条真的受影响**——出站慢 6.6 倍且五次一致。
新加坡和台湾在 1500 下毫无损失，说明它们的隧道端做了 TCP MSS clamping，救了 TCP 但救不了
ICMP；日本那条没有，于是变成 PMTU 黑洞，TCP 只能靠超时重传摸索，每次卡 5 秒以上。

注意受害的是**出站**大流量。下载方向的大包是入站的，出站只有小 ACK，碰不到这个问题——
所以光测下载会误判为"一切正常"。TCP 握手和小请求也一律正常。

本脚本把 MTU 挂到**网卡**上并写进 netplan，一次覆盖全部路由表，官方 timer 清路由表时
碰不到它。

**厂商 timer 会永久停摆。**它的 unit 只有 `OnBootSec=2min` + `OnUnitActiveSec=2min`。
机器开机很久之后，如果 `dynamicv6-client.service` 本次开机一次都没跑过，systemd 会算出
`NextElapseUSecMonotonic=infinity`，定时器 enabled 也 active，却永远不再触发，租约不再续。
实测撞到过一台连续 6 天没续约。本脚本部署时用 systemd 跑一次 service 补上锚点，
`--check` 也会专门报这一项。

**地址会变，而 Xray 的 `sendThrough` 只认具体 IP。**填域名报
`unable to send through: <域名>`，填 CIDR 段实测 0/3 失败（Xray 从段里随机取地址，
而你只拥有其中一个），`sockopt.interface` 也无效（多个地址在同一张网卡上）。
本脚本用固定 ULA + SNAT 绕开：面板里填一个永不变的内网地址，常驻服务监听内核
地址变化事件，几秒内更新映射。**实测无延迟开销**（SNAT 是同一个包在 POSTROUTING
链上多做一次头部改写，纳秒级，而链路 RTT 是毫秒级）。

## 装了什么

```
/usr/local/bin/v6setup.sh          本脚本自身，装好后可直接 v6setup.sh --check
/usr/local/bin/v6nat.sh            SNAT 跟随服务
/etc/systemd/system/v6nat.service  开机自启
/etc/netplan/99-mtu.yaml           MTU 持久化
```

主表默认路由本脚本**不碰**，交给官方脚本——它自己会 pin 源地址并把默认路由收敛成
单 nexthop。官方早期版本会删掉主表原生默认路由，现在已经修了（`pin_main_default_route_source`），
所以本脚本里那段 table 16009 的补丁已删除。

固定 ULA 默认 `fd00:6c:7477::1`，用 `V6SETUP_ULA` 环境变量可改。
MTU 默认 1400，用 `V6SETUP_MTU` 可改。

## 配合 3x-ui

出站的「发送通过」填固定 ULA，Strategy 随意（`sendThrough` 绑了 IPv6 就锁死地址族，
四种策略行为一致）。真实地址变了不用动面板。

多个出口想做故障转移，用 3x-ui 的负载均衡：出站标签统一前缀（如 `v6-`），
建均衡器选 `leastPing`，观测器探测 `https://www.google.com/generate_204`，
路由规则填 Balancer Tag 而非 Outbound Tag。实测某个出口挂掉后约 35 秒自动切换。

## 注意

网卡 MTU 降到 1400 会让所有流量每包少 100 字节载荷，效率损失约 6.7%。
对代理流量无感（瓶颈是延迟和住宅线路带宽），但如果你的机器主要跑大流量传输，
可以改用路由级 MTU —— 代价是官方 timer 每 2 分钟会清掉它，需要额外的守护进程补回。

## License

MIT
