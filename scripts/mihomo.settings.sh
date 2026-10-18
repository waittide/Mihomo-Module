#!/system/bin/sh
# 公共设置与工具函数，由 mihomo.service / mihomo.iptables / mihomo.tool 引入
# 目录约定：
#   模块脚本（随更新覆盖）  ${module_dir}/scripts/
#   用户数据（永不覆盖）    /data/adb/mihomo/

scripts_dir="${scripts_dir:-${0%/*}}"
module_dir="${module_dir:-${scripts_dir%/scripts}}"
[ "$module_dir" = "$scripts_dir" ] && module_dir="/data/adb/modules/mihomo_for_root"

data_dir="${data_dir:-/data/adb/mihomo}"
config_dir="$data_dir/config"
core_dir="$data_dir/core"
bin_path="$data_dir/bin/mihomo"
settings_file="$config_dir/settings.ini"
package_file="$config_dir/package.list.cfg"
user_config="$config_dir/config.yaml"
runtime_config="$core_dir/config.yaml"
pid_file="$core_dir/mihomo.pid"
log_file="$core_dir/mihomo.log"
uid_file="$core_dir/uid.list"
ports_file="$core_dir/ports.env"
error_file="$core_dir/last_error"

# ---- 默认值（settings.ini 里的同名项会覆盖）----
# network_mode: tproxy | tun | 空 = 安装时未选择（不启动）
network_mode="tproxy"
tproxy_port=7893
dns_port=1053
tun_device="mihomo"
tun_stack="mixed"
tun_mtu=1500
ipv6="true"
mark_id=2024
table_id=2024
pref_id=5200
core_group="root:net_admin"
external_controller="127.0.0.1:9090"
external_ui=""
config_watch="true"

load_settings() {
    network_mode="tproxy"
    tproxy_port=7893
    dns_port=1053
    tun_device="mihomo"
    tun_stack="mixed"
    tun_mtu=1500
    ipv6="true"
    mark_id=2024
    table_id=2024
    pref_id=5200
    core_group="root:net_admin"
    external_controller="127.0.0.1:9090"
    external_ui=""
    config_watch="true"
    [ -f "$settings_file" ] && . "$settings_file"

    core_user="${core_group%%:*}"
    core_gid="${core_group##*:}"
    [ -n "$core_user" ] || core_user="root"
    [ -n "$core_gid" ] || core_gid="net_admin"

    if [ -z "${busybox:-}" ] || [ ! -x "${busybox:-}" ]; then
        busybox=""
        for b in /data/adb/ap/bin/busybox /data/adb/ksu/bin/busybox \
                 /data/adb/magisk/busybox; do
            [ -x "$b" ] && { busybox="$b"; break; }
        done
        [ -n "$busybox" ] || busybox="$(command -v busybox 2>/dev/null)"
    fi

    # 内核进程的 gid 数字（用于 iptables 排除，避免自己的流量回环）
    core_gid_num=""
    if [ -n "$busybox" ] && [ -x "$busybox" ]; then
        core_gid_num=$("$busybox" id -g "$core_gid" 2>/dev/null)
    fi
    [ -n "$core_gid_num" ] || core_gid_num=$(id -g "$core_gid" 2>/dev/null)
    case "$core_gid_num" in
        ''|*[!0-9]*) core_gid_num="" ;;
    esac

    iptables_wait="iptables -w 100"
    ip6tables_wait="ip6tables -w 100"

    # 运行时实际端口（由 config 生成后写入，只给 iptables 用，不覆盖用户设置）
    eff_tproxy_port=""
    eff_dns_port=""
    if [ -f "$ports_file" ]; then
        . "$ports_file"
    fi
    [ -n "$eff_tproxy_port" ] || eff_tproxy_port="$tproxy_port"
    [ -n "$eff_dns_port" ] || eff_dns_port="$dns_port"
}

log_msg() {
    mkdir -p "$core_dir" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$log_file"
}

set_error() {
    mkdir -p "$core_dir" 2>/dev/null
    printf '%s\n' "$*" > "$error_file"
    log_msg "错误: $*"
}

clear_error() {
    rm -f "$error_file" 2>/dev/null
}

get_error() {
    [ -f "$error_file" ] && cat "$error_file"
    return 0
}

# 运行中的 pid（校验 cmdline，避免 pid 复用误判）
clash_pid() {
    [ -f "$pid_file" ] || return 1
    _pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$_pid" ] || return 1
    [ -d "/proc/$_pid" ] || return 1
    case "$(tr '\000' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)" in
        *mihomo*) echo "$_pid"; return 0 ;;
    esac
    return 1
}

# 用户配置里显式给出的 external-controller 优先于 settings.ini
effective_controller() {
    _c=""
    for f in "$runtime_config" "$user_config"; do
        [ -f "$f" ] || continue
        _c=$(awk '/^external-controller:/ { sub(/^external-controller:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); print; exit }' "$f")
        [ -n "$_c" ] && break
    done
    [ -n "$_c" ] || _c="$external_controller"
    case "$_c" in
        0.0.0.0:*) _c="127.0.0.1:${_c#0.0.0.0:}" ;;
    esac
    echo "$_c"
}

# 从配置文件里取某个顶层键（简单标量）
config_get() {
    _f="$1"; _k="$2"
    [ -f "$_f" ] || return 1
    awk -v k="$_k" '
        index($0, k ":") == 1 {
            sub("^" k ":[ \t]*", "")
            sub("[ \t]*#.*$", "")
            print
            exit
        }' "$_f"
}

# 检查端口是否已被监听（ss 数据行: netid state recv-q send-q local peer）
port_listening() {
    [ -n "$1" ] || return 1
    ss -lntu 2>/dev/null | awk -v p="$1" '
        NR > 1 {
            for (i = 1; i <= NF; i++) {
                if ($i ~ ("[:.]" p "$")) { found = 1; exit }
            }
        }
        END { exit !found }'
}
