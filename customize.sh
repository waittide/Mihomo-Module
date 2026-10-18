#!/system/bin/sh
# 安装脚本
# 环境由 root 管理器提供: $MODPATH $TMPDIR $ZIPFILE ui_print abort set_perm set_perm_recursive

SKIPUNZIP=1

# ---------------------------------------------------------------- 输出

ui_print_line() { ui_print "- $*"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 环境检查

check_env() {
    [ -n "$MODPATH" ] || abort "! 缺少 MODPATH 环境变量"

    case "$(getprop ro.product.cpu.abi 2>/dev/null)" in
        arm64*) target_arch="arm64-v8a" ;;
        armeabi*) target_arch="armeabi-v7a" ;;
        x86_64) target_arch="x86_64" ;;
        *)
            ui_print "! 未识别的 CPU 架构: $(getprop ro.product.cpu.abi 2>/dev/null)"
            abort "! 目前仅支持 arm64-v8a / armeabi-v7a / x86_64"
            ;;
    esac
    ui_print_line "架构: ${target_arch}"

    # busybox 用于 setuidgid / unzip 等
    busybox=""
    for b in /data/adb/ap/bin/busybox /data/adb/ksu/bin/busybox \
             /data/adb/magisk/busybox /data/adb/magisk/busybox.static; do
        [ -x "$b" ] && { busybox="$b"; break; }
    done
    [ -n "$busybox" ] || busybox="$(command -v busybox 2>/dev/null)"
    [ -n "$busybox" ] && ui_print_line "busybox: ${busybox}"

    if [ -z "$busybox" ]; then
        ui_print "! 未找到 busybox，内核将以默认用户组启动（高版本内核可能无法解析策略）"
    fi
}

# ---------------------------------------------------------------- 解包

extract_files() {
    ui_print_line "解压模块文件"
    if [ -n "$busybox" ] && [ -x "$busybox" ]; then
        "$busybox" unzip -oq "$ZIPFILE" -d "$MODPATH" || abort "! 解压失败"
    else
        unzip -oq "$ZIPFILE" -d "$MODPATH" || abort "! 解压失败"
    fi
    rm -rf "$MODPATH/META-INF" 2>/dev/null
    # 允许的残留（自定义脚本无需保留）
    rm -f "$MODPATH/customize.sh" 2>/dev/null
}

stage_binary() {
    _bin="$MODPATH/bin/mihomo"
    if [ -f "$_bin" ]; then
        chmod 0755 "$_bin"
        ui_print_line "内核: $(du -h "$_bin" 2>/dev/null | cut -f1) ($(basename "$_bin"))"
        return 0
    fi
    ui_print "! 安装包内未找到 bin/mihomo"
    ui_print "! 安装后请手动放入 /data/adb/mihomo/bin/mihomo (chmod 0755)"
    return 1
}

# ---------------------------------------------------------------- 能力探测

# TPROXY: 能不能建 TPROXY 规则
probe_tproxy() {
    probe_tproxy_reason=""
    if ! has_cmd iptables; then
        probe_tproxy_reason="系统缺少 iptables"
        return 1
    fi
    if ! iptables -w 100 -t mangle -N MIHOMO_PROBE >/dev/null 2>&1; then
        probe_tproxy_reason="iptables 无法创建 mangle 链（内核可能未加载 xt_TPROXY/xt_mangle）"
        return 1
    fi
    if ! iptables -w 100 -t mangle -A MIHOMO_PROBE -p tcp -j TPROXY \
            --on-port 1 --tproxy-mark 0x1/0x1 >/dev/null 2>&1; then
        probe_tproxy_reason="内核不支持 TPROXY 目标（缺少 xt_TPROXY 模块）"
        iptables -w 100 -t mangle -F MIHOMO_PROBE >/dev/null 2>&1
        iptables -w 100 -t mangle -X MIHOMO_PROBE >/dev/null 2>&1
        return 1
    fi
    iptables -w 100 -t mangle -F MIHOMO_PROBE >/dev/null 2>&1
    iptables -w 100 -t mangle -X MIHOMO_PROBE >/dev/null 2>&1

    if ! ip -4 rule show >/dev/null 2>&1 || ! ip -4 route show table 1 >/dev/null 2>&1; then
        probe_tproxy_reason="系统缺少 ip 命令，无法建立策略路由"
        return 1
    fi
    return 0
}

