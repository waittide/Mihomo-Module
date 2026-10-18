#!/bin/sh
# 打包成 Magisk/KernelSU/APatch 可刷入的 zip
# 用法: ./build.sh [输出目录]
set -e

cd "$(dirname "$0")"
out_dir="${1:-dist}"
name="Mihomo-$(grep '^version=' module.prop | cut -d= -f2).zip"

mkdir -p "$out_dir"
rm -f "$out_dir/$name"

includes="module.prop customize.sh service.sh action.sh uninstall.sh META-INF scripts config bin core"

# web 面板（zashboard）可选：存在则打进包里，安装时落到 /data/adb/mihomo/core/ui
if [ -d "ui" ] && [ -f "ui/index.html" ]; then
    includes="$includes ui"
    echo "包含 web 面板: $(find ui -type f | wc -l) 个文件"
else
    echo "提示: 未找到 ui/（web 面板），安装后首次点“执行”按钮时会自动下载"
fi

if command -v zip >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    zip -r -9 -q "$out_dir/$name" $includes \
        -x '*.DS_Store' '*/.git*' 'core/*.log' 'core/mihomo.pid'
elif command -v python3 >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    python3 - "$out_dir/$name" $includes <<'PY'
import os, stat, sys, zipfile

out, includes = sys.argv[1], sys.argv[2:]
skip_dirs = {".git", "dist", "build"}
skip_names = {'.DS_Store'}
skip_suffixes = ('.log', '.pid')

def add(zf, path):
    st = os.stat(path)
    info = zipfile.ZipInfo(path, date_time=(2026, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (st.st_mode & 0xFFFF) << 16
    info.create_system = 3
    with open(path, 'rb') as fp:
        zf.writestr(info, fp.read())

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for inc in includes:
        if os.path.isdir(inc):
            for root, dirs, files in os.walk(inc):
                dirs[:] = sorted(d for d in dirs if d not in skip_dirs)
                for fn in sorted(files):
                    if fn in skip_names or fn.endswith(skip_suffixes):
                        continue
                    add(zf, os.path.join(root, fn))
        elif os.path.isfile(inc):
            add(zf, inc)

PY
else
    echo "错误: 需要 zip 或 python3 才能打包" >&2
    exit 1
fi

echo "已生成 $out_dir/$name"
ls -lh "$out_dir/$name"
