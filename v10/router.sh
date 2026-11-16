#!/bin/sh
# AV10: single-process Zray + Hev IPv4 TCP/UDP on ASUS RT-N12 C1 / FreshTomato.
# Binaries and script are PUBLIC; private VLESS configuration stays on the ASUS.
# This script is intentionally POSIX/BusyBox ash and does not require JFFS.

LAN=192.168.50.0/24
ROUTER=192.168.50.1
DNS=1.1.1.1
TABLE=125
PREF=12029
CHAIN=AV10FW
TUN=tun0
D=/tmp/av10
SELF=/tmp/av10-router.sh
ZBIN=/tmp/av9-zray
HBIN=/tmp/av9-hev
OLD=/tmp/zray-auto
OLDCONF=/tmp/zray-auto.json
ZCONF=$D/zray.json
HCONF=$D/hev.yml
ZLOG=$D/zray.log
HLOG=$D/hev.log
STATE=$D/route.state
PENDING=$D/pending
ACTIVE=$D/persist.active
RPF_ALL=$D/rpf.all
RPF_TUN=$D/rpf.tun
V6_MARK=$D/v6.mark
ZMD5='cbf9926c66fd42d0d454ab3f14914f8a'
HMD5='2c265b5d939706d4bd0e95eb0c673517'
REPO='lwdppwrk/asus-zray'

