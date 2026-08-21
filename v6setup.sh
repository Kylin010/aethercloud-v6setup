#!/bin/bash
# AetherCloud dynamicv6 一键部署
# 下发住宅 IPv6 + 修复厂商脚本的三个缺陷 + 装固定 ULA 出口
#
# 用法:
#   v6setup.sh                      下发并部署，交互选择要绑的出口
#   v6setup.sh --prefix 2001:b011   非交互，直接绑指定前缀
#   v6setup.sh --check              只体检，不改动
#   v6setup.sh --uninstall          卸载本脚本装的东西（不动厂商的）
set -u

ULA=${V6SETUP_ULA:-fd00:6c:7477::1}
MTU=${V6SETUP_MTU:-1400}
PROV=/tmp/dv6.sh
PROV_URL=https://billing.aethercloud.io/dynamicv6/client.sh
IFACE=$(ip -o route show to default | awk '{print $5; exit}')
MODE=deploy; PREFIX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX=$2; shift 2 ;;
    --check) MODE=check; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
hr(){ printf '─%.0s' $(seq 60); echo; }

alive(){ [ -n "$(curl -6 -s --interface "$1" --max-time 8 https://api6.ipify.org 2>/dev/null)" ]; }

show_addrs(){
  for a in $(ip -6 addr show scope global | grep -oP 'inet6 \K[0-9a-f:]+'); do
    ip6=$(curl -6 -s --interface "$a" --max-time 8 https://api6.ipify.org 2>/dev/null)
    if [ -n "$ip6" ]; then
      geo=$(curl -4 -s --max-time 6 "http://ip-api.com/json/$ip6?fields=country,isp" 2>/dev/null \
            | sed 's/[{}"]//g;s/country://;s/isp:/ · /')
      printf '  ✅ %-34s %s\n' "$a" "$geo"
    else
      printf '  ❌ %-34s 不通\n' "$a"
    fi
  done
}

# ── 卸载 ──────────────────────────────────────────────
if [ "$MODE" = uninstall ]; then
  systemctl disable --now v6nat.service 2>/dev/null
  rm -f /etc/systemd/system/v6nat.service /usr/local/bin/v6nat.sh /etc/netplan/99-mtu.yaml
  systemctl daemon-reload 2>/dev/null
  ip6tables -t nat -S POSTROUTING 2>/dev/null | grep -oP -- "-s ${ULA}/128.*--to-source \K[0-9a-f:]+" \
    | while read -r x; do ip6tables -t nat -D POSTROUTING -s "$ULA" -o "$IFACE" -j SNAT --to-source "$x" 2>/dev/null; done
  ip -6 rule del from "$ULA" 2>/dev/null
  ip -6 addr del "$ULA/128" dev lo 2>/dev/null
  netplan apply 2>/dev/null
  say "已卸载（厂商的 dynamicv6 未动）"
  exit 0
fi

# ── 体检 ──────────────────────────────────────────────
if [ "$MODE" = check ]; then
  hr; say "IPv6 出口体检"; hr
  say "网卡 $IFACE  MTU $(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')"
  say "厂商 timer   $(systemctl is-active dynamicv6-client.timer 2>/dev/null)/$(systemctl is-enabled dynamicv6-client.timer 2>/dev/null)"
  say "ULA 服务     $(systemctl is-active v6nat.service 2>/dev/null)/$(systemctl is-enabled v6nat.service 2>/dev/null)"
  say "SNAT 指向    $(ip6tables -t nat -S POSTROUTING 2>/dev/null | grep -oP 'to-source \K[0-9a-f:]+' | head -1 || echo 无)"
  say ""; say "地址状态:"; show_addrs
  exit 0
fi

# ── 部署 ──────────────────────────────────────────────
hr; say "第 1 步  下发住宅 IPv6"; hr
curl -fsSL "$PROV_URL" -o "$PROV" || { say "下载失败"; exit 1; }
DYNAMICV6_AUTO_TIMER=1 bash "$PROV" 2>&1 | grep -E 'lease|applying|configured|ipv6_count' | sed 's/^/  /'

hr; say "第 2 步  修复厂商脚本的缺陷"; hr
ip -6 neigh flush dev "$IFACE"
say "  ✓ 刷新邻居表（厂商脚本不做，ND 失败后不会自动重试）"
cat > /etc/netplan/99-mtu.yaml <<YAML
network:
  version: 2
  ethernets:
    $IFACE:
      mtu: $MTU
YAML
chmod 600 /etc/netplan/99-mtu.yaml
netplan apply 2>/dev/null
say "  ✓ 网卡 MTU 固定为 $MTU 并持久化"
say "    （挂网卡而非路由，厂商 timer 清路由表时碰不到，避免周期性中断）"
say "  等待 ND 收敛..."
sleep 10

say "  修复原生地址（厂商脚本会删掉主表原生路由，导致原生地址失联）"
NAT_ADDR=$(ip -6 addr show scope global | grep -oP 'inet6 \K2401:[0-9a-f:]+' | head -1)
if [ -n "$NAT_ADDR" ] && ! ip -6 rule show | grep -q "from $NAT_ADDR "; then
  NAT_GW=$(echo "$NAT_ADDR" | cut -d: -f1-3)::1
  if ip -6 route replace default via "$NAT_GW" dev "$IFACE" table 16009 onlink 2>/dev/null; then
    ip -6 rule add from "$NAT_ADDR" table 16009 pref 16009 2>/dev/null
    say "  ✓ 原生地址已补策略表 16009 (网关 $NAT_GW)"
  fi
fi
sleep 3

hr; say "第 3 步  地址清单"; hr
show_addrs

if [ -z "$PREFIX" ]; then
  hr; say "第 4 步  选择要绑定固定 ULA 的出口"; hr
  say "  绑定后 3x-ui 里只填 $ULA，真实地址变了自动跟随"
  i=1; declare -a CAND
  for a in $(ip -6 addr show scope global | grep -oP 'inet6 \K[0-9a-f:]+'); do
    alive "$a" || continue
    CAND[$i]=$a; printf '  %d) %s\n' "$i" "$a"; i=$((i+1))
  done
  [ $i -eq 1 ] && { say "  没有可用地址，中止"; exit 1; }
  printf '  选择 [1-%d]，回车跳过: ' $((i-1)); read -r sel
  [ -z "$sel" ] && { say "  已跳过绑定"; exit 0; }
  SEL=${CAND[$sel]:-}
  [ -z "$SEL" ] && { say "  无效选择"; exit 1; }
  PREFIX=$(echo "$SEL" | cut -d: -f1-2)
fi

TABLE=$(ip -6 rule show | grep "$PREFIX" | grep -oE 'lookup [0-9]{5}' | awk '{print $2}' | head -1)
[ -z "$TABLE" ] && { say "找不到前缀 $PREFIX 的策略表"; exit 1; }

hr; say "第 5 步  部署固定 ULA 出口"; hr
say "  前缀 $PREFIX  策略表 $TABLE  固定地址 $ULA"

cat > /usr/local/bin/v6nat.sh <<'INNER'
#!/bin/bash
# 固定 ULA -> 动态住宅 IPv6 的 SNAT 映射，地址变了自动跟随
set -u
FIX=$1; PREFIX=$2; TABLE=$3
IFACE=$(ip -o route show to default | awk '{print $5; exit}')
log(){ echo "[v6nat $(date '+%F %T')] $*"; }
sync_rule(){
  ip -6 addr show dev lo | grep -q "$FIX" || ip -6 addr add "$FIX/128" dev lo 2>/dev/null
  ip -6 rule show | grep -q "from $FIX " || ip -6 rule add from "$FIX" table "$TABLE" pref 15000 2>/dev/null
  cur=$(ip -6 addr show scope global | grep -oP "inet6 \K${PREFIX}[0-9a-f:]*" | head -1)
  [ -z "$cur" ] && { log "前缀 $PREFIX 下无地址，保持原规则"; return; }
  now=$(ip6tables -t nat -S POSTROUTING 2>/dev/null | grep -oP -- "-s ${FIX}/128.*--to-source \K[0-9a-f:]+" | head -1)
  [ "$now" = "$cur" ] && return
  [ -n "$now" ] && ip6tables -t nat -D POSTROUTING -s "$FIX" -o "$IFACE" -j SNAT --to-source "$now" 2>/dev/null
  ip6tables -t nat -A POSTROUTING -s "$FIX" -o "$IFACE" -j SNAT --to-source "$cur"
  log "映射更新 ${now:-无} -> $cur"
}
modprobe ip6table_nat 2>/dev/null
sync_rule
log "监听地址变化，前缀 $PREFIX"
( while true; do sleep 300; sync_rule; done ) &
ip -6 monitor address | while read -r _; do sleep 1; sync_rule; done
INNER
chmod +x /usr/local/bin/v6nat.sh

cat > /etc/systemd/system/v6nat.service <<UNIT
[Unit]
Description=Dynamic IPv6 outbound NAT
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/v6nat.sh $ULA $PREFIX $TABLE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now v6nat.service
sleep 5

hr; say "完成"; hr
say "  SNAT 映射   $(ip6tables -t nat -S POSTROUTING | grep -oP 'to-source \K[0-9a-f:]+' | head -1)"
say "  出口验证   $(curl -6 -s --interface "$ULA" --max-time 12 https://api6.ipify.org 2>/dev/null || echo 失败)"
say ""
say "  3x-ui 出站的「发送通过」填: $ULA"
say "  这个地址永不改变，真实地址变了服务会自动跟随"
