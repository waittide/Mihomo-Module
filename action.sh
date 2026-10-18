#!/system/bin/sh
# 模块 action 按钮（Magisk / KernelSU / APatch 管理器里点「操作」/「执行」）
#
# 行为：确保内核在跑 → 打开 mihomo 自带的 web 面板（external-ui）
# 管理器弹出的终端窗口几秒后会自己关掉，所以关键信息另外写到
#   /data/adb/mihomo/core/action.log
# 之后随时可以用以下任一方式查看：
#   adb shell su -c 'cat /data/adb/mihomo/core/action.log'
#   Termux: su -c 'less /data/adb/mihomo/core/action.log'
#
MODDIR="${0%/*}"
DATA_DIR=/data/adb/mihomo
LOG="$DATA_DIR/core/action.log"
UI_DIR="$DATA_DIR/core/ui"

mkdir -p "$DATA_DIR/core" 2>/dev/null
: > "$LOG"

# 同时输出到屏幕和日志；管理器关窗后仍能从 LOG 读到
say() {
    echo "$*"
    echo "$*" >> "$LOG"
}

say "======================================"
say " Mihomo Module  $(date '+%Y-%m-%d %H:%M:%S')"
say "======================================"

if [ ! -d "$DATA_DIR" ]; then
    say "数据目录 $DATA_DIR 不存在，模块可能未正确安装。"
    sleep 3
    exit 0
fi

TOOL="$MODDIR/scripts/mihomo.tool"

# ---- 1. 内核没在跑就先拉起来 ----
if ! "$TOOL" status 2>/dev/null | grep -q "running"; then
    say "内核未运行，正在启动 ..."
    "$TOOL" start >> "$LOG" 2>&1
    sleep 2
fi

if ! "$TOOL" status 2>/dev/null | grep -q "running"; then
    say "内核启动失败，详情见下："
    "$TOOL" check >> "$LOG" 2>&1
    say ""
    say "排查：$TOOL check"
    say "日志：$DATA_DIR/core/mihomo.log"
    sleep 5
    exit 1
fi

say "内核运行中：$("$TOOL" status 2>/dev/null | sed -n 's/^status *: *//p' | head -1)"

# ---- 2. web 面板没就绪就下载 ----
if [ ! -f "$UI_DIR/index.html" ]; then
    say "web 面板未安装，正在下载 zashboard ..."
    "$TOOL" dashboard >> "$LOG" 2>&1
fi

# ---- 3. 面板目录通过 config.yaml 的 external-ui 指定 ----
# 面板必须在 $DATA_DIR/core 下（内核以 -d core 运行），使 external-ui: ui 生效。
# 新安装已经把 zashboard 部署到 core/ui，install 时也会自动写入 external-ui: ui。
if ! grep -q '^external-ui:' "$DATA_DIR/config/config.yaml" 2>/dev/null; then
    say "配置里未设置 external-ui，面板可能无法通过 /ui/ 访问。"
    say "在 $DATA_DIR/config/config.yaml 里加一行: external-ui: ui"
    sleep 2
fi

# ---- 4. 拼 URL 并打开 ----
# 控制器监听在 0.0.0.0/127.0.0.1 时同机浏览器都能访问；面板与 API 同端口。
# 只打开纯 /ui/：后端地址与 secret 由用户在面板里自行填写（模块不改面板代码）。
CTL=$("$TOOL" status 2>/dev/null | sed -n 's/^controller *: *//p' | head -1)
[ -n "$CTL" ] || CTL="127.0.0.1:9090"
_ctl_host="${CTL%:*}"
_ctl_port="${CTL##*:}"
case "$_ctl_host" in
    0.0.0.0|::|"") _ctl_host="127.0.0.1" ;;
esac
URL="http://${_ctl_host}:${_ctl_port}/ui/"

say "面板地址：${URL}"

if command -v am >/dev/null 2>&1; then
    am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1 \
        && say "已用系统浏览器打开。" \
        || say "打开浏览器失败，请手动访问上面的地址。"
else
    say "未找到 am 命令，请手动访问上面的地址。"
fi

say ""
say "--- 内核摘要 ---"
_st=$("$TOOL" status 2>/dev/null)
for _k in network_mode status tproxy-port dns-port controller; do
    _v=$(echo "$_st" | sed -n "s/^${_k} *: *//p" | head -1)
    [ -n "$_v" ] && say "  ${_k}: ${_v}"
done
say "完整诊断请执行: $TOOL check"
say "本次日志已保存: $LOG"
sleep 3
exit 0
