#!/bin/bash
# AetherCloud dynamicv6 一键部署
# 下发住宅 IPv6 + 修复厂商脚本的三个缺陷 + 装固定 ULA 出口
#
# 用法:
#   v6setup.sh                      下发并部署，交互选择要绑的出口
#   v6setup.sh --exit <IPv6>        非交互，指定要用哪个出口地址
#   v6setup.sh --prefix 2001:b011   非交互，直接绑指定前缀
#   v6setup.sh --check              只体检，不改动
#   v6setup.sh --uninstall          卸载本脚本装的东西（不动厂商的）
set -u

ULA=${V6SETUP_ULA:-fd00:6c:7477::1}
MTU=${V6SETUP_MTU:-1400}
PROV=/tmp/dv6.sh
PROV_URL=https://billing.aethercloud.io/dynamicv6/client.sh
SELF_URL=https://raw.githubusercontent.com/Kylin010/aethercloud-v6setup/main/v6setup.sh
SELF_PATH=/usr/local/bin/v6setup.sh
IFACE=$(ip -o route show to default | awk '{print $5; exit}')
MODE=deploy; PREFIX=""; EXIT_ADDR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --exit) EXIT_ADDR=$2; shift 2 ;;
    --prefix) PREFIX=$2; shift 2 ;;
    --check) MODE=check; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*"; }
hr(){ printf '─%.0s' $(seq 60); echo; }

alive(){ [ -n "$(curl -6 -s --interface "$1" --max-time 8 https://api6.ipify.org 2>/dev/null)" ]; }

geo_of(){
  local j; j=$(curl -4 -s --max-time 6 "http://ip-api.com/json/$1?fields=country,isp" 2>/dev/null)
  [ -z "$j" ] && { echo ""; return; }
  if command -v jq >/dev/null 2>&1; then
    echo "$j" | jq -r 'select(.country!=null) | "\(.country) · \(.isp)"' 2>/dev/null
  else
    echo "$j" | sed 's/[{}"]//g;s/country://;s/,isp:/ · /'
  fi
}

all_addrs(){ ip -6 addr show scope global | grep -oP 'inet6 \K[0-9a-f:]+' | awk '!seen[$0]++'; }

show_addrs(){
  for a in $(all_addrs); do
    ip6=$(curl -6 -s --interface "$a" --max-time 8 https://api6.ipify.org 2>/dev/null)
    if [ -n "$ip6" ]; then
      printf '  ✅ %-34s %s\n' "$a" "$(geo_of "$ip6")"
    else
      printf '  ❌ %-34s 不通\n' "$a"
    fi
  done
}

# 历史上出现过 v6nat-tw.service 这类命名，别写死单元名
nat_units(){ ls /etc/systemd/system/ 2>/dev/null | grep -E '^v6nat(-[a-z0-9]+)?\.service$'; }

# 厂商 timer 只有 OnBootSec + OnUnitActiveSec。开机很久之后如果服务本次开机一次都没跑过，
# systemd 会算出 NextElapse=infinity 永久停摆，租约不再续。实测撞到过一台 6 天没续约。
timer_health(){
  systemctl cat dynamicv6-client.timer >/dev/null 2>&1 || { echo "未安装"; return; }
  local nx last
  nx=$(systemctl show dynamicv6-client.timer -p NextElapseUSecMonotonic --value 2>/dev/null)
  last=$(systemctl show dynamicv6-client.timer -p LastTriggerUSec --value 2>/dev/null)
  if [ -z "$nx" ] || [ "$nx" = "infinity" ]; then
    echo "❌ 已停摆，无下次触发（上次 ${last:-未知}）→ systemctl start dynamicv6-client.service"
  else
    echo "✅ $(systemctl is-active dynamicv6-client.timer 2>/dev/null)/$(systemctl is-enabled dynamicv6-client.timer 2>/dev/null)（上次 ${last:-未知}）"
  fi
}

# 默认出口必须实测。ip -6 route get 在 ECMP 多 nexthop 下只报第一条会骗人，
# 而 Linux 的 IPv6 ECMP 按 (源,目的) 哈希，得换几个目的地才看得出分流。
default_exit(){
  local seen="" r nh
  # 真 ECMP 是路由结构上就有多条 nexthop，直接查，别靠探测推断。
  # 厂商 timer 每 2 分钟先删后加默认路由，原生那条(metric 1024)最后才回来，
  # 在这个窗口里主表最优的是住宅备份路由(metric 2048)，探测撞进去就会看到两个出口。
  nh=$(ip -6 route show default 2>/dev/null | grep -c 'nexthop')
  for u in https://api6.ipify.org https://v6.ident.me https://ipv6.icanhazip.com; do
    r=$(curl -6 -s --max-time 8 "$u" 2>/dev/null | tr -d '\r\n')
    [ -n "$r" ] && case " $seen " in *" $r "*) : ;; *) seen="$seen $r" ;; esac
  done
  seen=${seen# }
  [ -z "$seen" ] && { echo "❌ 无 IPv6 默认出口"; return; }
  if [ "$nh" -gt 1 ]; then
    echo "❌ 主表默认路由是 ECMP（$nh 条 nexthop），按目的地分流:"
    for x in $seen; do echo "             $x  $(geo_of "$x")"; done
    echo "             修: /usr/local/bin/dynamicv6-client.sh $IFACE 跑一次，官方脚本会收敛成单 nexthop"
  elif [ "$(echo "$seen" | wc -w)" -gt 1 ]; then
    echo "⚠️  探测到多个出口，但主表是单 nexthop —— 多半撞上了厂商 timer 重建路由的瞬间窗口:"
    for x in $seen; do echo "             $x  $(geo_of "$x")"; done
    echo "             隔一会再跑一次 --check 确认，持续出现才是真问题"
  else
    echo "$seen  $(geo_of "$seen")"
  fi
}

