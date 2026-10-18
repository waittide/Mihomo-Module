# Mihomo Module

轻量的 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta）Magisk / KernelSU / APatch 模块。

**核心原则：模块不改写你的 `config.yaml`。** 你写什么，内核就跑什么；模块只在运行时配置里补上容器需要的最小几段（`tun`、`external-controller`、`tproxy-port`、缺省 `dns`），你配置里已有的同名顶层键一律以你的为准。

## 特性

- **不篡改用户配置**：用户配置在安装后原样保留，重装/升级不覆盖（已存在就跳过）。
- **安装时能力探测 + 选择网络模式**：真实探测 TPROXY（mangle/TPROXY + 策略路由）和 TUN（**真启动一次内核看网卡是否创建**），不可用的模式会打印原因并拒绝选择。
- **按应用分流**：`package.list.cfg` 的黑/白名单，TPROXY 下翻译成 `-m owner --uid-owner` 规则，TUN 下翻译成 `include-package` / `exclude-package`。
- **配置变更自动重载**：改动 `config.yaml` / `settings.ini` / `package.list.cfg` 后自动重启内核。
- **无 ipset 依赖**：本模块只用 `iptables -m owner`，因为很多设备（含鸿蒙）没有 `ipset` / `-m set`。
- **一键诊断**：`mihomo.tool check`（也可用模块管理器里的「操作」按钮）。

## 安装

```sh
# Magisk / KernelSU：管理器里刷入 zip
# APatch：
apd module install /path/to/Mihomo-v1.0.0.zip
```

安装过程中：

1. 检查架构（arm64-v8a / armeabi-v7a / x86_64）与 busybox。
2. 探测 TPROXY 与 TUN 可用性。
3. 用音量键选择网络模式（**默认 TPROXY**；10 秒无操作按默认值）：
   - **音量上 = TPROXY**
   - **音量下 = TUN**
   - 不可用的模式会显示原因，按对应的键会被忽略。
4. 释放文件到 `/data/adb/mihomo/`。

首次安装后**需要重启一次**才生效（模块目录里的 `update` 标记为 APatch 的待生效状态）。

## 目录结构

```
/data/adb/mihomo/
├── bin/mihomo          # 内核（随模块打包）
├── config/             # 你的配置，模块不会改写
│   ├── config.yaml     # 主配置
│   ├── settings.ini    # 模块设置（端口/模式/mark 等）
│   └── package.list.cfg# 按应用分流清单
└── core/               # 运行时产物
    ├── config.yaml     # 模块生成的运行时配置（= 你的配置 + 补充段）
    ├── mihomo.log      # 内核 + 模块日志
    ├── mihomo.pid
    ├── ports.env       # 实际生效的端口
    ├── uid.list        # 名单解析出的 uid
    ├── last_error      # 最近一次错误
    └── GeoIP.dat / GeoSite.dat / Country.mmdb
```

## 配置

### `config/settings.ini`

```ini
network_mode=tproxy     # tproxy | tun
tproxy_port=7893
dns_port=1053
tun_device=mihomo
tun_stack=mixed         # mixed | system | gvisor
tun_mtu=1500
ipv6=true
mark_id=2024            # fwmark，策略路由用
table_id=2024
pref_id=5200            # ip rule 优先级
core_group=root:net_admin
external_controller=127.0.0.1:9090
config_watch=true       # 配置变更自动重载
```

> 你在 `config.yaml` 里显式写了 `external-controller` 时，以 `config.yaml` 为准。

### `config/package.list.cfg`

```ini
# mode: blacklist = 名单内不走代理（其余走代理）
# mode: whitelist = 只有名单内走代理
mode: blacklist
com.example.app
10:com.example.workprofile_app   # 指定用户（10 = 工作资料）
```

默认 `mode: blacklist` + 空名单 = 全部走代理。

### 端口冲突

`tproxy_port` / `dns_port` 被别的程序占用时，模块不会自动改端口，只在 `mihomo.tool check` 里报出来。改 `settings.ini` 后会自动重载。

## 命令

所有命令都在 `/data/adb/modules/mihomo_module/scripts/` 下：

```sh
S=/data/adb/modules/mihomo_module/scripts

$S/mihomo.tool start|stop|restart|status
$S/mihomo.tool check                # 一键诊断（= 模块「操作」按钮）
$S/mihomo.tool switch tproxy|tun    # 切换网络模式（会重启）
$S/mihomo.tool toggle on|off        # 临时启停
$S/mihomo.tool mode blacklist|whitelist|off
$S/mihomo.tool resolve-uid          # 重新解析名单 uid
$S/mihomo.tool config-test          # 只校验你的 config.yaml
$S/mihomo.tool dashboard [dir]      # 下载 zashboard 到 core/ui
$S/mihomo.tool update-geo           # 删掉本地 geo 数据后重启，让内核重新下载
```

## 网络模式说明

### TPROXY（默认）

不需要 VPN 授权，适合大多数已 root 设备。规则：

- `mangle PREROUTING → MIHOMO_TPROXY`：保留地址 RETURN，其余 TCP/UDP `TPROXY --on-port <tproxy_port>`
- `mangle OUTPUT → MIHOMO_MARK`：先 RETURN 掉内核自身（uid 0 / gid net_admin），再按名单 MARK
- `nat PREROUTING/OUTPUT → MIHOMO_DNS*`：把 53 端口 REDIRECT 到 `dns_port`
- `ip rule fwmark <mark_id> lookup <table_id>` + `ip route add local default dev lo table <table_id>`

**注意：`mihomo` 的 fake-ip 段（默认 `198.18.0.1/16`）不能算作保留地址**，否则应用解析出的 fake-ip 会被直接放行。模块已把它排除在 RETURN 列表外。

### TUN

需要内核支持 `/dev/net/tun`。安装时模块会真启动一次内核去验证网卡能否创建。

TUN 模式下模块不写 iptables 规则（DNAT/劫持都不需要），黑白名单通过 `tun.exclude-package` / `tun.include-package` 实现——所以列表里必须写**包名**，不能写 uid（写 `user:包名` 的条目在 TUN 模式下会被解析成包名）。

## 已知限制

- **无 `ipset`**：黑白名单靠 `iptables -m owner --uid-owner`，名单很长时规则条数会变多（每条应用一条）。
- **IPv6 DNS 无法劫持**：部分设备（如 HarmonyOS 4.2 / kernel 4.19）没有 `ip6tables -t nat` 表，模块会在日志里说明并回退到「IPv6 流量按 mihomo 的 tun/direct 处理」。
- **`-f` 不能叠加**：mihomo 的多个 `-f` 是 last-wins（后一个文件整体替换前一个，不是深度合并），所以模块把补充段写进运行时配置的单一文件里，而不是用多个 `-f`。
- **配置变更检测是轮询**（每 2 秒比对 md5）：比 inotify 可靠。本机实测一次保存会连发 `c/c/w` 三个事件，用 inotify 去抖很难做对（容易漏事件或重复重启）。

## 卸载

管理器里卸载即可，`/data/adb/mihomo` 用户数据默认保留。想彻底清理：

```sh
rm -rf /data/adb/mihomo
```

## 参考

设计上参考了 [Mihomo_For_Magisk](https://github.com/icewithcola/Mihomo_For_Magisk) 与 [box_for_magisk](https://github.com/taamarin/box_for_magisk) 的实现，但**配置处理策略完全不同**：前者的 template 合并会截断用户配置（`sed -n '/^proxies:/,$p'` 只保留 `proxies:` 之后的内容），本模块不做这种事。

## License

MIT
