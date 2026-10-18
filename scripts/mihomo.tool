#!/system/bin/sh
# 日常操作: mihomo.tool <子命令>
#
#   start | stop | restart | status        启停内核（并同步防火墙）
#   check | t                            一键诊断
#   switch <tproxy|tun>                  切换网络模式（会重启）
#   toggle <on|off>                      临时启用/停用（不动 settings.ini）
#   mode <blacklist|whitelist|off>       切换分流模式
#   resolve-uid                          重新解析 package.list.cfg 的 uid
#   config-test                          单独校验用户配置
#   dashboard [目录]                     下载 zashboard 到 core/ui
#   update-geo                           更新 geo 数据

scripts_dir="${0%/*}"
. "${scripts_dir}/mihomo.settings.sh"
. "${scripts_dir}/mihomo.packages.sh"

CTL_API() {
    _ctl=$(effective_controller)
    _secret=$(config_get "$user_config" secret)
    [ -n "$_secret" ] || _secret=$(config_get "$runtime_config" secret)
    echo "${_ctl}|${_secret}"
}

http_get() {
    # http_get <path>
    _p=$(CTL_API)
    _addr="${_p%%|*}"
    _sec="${_p#*|}"
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$_sec" ]; then
            curl -fsS -H "Authorization: Bearer ${_sec}" "http://${_addr}$1"
        else
            curl -fsS "http://${_addr}$1"
        fi
    else
        "$busybox" wget -q -O - "http://${_addr}$1" 2>/dev/null
    fi
}

reload_config() {
    # PUT /configs?force=true 让内核重载运行中配置（不重启进程）
    _p=$(CTL_API)
    _addr="${_p%%|*}"
    _sec="${_p#*|}"
    _hdr="Content-Type: application/json"
    [ -n "$_sec" ] && _hdr="${_hdr}\nAuthorization: Bearer ${_sec}"
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$_sec" ]; then
            curl -sS -o /dev/null -w '%{http_code}' -X PUT \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${_sec}" \
                "http://${_addr}/configs?force=true" -d '{"path":""}'
        else
            curl -sS -o /dev/null -w '%{http_code}' -X PUT \
                -H "Content-Type: application/json" \
                "http://${_addr}/configs?force=true" -d '{"path":""}'
        fi
    else
        "$busybox" wget -q -O - "http://${_addr}/configs?force=true" >/dev/null 2>&1 && echo 204
    fi
}

do_start() {
    "${scripts_dir}/mihomo.service" start || return 1
    "${scripts_dir}/mihomo.iptables" enable || return 1
    return 0
}

do_stop() {
    "${scripts_dir}/mihomo.iptables" disable
    "${scripts_dir}/mihomo.service" stop
    return 0
}

# 重启内核。tproxy 模式下不拆防火墙（apply_rules 本身幂等），
# 避免拆/建之间的几秒空窗与 xtables 锁竞争。
do_restart() {
    load_settings
    if [ "$network_mode" = "tproxy" ]; then
        "${scripts_dir}/mihomo.service" restart || return 1
        "${scripts_dir}/mihomo.iptables" enable || return 1
    else
        do_stop; do_start
    fi
    return 0
}

