#!/system/bin/sh
# 按应用分流清单解析
#
#   ${package_file} 格式（与 box_for_magisk 兼容）：
#     mode:blacklist        # blacklist = 名单内不走代理；whitelist = 只有名单内走代理
#     com.android.chrome
#     10:com.tencent.mm     # 前缀 "用户id:" 指定工作资料/多用户
#
# 空名单 + blacklist = 全部走代理（默认）。

load_packages() {
    proxy_mode="blacklist"
    packages_list=()
    uid_list=()

    if [ ! -f "$package_file" ]; then
        log_msg "未找到分流清单 $package_file，使用默认: mode=blacklist 空名单（全部代理）"
        return 0
    fi

    _m=$(sed -n 's/^[ \t]*mode:[ \t]*\([A-Za-z]*\).*/\1/p' "$package_file" | head -1)
    case "$_m" in
        whitelist|blacklist) proxy_mode="$_m" ;;
        "") : ;;
        *) log_msg "分流清单 mode 非法（$_m），回退 blacklist" ;;
    esac

    # 收集包名（保留 用户id: 前缀）
    _entries=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
                   -e '/^[[:space:]]*mode:/d' "$package_file" \
               | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    for _e in $_entries; do
        case "$_e" in
            */*) log_msg "分流清单条目非法（含 '/'）: $_e"; continue ;;
        esac
        packages_list[${#packages_list[@]}]="$_e"
    done

    log_msg "分流清单: mode=${proxy_mode} 条目数=${#packages_list[@]}"
    return 0
}

# 把包名解析成 uid（tproxy 模式需要 -m owner --uid-owner）
resolve_uids() {
    uid_list=()
    [ ${#packages_list[@]} -gt 0 ] || return 0
    [ -f /data/system/packages.list ] || {
        log_msg "找不到 /data/system/packages.list，无法解析 uid"
        return 1
    }
    for _e in "${packages_list[@]}"; do
        _user=0
        _pkg="$_e"
        case "$_e" in
            *:*) _user="${_e%%:*}"; _pkg="${_e#*:}" ;;
        esac
        _appid=$(awk -v p="$_pkg" '$1 == p {print $2; exit}' /data/system/packages.list)
        if [ -z "$_appid" ]; then
            log_msg "未安装或在 packages.list 中找不到: $_pkg"
            continue
        fi
        uid_list[${#uid_list[@]}]=$((_user * 100000 + _appid))
    done
    if [ ${#uid_list[@]} -gt 0 ]; then
        printf '%s\n' "${uid_list[@]}" > "$uid_file" 2>/dev/null
    else
        : > "$uid_file" 2>/dev/null
    fi
    return 0
}
