#!/system/bin/sh
# 日常操作: mihomo.tool <子命令>
#
#   start | stop | restart | status        启停内核
#   check | t                            一键诊断
#   toggle <on|off>                      临时启用/停用
#   dashboard [目录]                     下载 zashboard 到 core/ui
#   update-geo                           更新 geo 数据
#
# 网络参数完全由 config.yaml 决定，模块不代改、也不建立任何 iptables 规则。

scripts_dir="${0%/*}"
. "${scripts_dir}/mihomo.settings.sh"

do_start() {
    "${scripts_dir}/mihomo.service" start || return 1
    return 0
}

do_stop() {
    "${scripts_dir}/mihomo.service" stop
    return 0
}

# 重启内核。必须走 service 的 restart（一次取锁内完成 stop+start）。
# 拆成 do_stop; do_start 会连续取两次锁，中间窗口允许另一个 restart 插进来，
# 曾被热重载与手动重启同时触发时搞出两个内核实例。
do_restart() {
    "${scripts_dir}/mihomo.service" restart || return 1
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
    echo
    echo "=== 4. 端口 ==="
    _ctl=$(effective_controller)
    for _p in "${eff_tproxy_port}" "${eff_dns_port}" "${_ctl##*:}"; do
        [ -n "$_p" ] || continue
        if port_listening "$_p"; then echo "  ${_p} 监听中"; else echo "  ${_p} 未监听"; fi
    done
    echo
    echo "=== 5. 网卡 ==="
    _dev=$(config_sub_get "$user_config" tun device)
    [ -n "$_dev" ] || _dev="Meta"
    ip -o link show "$_dev" >/dev/null 2>&1 \
        && echo "  TUN 网卡 $_dev 存在" || echo "  TUN 网卡 $_dev 不存在"
    echo "  （网卡/路由/规则由内核自己维护）"
    echo
    echo "=== 6. 分流 ==="
    echo "  按应用分流看 config.yaml 的 tun.include-package / exclude-package"
    for _k in include-package exclude-package; do
        _v=$(config_sub_get "$user_config" tun "$_k")
        [ -n "$_v" ] && echo "  ${_k}: $_v"
    done
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
    toggle)
        case "$2" in
            on)  do_start && echo "已启用" ;;
            off) do_stop && echo "已停用" ;;
            *) echo "用法: $0 toggle <on|off>"; exit 1 ;;
        esac
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
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