# TUN: 真的有 /dev/tun 并且内核能把网卡拉起来
probe_tun() {
    probe_tun_reason=""
    if [ ! -e /dev/net/tun ] && [ ! -e /dev/tun ]; then
        probe_tun_reason="设备没有 /dev/tun 或 /dev/net/tun（内核未开启 TUN 支持）"
        return 1
    fi

    _bin="$MODPATH/bin/mihomo"
    if [ ! -x "$_bin" ]; then
        # 没有内核就没法真启探测，只能退回静态判断
        ui_print_line "未携带内核，TUN 仅做静态判断（/dev/tun 存在）"
        return 0
    fi

    _probe_dir="$TMPDIR/mihomo_probe"
    mkdir -p "$_probe_dir"
    cat > "$_probe_dir/probe.yaml" <<EOF
log-level: silent
tun:
  enable: true
  stack: mixed
  device: mihomo_probe
  mtu: 1500
  auto-route: false
  auto-detect-interface: false
EOF

    ( "$_bin" -d "$_probe_dir" -f "$_probe_dir/probe.yaml" > "$_probe_dir/probe.log" 2>&1 & echo $! > "$_probe_dir/probe.pid" )

    _i=0
    _ok=""
    while [ $_i -lt 20 ]; do
        sleep 0.3
        if ip -o link show mihomo_probe >/dev/null 2>&1; then
            _ok="1"
            break
        fi
        _i=$((_i + 1))
    done

    if [ -f "$_probe_dir/probe.pid" ]; then
        kill "$(cat "$_probe_dir/probe.pid")" 2>/dev/null
        sleep 0.3
        kill -9 "$(cat "$_probe_dir/probe.pid")" 2>/dev/null
    fi

    if [ -z "$_ok" ]; then
        probe_tun_reason="TUN 网卡创建失败: $(grep -iE 'tun|error' "$_probe_dir/probe.log" 2>/dev/null | tail -2 | tr '\n' ' ')"
        [ -n "$probe_tun_reason" ] || probe_tun_reason="TUN 网卡创建超时"
        rm -rf "$_probe_dir"
        return 1
    fi

    rm -rf "$_probe_dir"
    ui_print_line "TUN 探测通过（成功创建 mihomo_probe 网卡）"
    return 0
}

# ---------------------------------------------------------------- 交互选择

wait_key() {
    # $1 = 超时秒数；输出 UP / DOWN / TIMEOUT
    # 用常驻 getevent -l 收集事件再轮询：逐个 `getevent -lc 1` 在这类设备上
    # 会因为要枚举输入设备而漏掉按键（实测常常读不到），常驻流才稳定。
    _ev="${TMPDIR:-/tmp}/mihomo_key.$$"
    rm -f "$_ev"
    getevent -l > "$_ev" 2>/dev/null &
    _gpid=$!
    _start=$(date +%s)
    _ret=""
    while true; do
        if grep -q KEY_VOLUMEUP "$_ev" 2>/dev/null; then
            _ret="UP"
            break
        fi
        if grep -q KEY_VOLUMEDOWN "$_ev" 2>/dev/null; then
            _ret="DOWN"
            break
        fi
        if [ $(( $(date +%s) - _start )) -ge "$1" ]; then
            _ret="TIMEOUT"
            break
        fi
        sleep 0.2
    done
    kill "$_gpid" 2>/dev/null
    wait "$_gpid" 2>/dev/null
    rm -f "$_ev"
    echo "$_ret"
}

select_network_mode() {
    tproxy_ok=""
    tun_ok=""
    probe_tproxy && tproxy_ok="1"
    probe_tun && tun_ok="1"

    ui_print ""
    ui_print "*******************************"
    ui_print "  选择网络模式"
    ui_print "*******************************"

    if [ -n "$tproxy_ok" ]; then
        ui_print "  [音量+] TPROXY  (推荐，当前可用)"
    else
        ui_print "  [音量+] TPROXY  不可用"
        ui_print "          原因: ${probe_tproxy_reason}"
    fi

    if [ -n "$tun_ok" ]; then
        ui_print "  [音量-] TUN"
    else
        ui_print "  [音量-] TUN     不可用"
        ui_print "          原因: ${probe_tun_reason}"
    fi
    ui_print "  (10 秒无操作 -> 默认 TPROXY)"
    ui_print ""

    selected=""
    if [ -z "$tproxy_ok" ] && [ -z "$tun_ok" ]; then
        ui_print "! 两种模式均不可用，模块将安装但不启动内核"
        ui_print "! TPROXY: ${probe_tproxy_reason}"
        ui_print "! TUN    : ${probe_tun_reason}"
        selected=""
        return 0
    fi

    if [ -z "$tproxy_ok" ]; then
        ui_print "! 仅有 TUN 可用，自动选择 TUN"
        selected="tun"
        return 0
    fi

    _key=$(wait_key 10 2>/dev/null)
    # 清掉按键事件缓冲
    ui_print_line "按键: ${_key}"

    case "$_key" in
        DOWN)
            if [ -n "$tun_ok" ]; then
                selected="tun"
            else
                ui_print "! 按键无效：TUN 不可用，改用 TPROXY"
                selected="tproxy"
            fi
            ;;
        UP)
            selected="tproxy"
            ;;
        *)
            selected="tproxy"
            ;;
    esac
    ui_print_line "已选择: ${selected}"
}

# ---------------------------------------------------------------- 安装

