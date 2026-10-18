#!/system/bin/sh
# 日常操作: mihomo.tool <子命令>
#
#   start | stop | restart | status        启停内核（并同步防火墙）
#   check | t                            一键诊断
#   switch <tproxy|tun>                  切换网络模式（改 config.yaml 后重启）
#   toggle <on|off>                      临时启用/停用
#   mode <blacklist|whitelist|off>       切换分流模式（仅 TPROXY 模式有效）
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
    load_settings
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
    # 必须走 service 的 restart（一次取锁内完成 stop+start）。
    # 拆成 do_stop; do_start 会连续取两次锁，中间窗口允许另一个 restart 插进来，
    # 曾被热重载与手动重启同时触发时搞出两个内核实例。
    "${scripts_dir}/mihomo.service" restart || return 1
    load_settings
    # TUN 模式下 iptables enable 会走 flush 分支，把上一次 TPROXY 模式留下的
    # 规则/策略路由清掉 —— 否则切到 TUN 后流量仍被劫持回 lo，应用全 000。
    "${scripts_dir}/mihomo.iptables" enable || return 1
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
    if [ "$network_mode" = "tproxy" ] && [ -f "$runtime_config" ]; then
        echo "运行时副本: $runtime_config（已去掉 tun 段，内核实际跑它）"
        "$bin_path" -d "$core_dir" -t -f "$runtime_config" >/dev/null 2>&1 \
            && echo "  运行时副本校验 OK" \
            || echo "  运行时副本校验失败"
    fi
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
        _dev=$(config_sub_get "$user_config" tun device)
        [ -n "$_dev" ] || _dev="Meta"
        ip -o link show "$_dev" >/dev/null 2>&1 \
            && echo "  TUN 网卡 $_dev 存在" || echo "  TUN 网卡 $_dev 不存在"
        echo "  （TUN 模式下网卡/路由/规则由内核自己维护，模块不写 iptables）"
    fi
    echo
    echo "=== 6. 分流 ==="
    if [ "$network_mode" = "tproxy" ]; then
        load_packages
        echo "  mode: $proxy_mode  条目: ${#packages_list[@]}"
    else
        echo "  TUN 模式：按应用分流看 config.yaml 的 tun.include-package / exclude-package"
        for _k in include-package exclude-package; do
            _v=$(config_sub_get "$user_config" tun "$_k")
            [ -n "$_v" ] && echo "  ${_k}: $_v"
        done
    fi
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
        # 只读：报告配置现在是哪种模式，不改写 config.yaml。
        # 模式完全由用户的 config.yaml 决定（tun.enable 或 tproxy-port），
        # 模块不替用户改配置。
        load_settings
        echo "当前模式: ${network_mode:-未确定}"
        echo ""
        echo "切换方式（由你改配置，模块不代改）:"
        echo "  用 TUN     : 保留 tun: 段并设 enable: true，删掉 tproxy-port"
        echo "  用 TPROXY  : 删掉 tun: 段（或设 enable: false），加 tproxy-port: 7893"
        echo "             并把 dns.listen 设成固定端口（如 listen: 0.0.0.0:53）"
        echo ""
        echo "改完执行: $0 restart"
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
        _zip="${core_dir}/zashboard.zip"
        echo "下载 zashboard 到 ${_dir} ..."
        # 设备上直连 GitHub release 经常被截断，失败时重试一次并校验 zip 完整性
        _ok=0
        for _try in 1 2; do
            echo "  第 ${_try} 次尝试 ..."
            rm -f "$_zip"
            if command -v curl >/dev/null 2>&1; then
                curl -fL --retry 3 --connect-timeout 15 -o "$_zip" \
                    https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip || { _ok=0; continue; }
            else
                "$busybox" wget -O "$_zip" -T 20 \
                    https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip 2>/dev/null || { _ok=0; continue; }
            fi
            # 用 unzip -t 验证完整性，避免“short read”的半截包
            if "$busybox" unzip -tq "$_zip" >/dev/null 2>&1 || unzip -tq "$_zip" >/dev/null 2>&1; then
                _ok=1; break
            fi
            echo "  下载不完整，重试 ..."
        done
        if [ "$_ok" != "1" ]; then
            rm -f "$_zip"
            echo "下载失败或文件不完整。"
            echo "请在网络更好的环境手动下载后推送:"
            echo "  curl -L -o dist.zip https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
            echo "  adb push dist.zip /data/local/tmp/zz.zip"
            echo "  su -c 'unzip -o /data/local/tmp/zz.zip -d ${_dir}'"
            exit 1
        fi
        # zip 内顶层就是 dist/ 目录，解压后把内容提到 _dir 下
        "$busybox" unzip -oq "$_zip" -d "${core_dir}/.ui_tmp" 2>/dev/null || \
            unzip -oq "$_zip" -d "${core_dir}/.ui_tmp"
        if [ -d "${core_dir}/.ui_tmp/dist" ]; then
            cp -af "${core_dir}/.ui_tmp/dist/." "$_dir/"
        else
            cp -af "${core_dir}/.ui_tmp/." "$_dir/"
        fi
        rm -rf "${core_dir}/.ui_tmp" "$_zip"
        echo "完成: $(ls "$_dir" | wc -l) 个文件已就位"
        echo "external-ui 应为: ${_dir}"
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