say(){ echo "$*"; }
err(){ echo "ERROR: $*" >&2; }
fail(){ err "$*"; exit 1; }
initdir(){ mkdir -p "$D" || fail "Cannot mkdir $D"; chmod 700 "$D"; }
# pidof on Linux 2.6 includes zombies. A zombie is not a live proxy.
live(){
    for p in $(pidof "$1" 2>/dev/null); do
        [ -r "/proc/$p/stat" ] || continue
        s=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
        case "$s" in Z|X|'') ;; *) echo "$p" ;; esac
    done
}
stopname(){ for p in $(live "$1"); do kill "$p" 2>/dev/null || :; done; }
portup(){ netstat -lnt 2>/dev/null | grep -q "192\\.168\\.50\\.1:$1[[:space:]]"; }
memkb(){ free 2>/dev/null | awk '/buffers\/cache:/{print $NF; exit}'; }
memmin(){ n=$(memkb); [ -n "$n" ] && [ "$n" -ge "$1" ]; }
filemd5(){ md5sum "$1" 2>/dev/null | awk '{print $1}'; }
checkmd5(){ [ -s "$1" ] && [ "$(filemd5 "$1")" = "$2" ]; }
rawurl(){ echo "https://raw.githubusercontent.com/$REPO/$1/v10/$2"; }
fetch(){
    u=$1; dst=$2
    rm -f "$dst"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dst" "$u" && [ -s "$dst" ] && return 0
    fi
    rm -f "$dst"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 12 -o "$dst" "$u" && [ -s "$dst" ] && return 0
    fi
    return 1
}
check_old(){
    [ -x "$OLD" ] && [ -s "$OLDCONF" ] || fail 'Old Zray or config unavailable; original WAN startup not ready'
    grep -Eq '"listen"[[:space:]]*:[[:space:]]*"192\.168\.50\.1:10808"' "$OLDCONF" || fail 'Old SOCKS listener differs'
    grep -Eq '"redirect"[[:space:]]*:[[:space:]]*"192\.168\.50\.1:12345"' "$OLDCONF" || fail 'Old redirect differs'
    grep -Eq '"flow"[[:space:]]*:[[:space:]]*"none"' "$OLDCONF" || fail 'Expected flow none'
    grep -q '"max_connections"' "$OLDCONF" || fail 'Missing max_connections'
}
conf(){
    check_old
    sed -e 's/"max_connections"[[:space:]]*:[[:space:]]*[0-9][0-9]*/"max_connections":64/' \
        -e 's/"stats_interval_s"[[:space:]]*:[[:space:]]*[0-9][0-9]*/"stats_interval_s":300/' \
        "$OLDCONF" > "$ZCONF" || fail 'Cannot write config'
    chmod 600 "$ZCONF"
    grep -q '"max_connections":64' "$ZCONF" || fail 'Slot count not set'
    cat > "$HCONF" <<'YAML'
tunnel:
  name: tun0
  mtu: 1400
  ipv4: 198.18.0.1
  icmp: 'off'
  offload:
    tso: false
    uso: false
    jumbo: false
socks5:
  address: 192.168.50.1
  port: 10808
  udp: 'udp'
misc:
  task-stack-size: 32768
  tcp-buffer-size: 4096
  udp-recv-buffer-size: 16384
  udp-copy-buffer-nums: 2
  max-session-count: 36
  limit-nofile: 256
  connect-timeout: 10000
  log-level: warn
YAML
    chmod 600 "$HCONF"
}
check_v6(){
    # IPv6 forwarding already off is safe even if ip6tables is absent.
    if [ -e /proc/sys/net/ipv6/conf/all/forwarding ] &&
       [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ]; then
        command -v ip6tables >/dev/null 2>&1 || fail 'IPv6 forwarding ON, ip6tables unavailable'
        ip6tables -L FORWARD -n >/dev/null 2>&1 || fail 'IPv6 firewall unavailable'
    fi
}
conflicts(){
    ip rule show >/dev/null 2>&1 || fail 'Policy routing unavailable'
    for pref in 12024 12025 12026 12027 12028 12029; do
        ip rule show | grep -q "^${pref}:" && fail "Routing policy $pref already exists"
    done
    [ -z "$(ip route show table "$TABLE" 2>/dev/null)" ] || fail 'Routing table 125 in use'
    iptables -L "$CHAIN" -n >/dev/null 2>&1 && fail 'Firewall chain AV10FW already exists'
    ifconfig "$TUN" >/dev/null 2>&1 && fail 'tun0 already in use'
}
preflight(){
    initdir
    [ ! -e "$PENDING" ] && [ ! -e "$STATE" ] || fail 'Previous activation is in progress'
    [ -x "$ZBIN" ] && [ -x "$HBIN" ] || fail 'New binaries missing / not executable'
    checkmd5 "$ZBIN" "$ZMD5" || fail 'Zray checksum mismatch'
    checkmd5 "$HBIN" "$HMD5" || fail 'Hev checksum mismatch'
    check_old
    [ -n "$(live zray-auto)" ] && portup 10808 && portup 12345 || fail 'Old VPN not running'
    [ -z "$(live av9-zray)" ] && [ -z "$(live av9-hev)" ] || fail 'New process already running'
    [ -e /dev/net/tun ] || fail '/dev/net/tun unavailable'
    [ -e /proc/sys/net/ipv4/conf/all/rp_filter ] || fail 'rp_filter unavailable'
    iptables -t nat -L ZRAY_NAT -n >/dev/null 2>&1 || fail 'Old NAT chain unavailable'
    conflicts
    check_v6
    memmin 8192 || fail 'Insufficient RAM before cutover: need 8 MiB free (excluding cache)'
    # Reserve NVRAM only on first install. At reboot the hook already occupies that space.
    if ! nvram get script_wanup 2>/dev/null | grep -q '^#AV10-BEGIN'; then
        nvleft=$(nvram show 2>&1 | sed -n 's/.*(\([0-9][0-9]*\) left).*/\1/p' | tail -n 1)
        [ -n "$nvleft" ] || fail 'Cannot measure free NVRAM for boot hook'
        [ "$nvleft" -ge 700 ] || fail "NVRAM free space only $nvleft bytes; cannot install safely"
    fi
    conf
    say 'PREFLIGHT OK: binaries, old config, 8MiB RAM, TUN and firewall ready.'
}
routeoff(){
    # Delete PBR first; existing WAN-protection rules remain in force.
    ip rule del pref "$PREF" from "$LAN" lookup "$TABLE" 2>/dev/null || :
    ip route del default dev "$TUN" table "$TABLE" 2>/dev/null || :
    ip route del "$LAN" dev br0 table "$TABLE" 2>/dev/null || :
    if [ -e "$STATE" ]; then
        for proto in udp tcp; do
            iptables -t nat -D PREROUTING -i br0 -s "$LAN" -d "$ROUTER" -p "$proto" --dport 53 -j DNAT --to-destination "$DNS" 2>/dev/null || :
        done
        iptables -t nat -D ZRAY_NAT -s "$LAN" -j RETURN 2>/dev/null || :
        iptables -D FORWARD -i br0 -s "$LAN" -j "$CHAIN" 2>/dev/null || :
        iptables -D FORWARD -i "$TUN" -o br0 -d "$LAN" -j ACCEPT 2>/dev/null || :
        iptables -F "$CHAIN" 2>/dev/null || :
        iptables -X "$CHAIN" 2>/dev/null || :
        if [ -e "$V6_MARK" ]; then
            ip6tables -D FORWARD -i br0 -j DROP 2>/dev/null || :
            ip6tables -D INPUT -i br0 -j DROP 2>/dev/null || :
        fi
    fi
    if [ -s "$RPF_ALL" ]; then cat "$RPF_ALL" > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || :; fi
    if [ -s "$RPF_TUN" ] && [ -e /proc/sys/net/ipv4/conf/tun0/rp_filter ]; then cat "$RPF_TUN" > /proc/sys/net/ipv4/conf/tun0/rp_filter 2>/dev/null || :; fi
    rm -f "$STATE" "$RPF_ALL" "$RPF_TUN" "$V6_MARK"
}
restore(){
    if [ -n "$(live zray-auto)" ] && portup 10808 && portup 12345; then return 0; fi
    if portup 10808; then return 1; fi
    [ -x "$OLD" ] && [ -s "$OLDCONF" ] || return 1
    "$OLD" "$OLDCONF" </dev/null >>"$D/old.log" 2>&1 &
    sleep 3
    portup 10808 && portup 12345
}
removehook(){
    wan=$(nvram get script_wanup 2>/dev/null)
    case "$wan" in *'#AV10-BEGIN'*)
        old=$(printf '%s\n' "$wan" | sed '/^#AV10-BEGIN$/,/^#AV10-END$/d')
        nvram set script_wanup="$old" && nvram commit || err 'Failed to remove boot hook from NVRAM'
        ;;
    esac
}
rollback(){
    initdir
    rm -f "$PENDING"
    routeoff
    stopname av9-hev
    stopname av9-zray
    sleep 2
    if restore; then
        say 'ROLLBACK OK: original Zray and web-VPN firewall restored'
    else
        err 'ROLLBACK INCOMPLETE: reboot router using power (NOT factory reset)'
    fi
    # Even after reboot, rollback must be able to disable the persistent WAN Up hook.
    removehook
    rm -f "$ACTIVE"
}
start_services(){
    stopname zray-auto
    sleep 2
    ! portup 10808 && ! portup 12345 || return 1
    "$ZBIN" "$ZCONF" </dev/null > "$ZLOG" 2>&1 &
    sleep 3
    [ -n "$(live av9-zray)" ] && portup 10808 && portup 12345 && grep -q '64 total slots' "$ZLOG" && memmin 6144 || return 1
    "$HBIN" "$HCONF" </dev/null > "$HLOG" 2>&1 &
    sleep 3
    [ -n "$(live av9-hev)" ] && ifconfig tun0 >/dev/null 2>&1 && memmin 5120 || return 1
    return 0
}
start_route(){
    [ -e /proc/sys/net/ipv4/conf/tun0/rp_filter ] || return 1
    cat /proc/sys/net/ipv4/conf/all/rp_filter > "$RPF_ALL" || return 1
    cat /proc/sys/net/ipv4/conf/tun0/rp_filter > "$RPF_TUN" || return 1
    # State is written before first mutation; failure cleanup removes partial rules.
    echo 1 > "$STATE" || return 1
    iptables -N "$CHAIN" || return 1
    iptables -A "$CHAIN" -d "$LAN" -j ACCEPT || return 1
    iptables -A "$CHAIN" -o "$TUN" -p tcp -j ACCEPT || return 1
    iptables -A "$CHAIN" -o "$TUN" -p udp -j ACCEPT || return 1
    iptables -A "$CHAIN" -j DROP || return 1
    iptables -I FORWARD 1 -i br0 -s "$LAN" -j "$CHAIN" || return 1
    iptables -I FORWARD 1 -i "$TUN" -o br0 -d "$LAN" -j ACCEPT || return 1
    if [ -e /proc/sys/net/ipv6/conf/all/forwarding ] &&
       [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding)" = 1 ]; then
        # Mark before change, so rollback can remove a partially installed IPv6 guard.
        touch "$V6_MARK"
        ip6tables -I FORWARD 1 -i br0 -j DROP || return 1
        ip6tables -I INPUT 1 -i br0 -j DROP || return 1
    fi
    printf '0\n' > /proc/sys/net/ipv4/conf/all/rp_filter || return 1
    printf '0\n' > /proc/sys/net/ipv4/conf/tun0/rp_filter || return 1
    ip route add "$LAN" dev br0 table "$TABLE" || return 1
    ip route add default dev "$TUN" table "$TABLE" || return 1
    iptables -t nat -I ZRAY_NAT 1 -s "$LAN" -j RETURN || return 1
    iptables -t nat -I PREROUTING 1 -i br0 -s "$LAN" -d "$ROUTER" -p udp --dport 53 -j DNAT --to-destination "$DNS" || return 1
    iptables -t nat -I PREROUTING 1 -i br0 -s "$LAN" -d "$ROUTER" -p tcp --dport 53 -j DNAT --to-destination "$DNS" || return 1
    ip rule add pref "$PREF" from "$LAN" lookup "$TABLE" || return 1
    return 0
}
watchdog(){
    # A single low-rate BusyBox shell; no second proxy process.
    while [ -e "$STATE" ]; do
        sleep 8
        [ -e "$STATE" ] || break
        if [ -z "$(live av9-zray)" ] || [ -z "$(live av9-hev)" ] || ! portup 10808 || ! memmin 4096; then
            echo 'WATCHDOG: lost service or less than 4 MiB RAM' >> "$D/watchdog.log"
            sh "$SELF" rollback >> "$D/watchdog.log" 2>&1
            break
        fi
        # A firewall reload must not silently leave VPN routing without its kill-switch.
        if ! iptables -L "$CHAIN" -n >/dev/null 2>&1 || ! iptables -L FORWARD -n 2>/dev/null | grep -q "$CHAIN" || ! ip rule show | grep -q "^${PREF}:"; then
            echo 'WATCHDOG: firewall/policy missing' >> "$D/watchdog.log"
            sh "$SELF" rollback >> "$D/watchdog.log" 2>&1
            break
        fi
        for l in "$ZLOG" "$HLOG"; do
            [ -f "$l" ] || continue
            sz=$(wc -c < "$l" 2>/dev/null)
            [ -n "$sz" ] && [ "$sz" -gt 65536 ] && : > "$l"
        done
    done
}
activate(){
    rev=$1
    case "$rev" in *[!0-9a-f]*|'') fail 'Invalid pinned Git revision' ;; esac
    [ "${#rev}" -eq 40 ] || fail 'Pinned revision must be 40 hex chars'
    preflight
    echo "$rev" > "$D/revision"
    token="$(date +%s).$$"
    echo "$token" > "$PENDING" || fail 'Cannot arm rollback'
    ( sleep 180; [ "$(cat "$PENDING" 2>/dev/null)" = "$token" ] && sh "$SELF" rollback ) </dev/null >"$D/timeout.log" 2>&1 &
    if ! start_services; then rollback; fail 'New Zray/Hev could not start; old Zray restored'; fi
    if ! start_route; then rollback; fail 'VPN routes/firewall could not be installed; old Zray restored'; fi
    ( watchdog ) </dev/null >"$D/watchdog-run.log" 2>&1 &
    say 'ACTIVATION PROVISIONAL: one Zray, one Hev, IPv4 TCP/UDP TUN, kill-switch.'
    say 'Installer will verify connectivity automatically; no action needed on router.'
}
boot(){
    rev=$1
    case "$rev" in *[!0-9a-f]*|'') fail 'Invalid pinned revision' ;; esac
    [ "${#rev}" -eq 40 ] || fail 'Invalid revision length'
    initdir
    # WAN Up may run several times; do not restart healthy instance.
    if [ -e "$STATE" ] && [ -n "$(live av9-zray)" ] && [ -n "$(live av9-hev)" ]; then
        # Original WAN script may launch a second old proxy on WAN reconnect.
        [ -n "$(live zray-auto)" ] && stopname zray-auto
        say 'AV10 already active'
        return 0
    fi
    [ -e "$STATE" ] && fail 'Stale route.state; watchdog/reboot should recover'
    i=0
    until [ -n "$(live zray-auto)" ] && portup 10808; do
        i=$((i+1)); [ "$i" -le 15 ] || fail 'Original WAN startup never finished'
        sleep 3
    done
    memmin 8192 || fail 'Insufficient RAM to boot v10'
    [ "$(df -k /tmp | awk 'NR==2{print $4}')" -ge 5120 ] || fail 'Not enough /tmp storage'
    # Fetch pinned artifacts. No VLESS credentials are ever sent to GitHub.
    if ! checkmd5 "$ZBIN" "$ZMD5"; then
        fetch "$(rawurl "$rev" zray-mipsel)" "$ZBIN.dl" || fail 'Cannot download Zray'
        checkmd5 "$ZBIN.dl" "$ZMD5" || fail 'Zray download checksum mismatch'
        mv "$ZBIN.dl" "$ZBIN" || fail 'Cannot stage Zray'
    fi
    if ! checkmd5 "$HBIN" "$HMD5"; then
        fetch "$(rawurl "$rev" hev-mipsel)" "$HBIN.dl" || fail 'Cannot download Hev'
        checkmd5 "$HBIN.dl" "$HMD5" || fail 'Hev download checksum mismatch'
        mv "$HBIN.dl" "$HBIN" || fail 'Cannot stage Hev'
    fi
    chmod 700 "$ZBIN" "$HBIN"
    # Keep original boot functional even if a new binary fails.
    activate "$rev"
    rm -f "$PENDING"   # router-owned boot, no external installer acknowledgement required
    touch "$ACTIVE"
    say 'AV10 BOOT: active; original boot retained as fallback.'
}
commit(){
    rev=$1
    s_md5=$2
    [ -e "$PENDING" ] && [ -e "$STATE" ] || fail 'No active provisional deployment'
    [ -n "$(live av9-zray)" ] && [ -n "$(live av9-hev)" ] || fail 'Processes disappeared before commit'
    [ -z "$(live zray-auto)" ] || fail 'Two Zray processes detected'
    portup 10808 && portup 12345 || fail 'Unified Zray listeners disappeared'
    memmin 4096 || fail 'RAM too low to persist'
    case "$s_md5" in *[!0-9a-f]*|'') fail 'Invalid script checksum' ;; esac
    [ "${#s_md5}" -eq 32 ] || fail 'Invalid script checksum length'
    wan=$(nvram get script_wanup) || fail 'Cannot read WAN Up script'
    case "$wan" in *'#AV10-BEGIN'*) fail 'AV10 already in WAN Up script';; esac
    # Preserve old startup as-is. New hook is prepended so even a trailing exit cannot skip it.
    url="https://raw.githubusercontent.com/$REPO/$rev/v10/router.sh"
    hook="#AV10-BEGIN