install_self(){
  if [ -f "$0" ] && [ -r "$0" ]; then cp -f "$0" "$SELF_PATH" 2>/dev/null
  else curl -fsSL "$SELF_URL" -o "$SELF_PATH" 2>/dev/null; fi
  [ -s "$SELF_PATH" ] && chmod +x "$SELF_PATH"
}

# ── 卸载 ──────────────────────────────────────────────
if [ "$MODE" = uninstall ]; then
  for u in $(nat_units); do
    systemctl disable --now "$u" 2>/dev/null
    rm -f "/etc/systemd/system/$u"
  done
  rm -f /usr/local/bin/v6nat.sh /etc/netplan/99-mtu.yaml "$SELF_PATH"
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
  say "网卡         $IFACE  MTU $(ip link show "$IFACE" | grep -oP 'mtu \K[0-9]+')"
  say "MTU 持久化   $([ -f /etc/netplan/99-mtu.yaml ] && grep -oP 'mtu: \K[0-9]+' /etc/netplan/99-mtu.yaml || echo '❌ 缺失')"
  say "厂商 timer   $(timer_health)"
  U=$(nat_units | head -1)
  if [ -n "$U" ]; then
    say "ULA 服务     $U  $(systemctl is-active "$U" 2>/dev/null)/$(systemctl is-enabled "$U" 2>/dev/null)"
  else
    say "ULA 服务     ❌ 未安装"
  fi
  say "SNAT 指向    $(ip6tables -t nat -S POSTROUTING 2>/dev/null | grep -oP 'to-source \K[0-9a-f:]+' | head -1 || echo 无)"
  say "线路一致性   $(consistency)"
  say "默认 v6 出口 $(default_exit)"
  say "默认 v4 出口 $(curl -4 -s --max-time 8 https://api4.ipify.org 2>/dev/null || echo 失败)"
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
# 主表交给官方脚本，本脚本不碰；它自己会 pin src 并收敛成单 nexthop。
# 这里只补 timer 的 OnUnitActiveSec 锚点，防止它算出 infinity 永久停摆。
systemctl enable dynamicv6-client.timer >/dev/null 2>&1
systemctl start dynamicv6-client.service >/dev/null 2>&1
say "  ✓ 厂商 timer 锚点已刷新  $(timer_health)"
install_self && say "  ✓ 本脚本已装到 $SELF_PATH（之后可直接 v6setup.sh --check）"
say "  等待 ND 收敛..."
sleep 10


hr; say "第 3 步  地址清单"; hr
show_addrs

if [ -n "$EXIT_ADDR" ]; then
  ip -6 addr show scope global | grep -q "\b${EXIT_ADDR}\b" || { say "本机没有地址 $EXIT_ADDR"; exit 1; }
  PREFIX=$(uniq_prefix "$EXIT_ADDR")
  hr; say "第 4 步  使用指定出口"; hr
  say "  出口 $EXIT_ADDR"
  say "  跟随前缀 $PREFIX"