install_data_dir() {
    data_dir="/data/adb/mihomo"
    mkdir -p "$data_dir/bin" "$data_dir/core" "$data_dir/config" 2>/dev/null

    # 二进制
    if [ -f "$MODPATH/bin/mihomo" ]; then
        cp -f "$MODPATH/bin/mihomo" "$data_dir/bin/mihomo"
        chmod 0755 "$data_dir/bin/mihomo"
        chown 0:0 "$data_dir/bin/mihomo" 2>/dev/null
    fi

    # geo 数据（用户已有的不覆盖）
    for f in GeoIP.dat GeoSite.dat Country.mmdb geoip.metadb; do
        if [ -f "$MODPATH/core/$f" ] && [ ! -f "$data_dir/core/$f" ]; then
            cp -f "$MODPATH/core/$f" "$data_dir/core/$f"
        fi
    done

    # web 面板（zashboard）：安装包带了就刷新，action 按钮靠它一键开面板
    if [ -f "$MODPATH/ui/index.html" ]; then
        rm -rf "$data_dir/core/ui"
        mkdir -p "$data_dir/core/ui"
        cp -af "$MODPATH/ui/." "$data_dir/core/ui/" 2>/dev/null
        ui_print_line "已部署 web 面板: $data_dir/core/ui"
    fi

    # 用户配置：已存在绝不覆盖
    if [ ! -f "$data_dir/config/config.yaml" ]; then
        if [ -f "$MODPATH/config/config.yaml" ]; then
            cp -f "$MODPATH/config/config.yaml" "$data_dir/config/config.yaml"
        fi
        ui_print_line "已放入默认 config.yaml，请按需修改: $data_dir/config/config.yaml"
    else
        ui_print_line "保留已有配置: $data_dir/config/config.yaml"
    fi

    # 分流清单：已存在则保留
    if [ ! -f "$data_dir/config/package.list.cfg" ]; then
        cp -f "$MODPATH/config/package.list.cfg" "$data_dir/config/package.list.cfg" 2>/dev/null
    fi

    # settings.ini：保留用户已有项，仅更新 network_mode
    if [ ! -f "$data_dir/config/settings.ini" ]; then
        cp -f "$MODPATH/config/settings.ini" "$data_dir/config/settings.ini" 2>/dev/null
        if grep -q '^network_mode=' "$data_dir/config/settings.ini" 2>/dev/null; then
            sed -i "s/^network_mode=.*/network_mode=${selected}/" "$data_dir/config/settings.ini"
        else
            echo "network_mode=${selected}" >> "$data_dir/config/settings.ini"
        fi
    else
        if grep -q '^network_mode=' "$data_dir/config/settings.ini" 2>/dev/null; then
            sed -i "s/^network_mode=.*/network_mode=${selected}/" "$data_dir/config/settings.ini"
        else
            echo "network_mode=${selected}" >> "$data_dir/config/settings.ini"
        fi
        ui_print_line "已更新 network_mode=${selected:-未选择}"
    fi

    chmod 0755 "$data_dir" "$data_dir/bin" "$data_dir/core" "$data_dir/config" 2>/dev/null
    chmod 0644 "$data_dir/config/"*.cfg "$data_dir/config/"*.ini 2>/dev/null
    chmod 0600 "$data_dir/config/config.yaml" 2>/dev/null
    chown -R 0:0 "$data_dir" 2>/dev/null

    # 记录安装时探测结果，供 action.sh 展示
    cat > "$data_dir/core/install_info" <<EOF
install_time=$(date '+%Y-%m-%d %H:%M:%S')
arch=${target_arch}
network_mode=${selected}
tproxy_ok=${tproxy_ok:-0}
tproxy_reason=${probe_tproxy_reason}
tun_ok=${tun_ok:-0}
tun_reason=${probe_tun_reason}
EOF

    # 安装包里的大文件已经落到 /data/adb/mihomo，模块目录只需保留脚本
    rm -rf "$MODPATH/bin" "$MODPATH/core" "$MODPATH/config" "$MODPATH/ui" 2>/dev/null
}

check_last_install() {
    if [ -d /data/adb/mihomo ] && [ ! -f /data/adb/mihomo/core/install_info ]; then
        ui_print_line "检测到已有 /data/adb/mihomo（非本模块创建？）"
        ui_print_line "本模块不会删除该目录内容"
    fi
}

set_module_perms() {
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    for f in "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh"; do
        [ -f "$f" ] && set_perm "$f" 0 0 0755
    done
    for f in "$MODPATH"/scripts/*; do
        [ -f "$f" ] && set_perm "$f" 0 0 0755
    done
    [ -f "$MODPATH/bin/mihomo" ] && set_perm "$MODPATH/bin/mihomo" 0 0 0755
}

# ---------------------------------------------------------------- 主流程

ui_print "*******************************"
ui_print "  Mihomo Module"
ui_print "*******************************"

check_env
check_last_install
extract_files
stage_binary
select_network_mode
install_data_dir
set_module_perms

ui_print ""
ui_print_line "安装完成"
ui_print_line "数据目录: /data/adb/mihomo"
ui_print_line "用户配置: /data/adb/mihomo/config/config.yaml"
ui_print_line "网络模式: ${selected:-未选择（不会启动）}"
ui_print ""
ui_print "重启设备后自动启动。命令行可用:"
ui_print "  /data/adb/modules/mihomo_module/scripts/mihomo.tool check"
ui_print "（首次安装后会重启生效；若在重启前调试，可用:"
ui_print "  sh /data/adb/modules_update/mihomo_module/scripts/mihomo.tool start）"
