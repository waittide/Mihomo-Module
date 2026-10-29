#!/system/bin/sh
# 路径与公共工具函数，由 mihomo.service / mihomo.tool 引入
#
# 配置的唯一来源：${config_dir}/config.yaml（mihomo 原生配置，模块不生成副本、
# 不改写它）。模块只从该文件读几个展示用参数：
#
#   tproxy-port        仅用于 status/check 展示
#   dns.listen         仅用于 status/check 展示
#   tun.enable          为 true 时模式显示为 tun
#   external-controller 面板地址
#   secret              面板密码
#
# 模式判定规则见 load_settings()。

scripts_dir="${scripts_dir:-${0%/*}}"

data_dir="${data_dir:-/data/adb/mihomo}"
config_dir="$data_dir/config"
core_dir="$data_dir/core"
bin_path="$data_dir/bin/mihomo"
user_config="$config_dir/config.yaml"
pid_file="$core_dir/mihomo.pid"
log_file="$core_dir/mihomo.log"
error_file="$core_dir/last_error"

# 内核进程身份
core_group="root:net_admin"

# ---------------------------------------------------------------- 配置读取

# 取顶层标量键的值（去掉引号与行内注释）
config_get() {
    _f="$1"; _k="$2"
    [ -f "$_f" ] || return 1
    awk -v k="$_k" '
        index($0, k ":") == 1 {
            sub("^" k ":[ \t]*", "")
            sub("[ \t]*#.*$", "")
            gsub(/["\047]/, "")
            print
            exit
        }' "$_f"
}

# 取某个顶层块下的二级标量，如 config_sub_get tun enable
config_sub_get() {
    _f="$1"; _block="$2"; _k="$3"
    [ -f "$_f" ] || return 1
    awk -v b="$_block" -v k="$_k" '
        $0 ~ "^" b ":[ \t]*$" { f = 1; next }
        f && /^[^ \t#]/ { f = 0 }
        f && $0 ~ "^[ \t]+" k ":" {
            sub("^[ \t]+" k ":[ \t]*", "")
            sub("[ \t]*#.*$", "")
            gsub(/["\047]/, "")
            print
            exit
        }' "$_f"
}

# tun.enable 是否为 true
tun_enabled() {
    _v=$(config_sub_get "$user_config" tun enable)
    [ "$_v" = "true" ]
}

# dns.listen 的端口部分（"0.0.0.0:1053" -> 1053；"1053" -> 1053）
dns_listen_port() {
    _v=$(config_sub_get "$user_config" dns listen)
    case "$_v" in
        "")  echo "" ;;
        *:*) echo "${_v##*:}" ;;
        *)   echo "$_v" ;;
    esac
}

# ---------------------------------------------------------------- 初始化

load_settings() {
    [ -n "${busybox:-}" ] && [ -x "${busybox:-}" ] || {
        busybox=""
        for b in /data/adb/ap/bin/busybox /data/adb/ksu/bin/busybox \
                 /data/adb/magisk/busybox; do
            [ -x "$b" ] && { busybox="$b"; break; }
        done
        [ -n "$busybox" ] || busybox="$(command -v busybox 2>/dev/null)"
    }

    # 从用户配置读端口（仅用于展示）
    tproxy_port=$(config_get "$user_config" tproxy-port)
    dns_port=$(dns_listen_port)

    eff_tproxy_port="$tproxy_port"
    eff_dns_port="$dns_port"

    # 模式判定（仅用于 status/check 展示，模块不据此做任何网络配置）
    network_mode=""
    if tun_enabled; then
        network_mode="tun"
    elif [ -n "$tproxy_port" ]; then
        network_mode="tproxy"
    fi
    return 0
}

# ---------------------------------------------------------------- 日志/错误

log_msg() {
    mkdir -p "$core_dir" 2>/dev/null
    echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$log_file"
}

set_error() {
    mkdir -p "$core_dir" 2>/dev/null
    printf '%s\n' "$*" > "$error_file"
    log_msg "错误: $*"
    # 同时输出到 stderr，否则命令行 rm/mihomo.tool start 失败时屏幕上一片空白
    printf '%s\n' "$*" >&2
}

clear_error() {
    rm -f "$error_file" 2>/dev/null
}

get_error() {
    [ -f "$error_file" ] && cat "$error_file"
    return 0
}

# ---------------------------------------------------------------- 进程

# 扫描所有 mihomo 进程（用 cmdline 匹配 bin_path，不依赖 pidfile）。
# 为什么需要：pidfile 可能因为异常退出/重装而指向不存在的 pid，而旧进程
# 还在跑并占着端口，此时新实例会因端口冲突立即退出。
all_mihomo_pids() {
    for _p in $(ls /proc 2>/dev/null); do
        case "$_p" in
            ''|*[!0-9]*) continue ;;
        esac
        # 用 cat 读而不是 `< 重定向`：进程在扫描期间消失时，重定向失败的错误
        # 由 shell 直接打印，2>/dev/null 管不到，会污染调用方输出。
        _c=$(cat "/proc/$_p/cmdline" 2>/dev/null | tr '\000' ' ')
        # 必须是内核进程本身：cmdline 里带 -f 且不以 sh 开头（排除包装脚本）
        case "$_c" in
            *"-f "*) : ;;
            *) continue ;;
        esac
        case "$_c" in
            *mihomo*) echo "$_p" ;;
        esac
    done
}

# 运行中的 pid（优先 pidfile，回退到扫描）
clash_pid() {
    if [ -f "$pid_file" ]; then
        _pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$_pid" ] && [ -d "/proc/$_pid" ]; then
            case "$(cat "/proc/$_pid/cmdline" 2>/dev/null | tr '\000' ' ')" in
                *mihomo*) echo "$_pid"; return 0 ;;
            esac
        fi
    fi
    _found=$(all_mihomo_pids | head -1)
    if [ -n "$_found" ]; then
        echo "$_found" > "$pid_file" 2>/dev/null
        echo "$_found"
        return 0
    fi
    return 1
}

# 面板地址：以用户配置的 external-controller 为准
effective_controller() {
    _c=$(config_get "$user_config" external-controller)
    [ -n "$_c" ] || _c="127.0.0.1:9090"
    case "$_c" in
        0.0.0.0:*) _c="127.0.0.1:${_c#0.0.0.0:}" ;;
        ::*)       _c="127.0.0.1:${_c##*:}" ;;
        *:*)       : ;;
        *)         _c="127.0.0.1:${_c}" ;;
    esac
    echo "$_c"
}

# 检查端口是否已被监听
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