do_check() {
    load_settings
    echo "=== 1. 内核 ==="
    "${scripts_dir}/mihomo.service" status
    echo
    echo "=== 2. 二进制 ==="
    if [ -x "$bin_path" ]; then
        echo "路径: $bin_path"
        "$bin_path" -v 2>/dev/null | head -2
    else
        echo "缺失或不可执行: $bin_path"
    fi
    echo
    echo "=== 3. 配置校验 ==="
    if [ -f "$user_config" ]; then
        "$bin_path" -d "$core_dir" -t -f "$user_config" >/dev/null 2>&1 \
            && echo "用户配置 OK: $user_config" \
            || echo "用户配置校验失败: $user_config"
    else
        echo "缺少用户配置: $user_config"
    fi
    [ -f "$runtime_config" ] && echo "运行时配置: $runtime_config"
    echo
    echo "=== 4. 端口 ==="
    _ctl=$(effective_controller)
    for _p in "${eff_tproxy_port}" "${eff_dns_port}" "${_ctl##*:}"; do
        [ -n "$_p" ] || continue
        if port_listening "$_p"; then echo "  ${_p} 监听中"; else echo "  ${_p} 未监听"; fi
    done
    echo
    echo "=== 5. 防火墙 ==="
    if [ "$network_mode" = "tproxy" ]; then
        if iptables -w 100 -t mangle -C PREROUTING -j MIHOMO_TPROXY >/dev/null 2>&1; then
            echo "  mangle/MIHOMO_TPROXY 已挂载"
        else
            echo "  mangle/MIHOMO_TPROXY 未挂载"
        fi
        if iptables -w 100 -t mangle -C OUTPUT -j MIHOMO_MARK >/dev/null 2>&1; then
            echo "  mangle/MIHOMO_MARK 已挂载"
        else
            echo "  mangle/MIHOMO_MARK 未挂载"
        fi
        if iptables -w 100 -t nat -C PREROUTING -j MIHOMO_DNS >/dev/null 2>&1; then
            echo "  nat/MIHOMO_DNS 已挂载"
        else
            echo "  nat/MIHOMO_DNS 未挂载"
        fi
        ip rule show 2>/dev/null | grep "lookup $table_id" || echo "  策略路由缺失"
        # ip rule 必须带掩码（fwmark <mark>/<mark>）。无掩码时掩码为 0xffffffff，
        # 而 MIHOMO_MARK 是 `--set-xmark`（按位或），Android netId 位会让实际 fwmark
        # 变成 0x1xxxx|mark，两者永远匹配不上 -> 流量不代理。
        # 注意：ip rule 输出的是十六进制（mark_id=2024 -> 0x7e8），需转换后比对。
        _mark_hex=$(printf '0x%x' "$mark_id")
        if ip rule show 2>/dev/null | grep -q "fwmark ${_mark_hex}/${_mark_hex}"; then
            echo "  策略路由掩码正确 (fwmark ${_mark_hex}/${_mark_hex})"
        else
            echo "  ⚠ 策略路由掩码不正确，应重新执行: $scripts_dir/mihomo.iptables enable"
        fi
    else
        _dev=$(config_get "$runtime_config" device)
        [ -n "$_dev" ] || _dev="$tun_device"
        ip -o link show "$_dev" >/dev/null 2>&1 \
            && echo "  TUN 网卡 $_dev 存在" || echo "  TUN 网卡 $_dev 不存在"
    fi
    echo
    echo "=== 6. 分流 ==="
    load_packages
    echo "  mode: $proxy_mode  条目: ${#packages_list[@]}"
    echo
    echo "=== 7. 最近日志 ==="
    tail -15 "$log_file" 2>/dev/null
}

case "$1" in
    start)    do_start ;;
    stop)     do_stop ;;
    restart)  do_restart ;;
    status)   "${scripts_dir}/mihomo.service" status ;;
    check|t)  do_check ;;
    switch)
        load_settings
        case "$2" in
            tproxy|tun) ;;
            *) echo "用法: $0 switch <tproxy|tun>"; exit 1 ;;
        esac
        if grep -q '^network_mode=' "$settings_file" 2>/dev/null; then
            sed -i "s/^network_mode=.*/network_mode=$2/" "$settings_file"
        else
            echo "network_mode=$2" >> "$settings_file"
        fi
        echo "已切换为 $2，重启中..."
        do_stop; load_settings; do_start &&
            echo "完成。当前模式: $network_mode"
        ;;
    toggle)
        case "$2" in
            on)  do_start && echo "已启用" ;;
            off) do_stop && echo "已停用" ;;
            *) echo "用法: $0 toggle <on|off>"; exit 1 ;;
        esac
        ;;
    mode)
        case "$2" in
            blacklist|whitelist|off) ;;
            *) echo "用法: $0 mode <blacklist|whitelist|off>"; exit 1 ;;
        esac
        if [ -f "$package_file" ]; then
            if grep -q '^mode:' "$package_file"; then
                sed -i "s/^mode:.*/mode: $2/" "$package_file"
            else
                printf 'mode: %s\n' "$2" | cat - "$package_file" > "${package_file}.new" \
                    && mv -f "${package_file}.new" "$package_file"
            fi
        else
            echo "mode: $2" > "$package_file"
        fi
        echo "分流模式已设为 $2（重启后生效: $0 restart）"
        ;;
    resolve-uid)
        load_packages
        resolve_uids
        echo "uid 列表（${#uid_list[@]} 项）:"
        printf '  %s\n' "${uid_list[@]}"
        ;;
    config-test)
        load_settings
        "$bin_path" -d "$core_dir" -t -f "$user_config"
        ;;
    dashboard)
        load_settings
        _dir="${2:-${core_dir}/ui}"
        mkdir -p "$_dir"
        echo "下载 zashboard 到 ${_dir} ..."
        if command -v curl >/dev/null 2>&1; then
            curl -sSL -o /tmp/zashboard.zip \
                https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip || {
                echo "下载失败"; exit 1; }
        else
            "$busybox" wget -q -O /tmp/zashboard.zip \
                https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip || {
                echo "下载失败"; exit 1; }
        fi
        "$busybox" unzip -oq /tmp/zashboard.zip -d "$_dir" 2>/dev/null || \
            unzip -oq /tmp/zashboard.zip -d "$_dir"
        rm -f /tmp/zashboard.zip
        echo "完成。请把 external-ui 指向 ${_dir}"
        ;;
    update-geo)
        echo "使用 mihomo 自带 geo 更新: 先删旧文件再重启内核"
        rm -f "$core_dir/GeoIP.dat" "$core_dir/GeoSite.dat" "$core_dir/geoip.metadb" 2>/dev/null
        "${scripts_dir}/mihomo.service" restart
        ;;
    *)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
