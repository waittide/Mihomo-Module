#!/system/bin/sh
# 模块 action 按钮（Magisk/KernelSU/APatch 管理器里点「操作」执行）
MODDIR="${0%/*}"
LOG=/data/adb/mihomo/core/action.log

mkdir -p /data/adb/mihomo/core 2>/dev/null

{
    echo "======================================"
    echo " Mihomo Module"
    echo "======================================"

    if [ ! -d /data/adb/mihomo ]; then
        echo "数据目录 /data/adb/mihomo 不存在，模块可能未正确安装。"
        exit 0
    fi

    "${MODDIR}/scripts/mihomo.tool" check
} 2>&1 | tee "$LOG"
