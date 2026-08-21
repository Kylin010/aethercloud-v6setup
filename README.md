# aethercloud-v6setup

AetherCloud dynamicv6 住宅 IPv6 一键部署，顺带修掉官方脚本的四个缺陷。

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
结果是 PMTU 黑洞：ping 通、TCP 握手通、TLS 大包被静默丢弃直到超时。
本脚本把 MTU 挂到**网卡**上并写进 netplan —— 官方 timer 每 2 分钟清路由表时碰不到它，
所以不会周期性中断。

**会删掉主表的原生默认路由。**下发后主表指向某个住宅网关，而原生地址没有专属策略规则，
源地址与网关不匹配被上游反欺骗过滤丢弃，表现为原生 IPv6 失联。本脚本补一条 table 16009。

**地址会变，而 Xray 的 `sendThrough` 只认具体 IP。**填域名报
`unable to send through: <域名>`，填 CIDR 段实测 0/3 失败（Xray 从段里随机取地址，
而你只拥有其中一个），`sockopt.interface` 也无效（多个地址在同一张网卡上）。
本脚本用固定 ULA + SNAT 绕开：面板里填一个永不变的内网地址，常驻服务监听内核
地址变化事件，几秒内更新映射。**实测无延迟开销**（SNAT 是同一个包在 POSTROUTING
链上多做一次头部改写，纳秒级，而链路 RTT 是毫秒级）。

## 装了什么

```
/usr/local/bin/v6nat.sh            SNAT 跟随服务
/etc/systemd/system/v6nat.service  开机自启
/etc/netplan/99-mtu.yaml           MTU 持久化
```

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
