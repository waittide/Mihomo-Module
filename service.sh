#!/system/bin/sh
# 开机自启：等系统启动完成后启动内核 + 防火墙规则
# 由 root 管理器在 post-fs-data 之后的 service 阶段执行。

MODDIR="${0%/*}"

(
    # 等待开机动画结束（部分设备该属性一直为空，加超时兜底）
    _wait=0
    until [ "$(getprop init.svc.bootanim)" = "stopped" ] || [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 2
        _wait=$((_wait + 1))
        [ $_wait -ge 120 ] && break
    done
    # 等待包管理就绪，package.list.cfg 的 uid 解析依赖它
    _wait=0
    while [ ! -f /data/system/packages.list ] && [ $_wait -lt 60 ]; do
        sleep 2
        _wait=$((_wait + 1))
    done
    sleep 3

    chmod 0755 "${MODDIR}"/scripts/* 2>/dev/null

    if [ -f "${MODDIR}/disable" ]; then
        exit 0
    fi

    "${MODDIR}/scripts/mihomo.tool" start >> /data/adb/mihomo/core/service.log 2>&1
) &
