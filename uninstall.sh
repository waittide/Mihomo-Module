#!/system/bin/sh
# 卸载：先停内核、清防火墙，再决定是否保留用户数据
MODDIR="${0%/*}"

DATA_DIR=/data/adb/mihomo
SCRIPTS="${MODDIR}/scripts"

# 停内核 + 清规则（脚本可能已被管理器删除，做存在性判断）
if [ -x "${SCRIPTS}/mihomo.iptables" ]; then
    "${SCRIPTS}/mihomo.iptables" disable >/dev/null 2>&1
fi
if [ -x "${SCRIPTS}/mihomo.service" ]; then
    "${SCRIPTS}/mihomo.service" stop >/dev/null 2>&1
fi

# 兜底：按 pid 文件 / 进程名清理
for _pf in "${DATA_DIR}/core/mihomo.watch.pid" "${DATA_DIR}/core/mihomo.pid"; do
    [ -f "$_pf" ] && kill "$(cat "$_pf" 2>/dev/null)" 2>/dev/null && rm -f "$_pf"
done

# 清理残留的 ip rule / ip route（mark/table 可能被用户在 settings.ini 改过，
# 所以先读配置；读不到就按默认值兜底）
_mark=2024; _table=2024
if [ -f "${DATA_DIR}/config/settings.ini" ]; then
    _m=$(sed -n 's/^mark_id=//p' "${DATA_DIR}/config/settings.ini" | head -1)
    _t=$(sed -n 's/^table_id=//p' "${DATA_DIR}/config/settings.ini" | head -1)
    [ -n "$_m" ] && _mark=$_m
    [ -n "$_t" ] && _table=$_t
fi
ip -4 rule show 2>/dev/null | awk -v t="$_table" '
    { for (i = 1; i < NF; i++) if ($i == "lookup" && $(i + 1) == t) { print; next } }' |
while read -r _line; do
    _pref=$(echo "$_line" | awk -F: '{print $1}')
    [ -n "$_pref" ] && ip -4 rule del pref "$_pref" 2>/dev/null
done
ip -4 rule del fwmark "$_mark/$_mark" table "$_table" 2>/dev/null
ip -4 rule del fwmark "$_mark" table "$_table" 2>/dev/null
ip -4 route flush table "$_table" 2>/dev/null
ip -6 rule del fwmark "$_mark/$_mark" table "$_table" 2>/dev/null
ip -6 rule del fwmark "$_mark" table "$_table" 2>/dev/null
ip -6 route flush table "$_table" 2>/dev/null

# 用户数据默认保留（含 config.yaml 与额外下载的 geo 数据）
# 想彻底清理可手动执行: rm -rf /data/adb/mihomo
rm -f "${DATA_DIR}/core/mihomo.pid"

exit 0
