#!/system/bin/sh
# 运行时配置生成器（被 mihomo.service 引入）
#
# 设计原则：
#   用户的 ${config_dir}/config.yaml 永远保持原样，模块不改写它；
#   生成的 ${runtime_config} = 用户配置 + 模块必需的键。
#   模块只接管它必须掌握的键：
#     tun / tproxy-port            —— 由安装时选择的网络模式决定
#     external-controller / dns    —— 用户没写时才补默认值
#   用户 tun 段里模块不认识的键（如 strict-route、endpoint-independent-nat）会被保留。

config_has_key() {
    _f="$1"; _k="$2"
    [ -f "$_f" ] || return 1
    grep -qE "^${_k}:" "$_f"
}

# 删除指定顶层键及其所有缩进子行
config_strip_keys() {
    _f="$1"; shift
    _keys="$*"
    awk -v keys="$_keys" '
        BEGIN { n = split(keys, arr, " "); for (i = 1; i <= n; i++) want[arr[i]] = 1 }
        {
            if ($0 ~ /^[A-Za-z0-9_.-]+:/) {
                name = $0
                sub(/:.*/, "", name)
                skip = (name in want)
                if (skip) next
            } else if (skip) {
                if ($0 ~ /^[ \t]/ || $0 ~ /^$/ || $0 ~ /^#/) next
                skip = 0
            }
            print
        }' "$_f"
}

# 从用户配置里取出 tun 段中「模块不接管」的子键，原样保留
#
# 注意：必须按缩进跟踪「被接管子键的值块」。dns-hijack 这类列表的下级项
# （如 `- "any:53"`）自身不带 `key:`，若只靠 key 名判断会被当成独立项重复
# 输出，而且缩进只有 2 空格，落到生成的 tun 段里就把 YAML 结构弄坏
# （典型报错：yaml: line N: did not find expected key）。
config_user_tun_extra() {
    _f="$1"
    [ -f "$_f" ] || return 0
    awk '
        BEGIN {
            own["enable"]; own["device"]; own["stack"]; own["mtu"]
            own["auto-route"]; own["auto-detect-interface"]; own["dns-hijack"]
            own["include-package"]; own["exclude-package"]
            own["include-uid"]; own["exclude-uid"]
            in_tun = 0; tun_indent = -1; skip_block = 0
        }
        /^tun:/ { in_tun = 1; tun_indent = -1; skip_block = 0; next }
        in_tun && /^[^ \t]/ { in_tun = 0 }
        !in_tun { next }
        /^[ \t]*#/ { next }
        !NF { next }
        {
            n = match($0, /[^ \t]/) - 1
            line = $0
            sub(/^[ \t]+/, "", line)
            if (tun_indent < 0) tun_indent = n
            if (n == tun_indent) {
                key = line
                sub(/:.*/, "", key)
                skip_block = (key in own)
                if (skip_block) next
                print "  " line
            } else if (n > tun_indent) {
                if (skip_block) next
                print "  " line
            }
        }' "$_f"
}

# 生成 tun 段
tun_block() {
    case "$network_mode" in
        tun) _enable="true" ;;
        *)   _enable="false" ;;
    esac
    echo "tun:"
    echo "  enable: ${_enable}"
    echo "  stack: ${tun_stack}"
    echo "  device: ${tun_device}"
    echo "  mtu: ${tun_mtu}"
    echo "  auto-route: true"
    echo "  auto-detect-interface: true"
    echo "  dns-hijack:"
    echo "    - any:53"
    # 按应用分流：TUN 模式只能靠 mihomo 自己的包名过滤
    if [ "$network_mode" = "tun" ] && [ ${#packages_list[@]} -gt 0 ]; then
        _key="exclude-package"
        [ "$proxy_mode" = "whitelist" ] && _key="include-package"
        echo "  ${_key}:"
        for _p in "${packages_list[@]}"; do
            # 去掉 "用户id:" 前缀：mihomo 的 include/exclude-package 只认包名
            echo "    - ${_p#*:}"
        done
    fi
    config_user_tun_extra "$user_config"
}

# 生成最小可用 dns 段（仅在用户没写 dns 时使用）
default_dns_block() {
    echo "dns:"
    echo "  enable: true"
    echo "  ipv6: ${ipv6}"
    echo "  listen: 0.0.0.0:${dns_port}"
    echo "  enhanced-mode: fake-ip"
    echo "  fake-ip-range: 198.18.0.1/16"
    echo "  default-nameserver:"
    echo "    - 223.5.5.5"
    echo "    - 119.29.29.29"
    echo "  nameserver:"
    echo "    - 223.5.5.5"
    echo "    - 119.29.29.29"
    echo "  fallback:"
    echo "    - tls://8.8.4.4:853"
}

# tproxy 模式需要内核自己监听 dns_port；若用户 dns 段没写 listen，补一个
config_dns_listen_port() {
    _f="$1"
    awk '
        /^dns:/ { f = 1; next }
        f && /^[^ \t]/ { f = 0 }
        f && /^[ \t]+listen:/ { sub(/^[ \t]+listen:[ \t]*/, ""); print; exit }' "$_f"
}

# 用户写了 dns 段但没写 listen（很常见：只关心 nameserver）时，mihomo 不会启动
# DNS 服务器 —— 1053 端口没人监听，nat 表把 53 端口 REDIRECT 过来后全部超时，
# 表现就是“所有应用都上不了网，但内核日志里一片正常”。
# 这里在 dns 段第一行后插入 listen，用户自己写了 listen 则原样保留。
config_dns_inject_listen() {
    _f="$1"; _port="$2"
    [ -f "$_f" ] || return 0
    awk -v port="$_port" '
        BEGIN { done = 0 }
        {
            print
            if (!done && $0 ~ /^dns:[ \t]*$/) {
                printf "  listen: 0.0.0.0:%s\n", port
                done = 1
            }
        }' "$_f"
}

generate_runtime_config() {
    mkdir -p "$core_dir" 2>/dev/null

    if [ ! -f "$user_config" ]; then
        set_error "找不到用户配置 $user_config"
        return 1
    fi

    _tmp="${runtime_config}.new"

    config_strip_keys "$user_config" tun external-controller tproxy-port external-ui > "$_tmp" || {
        set_error "读取 $user_config 失败"
        rm -f "$_tmp"; return 1
    }

    # external-controller 模块统一接管：用户配置里写了就用它的值，没写用 settings.ini 的
    # （不能“用户写了就不补”——上面 strip 已经把这一键从运行时配置删掉了，
    #  不补回来内核就完全不开 API 端口，面板会连不上）
    _user_ctl=$(config_get "$user_config" external-controller)
    _eff_ctl="${_user_ctl:-$external_controller}"
    printf '\nexternal-controller: %s\n' "$_eff_ctl" >> "$_tmp"

    # external-ui: 用户 config 里的旧值已在上一步 strip 掉；core/ui 就绪时自动挂上
    # （action 按钮一键打开 web UI 依赖它）
    if [ -n "$external_ui" ] && [ -d "$external_ui" ]; then
        printf '\nexternal-ui: %s\n' "$external_ui" >> "$_tmp"
    fi

    if ! config_has_key "$user_config" dns; then
        printf '\n' >> "$_tmp"
        default_dns_block >> "$_tmp"
    elif [ -z "$(config_dns_listen_port "$user_config")" ]; then
        # 用户 dns 段缺 listen：注入监听地址，否则 dns_port 无人监听、DNS 全挂
        config_dns_inject_listen "$_tmp" "$dns_port" > "${_tmp}.dns" && mv -f "${_tmp}.dns" "$_tmp"
        log_msg "用户 dns 段缺少 listen，已注入 0.0.0.0:${dns_port}"
    fi

    printf '\n' >> "$_tmp"
    tun_block >> "$_tmp"

    if [ "$network_mode" = "tproxy" ]; then
        printf '\ntproxy-port: %s\n' "$tproxy_port" >> "$_tmp"
    fi

    if ! "$bin_path" -d "$core_dir" -t -f "$_tmp" >> "$log_file" 2>&1; then
        _err=$("$bin_path" -d "$core_dir" -t -f "$_tmp" 2>&1 \
               | grep -E 'level=error|test failed' | tail -2 \
               | sed 's/.*msg="//; s/"[ \t]*$//')
        [ -n "$_err" ] || _err=$(tail -3 "$log_file")
        set_error "运行时配置校验失败: $_err"
        cp -f "$_tmp" "${runtime_config}.failed" 2>/dev/null
        rm -f "$_tmp"
        return 1
    fi

    mv -f "$_tmp" "$runtime_config"
    chmod 0644 "$runtime_config"
    chown "${core_user}:${core_gid}" "$runtime_config" 2>/dev/null

    # 记录实际生效的端口，供 iptables 使用
    _actual_tproxy=$(config_get "$runtime_config" tproxy-port)
    [ -n "$_actual_tproxy" ] || _actual_tproxy="$tproxy_port"
    _dns_listen=$(config_dns_listen_port "$runtime_config")
    case "$_dns_listen" in
        *:*) _actual_dns_port="${_dns_listen##*:}" ;;
        "")  _actual_dns_port="$dns_port" ;;
        *)   _actual_dns_port="$_dns_listen" ;;
    esac

    cat > "$ports_file" <<EOF
eff_tproxy_port=${_actual_tproxy}
eff_dns_port=${_actual_dns_port}
EOF
    chmod 0644 "$ports_file"

    log_msg "运行时配置已生成: mode=${network_mode} tproxy-port=${_actual_tproxy} dns-port=${_actual_dns_port}"
    return 0
}