( sleep 25; wget -q -O /tmp/av10-router.sh '$url' && [ \"\$(md5sum /tmp/av10-router.sh | awk '{print \$1}')\" = '$s_md5' ] && chmod 700 /tmp/av10-router.sh && sh /tmp/av10-router.sh boot '$rev' ) </dev/null >/tmp/av10-boot.log 2>&1 &
#AV10-END"
    # Check NVRAM headroom without printing any sensitive stored values.
    left=$(nvram show 2>&1 | sed -n 's/.*(\([0-9][0-9]*\) left).*/\1/p' | tail -n 1)
    need=$((${#hook}+256))
    [ -n "$left" ] || fail 'Cannot determine available NVRAM bytes; refusing commit'
    [ "$left" -ge "$need" ] || fail "NVRAM has ${left} bytes free; need at least $need"
    nvram set script_wanup="$hook
$wan" || fail 'NVRAM update failed'
    if ! nvram commit; then
        nvram set script_wanup="$wan"; nvram commit
        fail 'NVRAM commit failed; original restored'
    fi
    case "$(nvram get script_wanup)" in *'#AV10-BEGIN'*'#AV10-END'*) :;; *)
        nvram set script_wanup="$wan"; nvram commit; fail 'NVRAM verification failed; original restored';;
    esac
    touch "$ACTIVE"
    rm -f "$PENDING"
    say 'INSTALL COMPLETE: single Zray + Hev, all LAN TCP/UDP via TUN, boot hook saved.'
}
status(){
    [ -e "$STATE" ] && say 'ALL LAN: TUN ACTIVE' || say 'ALL LAN: ORIGINAL MODE'
    [ -e "$PENDING" ] && say 'CUTOVER: PENDING AUTO-ROLLBACK' || :
    [ -e "$ACTIVE" ] && say 'BOOT HOOK: committed (current session)' || :
    [ -n "$(live zray-auto)" ] && say 'OLD ZRAY: RUNNING' || :
    [ -n "$(live av9-zray)" ] && say 'NEW ZRAY: RUNNING' || :
    [ -n "$(live av9-hev)" ] && say 'HEV: RUNNING' || :
    netstat -lnt 2>/dev/null | grep -E '192\.168\.50\.1:(10808|12345)' || :
    ip rule show 2>/dev/null | grep "^${PREF}:" || :
    ip route show table "$TABLE" 2>/dev/null || :
    free || :
}
case "${1:-}" in
    preflight) preflight ;;
    activate) activate "${2:-}" ;;
    commit) commit "${2:-}" "${3:-}" ;;
    boot) boot "${2:-}" ;;
    rollback|off) rollback ;;
    status) status ;;
    *) say 'Usage: router.sh preflight|activate COMMIT|commit COMMIT SCRIPTMD5|boot COMMIT|rollback|status'; exit 2;;
esac