elif [ -z "$PREFIX" ]; then
  hr; say "第 4 步  选择要绑定固定 ULA 的出口"; hr
  say "  绑定后 3x-ui 里只填 $ULA，真实地址变了自动跟随"
  i=1; declare -a CAND
  for a in $(all_addrs); do
    case "$a" in fd[0-9a-f]*|fc[0-9a-f]*) continue ;; esac
    alive "$a" || continue
    CAND[$i]=$a; printf '  %d) %s\n' "$i" "$a"; i=$((i+1))
  done
  [ $i -eq 1 ] && { say "  没有可用地址，中止"; exit 1; }
  printf '  选择 [1-%d]，回车跳过: ' $((i-1)); read -r sel
  [ -z "$sel" ] && { say "  已跳过绑定"; exit 0; }
  SEL=${CAND[$sel]:-}
  [ -z "$SEL" ] && { say "  无效选择"; exit 1; }
  PREFIX=$(uniq_prefix "$SEL")
fi

BIND=$(ip -6 addr show scope global | grep -oP "inet6 \K${PREFIX}[0-9a-f:]*" | head -1)
[ -z "$BIND" ] && { say "前缀 $PREFIX 下没有地址"; exit 1; }
TABLE=$(ip -6 rule show | grep "from $BIND " | grep -oE 'lookup [0-9]+' | awk '{print $2}' | head -1)
[ -z "$TABLE" ] && { say "找不到 $BIND 的策略表"; exit 1; }

hr; say "第 5 步  部署固定 ULA 出口"; hr
say "  出口 $BIND  前缀 $PREFIX  策略表 $TABLE  固定地址 $ULA"

for u in $(nat_units | grep -v '^v6nat\.service$'); do
  systemctl disable --now "$u" 2>/dev/null
  rm -f "/etc/systemd/system/$u"
  say "  ✓ 清掉旧单元 $u"
done

cat > /usr/local/bin/v6nat.sh <<'INNER'
#!/bin/bash
# 固定 ULA -> 动态住宅 IPv6 的 SNAT 映射，地址变了自动跟随
set -u
FIX=$1; PREFIX=$2; FALLBACK=${3:-}
IFACE=$(ip -o route show to default | awk '{print $5; exit}')
log(){ echo "[v6nat $(date '+%F %T')] $*"; }
sync_rule(){
  ip -6 addr show dev lo | grep -q "$FIX" || ip -6 addr add "$FIX/128" dev lo 2>/dev/null

  cur=$(ip -6 addr show scope global | grep -oP "inet6 \K${PREFIX}[0-9a-f:]*" | head -1)
  [ -z "$cur" ] && { log "前缀 $PREFIX 下无地址，保持原规则"; return; }

  # 表号现查不存。厂商每 2 分钟给每个住宅地址刷一条 from <地址> lookup <表>，那是权威来源。
  # 部署时写死表号的话，它和 PREFIX 会各自老化，最后漂移成「A 线的源地址走 B 线的隧道」。
  tbl=$(ip -6 rule show | grep "from $cur " | grep -oE 'lookup [0-9]+' | awk '{print $2}' | head -1)
  [ -z "$tbl" ] && tbl=$FALLBACK
  [ -z "$tbl" ] && { log "查不到 $cur 的策略表，保持原规则"; return; }

  now_tbl=$(ip -6 rule show | grep "from $FIX " | grep -oE 'lookup [0-9]+' | awk '{print $2}' | head -1)
  if [ "$now_tbl" != "$tbl" ]; then
    [ -n "$now_tbl" ] && ip -6 rule del from "$FIX" table "$now_tbl" 2>/dev/null
    ip -6 rule add from "$FIX" table "$tbl" pref 15000 2>/dev/null
    log "策略表更新 ${now_tbl:-无} -> $tbl"
  fi

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
systemctl enable v6nat.service >/dev/null 2>&1
# 必须 restart 而不是 --now：改出口时单元文件变了但服务还在跑，
# --now 对已经 active 的单元不做任何事，老进程会带着老参数继续跑。
systemctl restart v6nat.service
sleep 6

hr; say "完成"; hr
say "  SNAT 映射    $(ip6tables -t nat -S POSTROUTING | grep -oP 'to-source \K[0-9a-f:]+' | head -1)"
say "  ULA 出口     $(curl -6 -s --interface "$ULA" --max-time 12 https://api6.ipify.org 2>/dev/null || echo 失败)"
say "  线路一致性   $(consistency)"
say "  默认 v6 出口 $(default_exit)"
say ""
say "  3x-ui 出站的「发送通过」填: $ULA"
say "  这个地址永不改变，真实地址变了服务会自动跟随"
say "  之后体检: v6setup.sh --check"
