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

    chmod 0755 "$data_dir" "$data_dir/bin" "$data_dir/core" "$data_dir/config" 2>/dev/null
    chmod 0600 "$data_dir/config/config.yaml" 2>/dev/null
    chown -R 0:0 "$data_dir" 2>/dev/null

    # 记录安装信息（不含探测结果，安装时不再探测）
    cat > "$data_dir/core/install_info" <<EOF
install_time=$(date '+%Y-%m-%d %H:%M:%S')
arch=${target_arch}
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
install_data_dir
set_module_perms

ui_print ""
ui_print_line "安装完成"
ui_print_line "数据目录: /data/adb/mihomo"
ui_print_line "配置文件: /data/adb/mihomo/config/config.yaml"
ui_print ""
ui_print "配置决定运行模式，二选一（不能同时写）："
ui_print "  TUN    : tun: {enable: true}   —— 网卡/路由/规则全部由内核自建（推荐）"
ui_print "  TPROXY : tproxy-port: 7893     —— 模块不再建 iptables 规则，需自行配"
ui_print "                                   策略路由与 nat 重定向"
ui_print ""
ui_print "改完配置执行一次重启生效:"
ui_print "  /data/adb/modules/mihomo_module/scripts/mihomo.tool restart"
ui_print "重启设备后会自动启动。诊断:"
ui_print "  /data/adb/modules/mihomo_module/scripts/mihomo.tool check"
