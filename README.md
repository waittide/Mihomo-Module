# Mihomo Module

给 Magisk / KernelSU / APatch 用的 mihomo 透明代理模块。

**核心原则：`config.yaml` 是唯一的配置来源。** 模块不生成运行时配置、不注入任何
键、不改写你的 `config.yaml`——内核永远直接用 `-f /data/adb/mihomo/config/config.yaml`
运行。你写什么，就跑什么。

配置写错时模块**只报错不动手**：缺 `dns.listen`、`tun` 与 `tproxy-port` 同时开，
都会直接拒绝启动并告诉你该删/该加哪一行（见「缺失配置直接报错」）。

## 特性

- **单一配置源**：没有 `settings.ini`、没有运行时配置生成、没有模板替换、没有
  文件监听。改完 `config.yaml` 后执行一次 `mihomo.tool restart` 即可。
- **两种运行模式，由配置自己表达**：
  - 顶层 `tproxy-port` → **TPROXY**（支持 UDP 全代理）。内核只提供端口，规则由
    模块建立：mangle `TPROXY` + `MARK`、nat DNS 重定向、`ip rule` 策略路由。
  - 只有 `tun.enable: true`、没有 `tproxy-port` → **TUN**。网卡、路由、iptables
    规则全部由内核自建，模块一个规则都不写。
  - 两者**同时存在 → 拒绝启动并报错**。实测两者同开会互相喂包——TUN 的
    `auto-route` 把默认路由指向 TUN 网卡，TPROXY 的 mark 又把包抢回 `lo`——结果
    是 `http=000`。模块不替你猜，直接告诉你删掉哪个。
- **模式切换会自动清理残留规则**：从 TPROXY 切到 TUN 时，`mihomo.iptables enable`
  走 flush 分支把 mangle 链、nat 链、`ip rule`/`ip route` 全部拆掉。否则旧的
  TPROXY 规则会把 TUN 的流量劫持回 `lo`，而 `status` 却显示「TUN 模式，模块不写
  iptables」，极难排查。
- **缺失配置直接报错，不猜不补**：TPROXY 模式缺 `dns.listen` 时拒绝启动并给出
  该补的那一行（`listen` 缺失会让 53 被劫持到不存在的端口，表现为"全部应用上
  不了网但内核日志正常"）。
- **内置 web 面板**：安装包自带 zashboard 到 `core/ui`，`external-ui: ui` 由你写在
  配置里。管理器里点「执行」按钮会启动内核并用浏览器打开 `http://127.0.0.1:9090/ui/`
  （不带 query 参数，后端地址和密码在面板里自己填）。
- **action 日志落盘**：管理器终端窗口一闪而过看不清时，看
  `/data/adb/mihomo/core/action.log`。

## 安装

1. 在管理器里刷入 zip。
2. 安装只做三件事：解包、把 `bin/mihomo` 与 geo 数据放到 `/data/adb/mihomo`、
   在 `config/` 下放一份默认 `config.yaml`（**已存在则绝不覆盖**）。
   **不做能力探测，也不让你按音量键选模式**——模式由配置文件决定。
3. 重启设备生效。重启前想先试可以：
   ```sh
   su -c 'sh /data/adb/modules/mihomo_module/scripts/mihomo.tool start'
   ```

## 目录结构

```
/data/adb/mihomo/
├── bin/mihomo              # 内核（随安装包提供）
├── config/
│   ├── config.yaml         # ← 唯一配置源，内核直接读它
│   └── package.list.cfg    # 按应用分流清单（仅 TPROXY 模式使用）
└── core/
    ├── ui/                 # zashboard 面板（external-ui: ui）
    ├── mihomo.log          # 内核日志
    ├── mihomo.pid
    ├── action.log          # 「执行」按钮的输出
    └── last_error          # 最近一次启动失败原因
```

模块自身（`/data/adb/modules/mihomo_module/`）只放脚本，不放二进制和 geo 数据，
升级时不会重复占空间。

## 配置怎么选模式

### TPROXY（推荐，支持 UDP 全代理）

```yaml
tproxy-port: 7893

dns:
  enable: true
  listen: 0.0.0.0:53        # ← 必须写！缺了会拒绝启动
  enhanced-mode: redir-host # ← 不能是 fake-ip，见下
```

TPROXY 适合需要 UDP 全代理、或不想建 TUN 网卡的场景。模块会建立：

- `mangle PREROUTING → MIHOMO_TPROXY`：保留网段 RETURN，其余 `TPROXY --on-port`
- `mangle OUTPUT → MIHOMO_MARK`：排除 root 与内核自身 gid 后打 mark
- `nat PREROUTING/OUTPUT → MIHOMO_DNS*`：53 重定向到 `dns.listen` 的端口
- `ip rule fwmark 0x7e8/0x7e8 table 2024` + `ip route local default dev lo table 2024`

> `fwmark` 必须带掩码。`MIHOMO_MARK` 是 `MARK --set-xmark`（按位或），Android 的
> socket 自带 netId 位（wifi 100 → `0x10064`），实际 fwmark 是 `0x107ec`；无掩码
> 的 `ip rule` 要求精确相等，永远匹配不上，表现为"规则有命中但流量从 wlan0 逃逸"。

> **TPROXY 不能配 fake-ip**：`198.18.0.0/16` 的包会被内核判为 `local` 直接放行，
> 永远进不了 tproxy，表现为"能解析但连不上"。必须用 `redir-host`。

### TUN

```yaml
tun:
  enable: true
  stack: mixed
  auto-route: true            # TUN 必需：跟随网络切换重建路由
  auto-detect-interface: true # 出站绑定正确的物理网卡
  dns-hijack:
    - "any:53"
  # auto-redirect 建议不写：它是给「不开 Android VPN、纯靠 iptables 抓流量」的场景
  # 准备的第二层劫持，常规使用会和内核自身路由重复。
```

内核自己建网卡、策略路由、nat 重定向，停止时自动清理干净。**不需要模块写任何
iptables 规则**——但如果你刚从 TPROXY 切过来，模块会主动清掉旧的 TPROXY 规则。

## `package.list.cfg`（仅 TPROXY 模式）

```yaml
mode: blacklist        # blacklist = 名单内不走代理；whitelist = 只有名单内走代理
com.android.chrome
10:com.tencent.mm       # 前缀 "用户id:" 可指定工作资料/多用户
```

空名单 + `blacklist` = 全部走代理（默认）。

设备上没有 `ipset`/`-m set`，所以分流只能翻译成 `-m owner --uid-owner`；uid 从
`/data/system/packages.list` 解析（`user*100000+appid`）。

TUN 模式的按应用分流**不**用这个文件，直接在 `config.yaml` 里写
`tun.include-package` / `tun.exclude-package`。

## 命令

```sh
TOOL=/data/adb/modules/mihomo_module/scripts/mihomo.tool

$TOOL start|stop|restart|status    # 启停（TPROXY 模式下同时同步防火墙）
$TOOL check                        # 一键诊断（配置校验/端口/规则/分流/日志）
$TOOL switch                       # 只读：显示当前模式 + 如何自行切换
$TOOL toggle <on|off>              # 临时启停
$TOOL mode <blacklist|whitelist>   # 改 package.list.cfg 的 mode
$TOOL resolve-uid                  # 重新解析 uid
$TOOL config-test                  # 单独校验 config.yaml
$TOOL dashboard                    # 重新下载 zashboard 到 core/ui
$TOOL update-geo                   # 删掉旧 geo 数据后重启（内核会重新下载）
```

## 已知限制

- **没有 `ipset` / `-m set`**：本类设备（实测 HarmonyOS 4.2）的 iptables 缺该
  match，busybox 也没有 ipset，所以黑白名单只能用 `-m owner`。宽带名单会变长。
- **IPv6 可能没有 nat 表**：本机 `ip6tables -t nat` 不存在，IPv6 的 53 无法
  REDIRECT，只能靠 TUN 的 `dns-hijack` 或 mangle TPROXY 兜。
- **TUN 与 TPROXY 不能同时开**（见上）。
- **mihomo 多个 `-f` 是 last-wins**，不能当覆盖层用——所以本模块坚持单文件。
- **不监听配置变更**：改完 `config.yaml` 需要手动 `mihomo.tool restart`（或管理器里
  点「执行」按钮）。曾实现过轮询与 `inotifyd` 两版，前者多耗电，后者在本类设备上
  一次保存连发 `c/c/w` 三个事件、编辑器还会 rename 产生目录 `M` 事件，去抖很容易
  做错（出现过"一次保存触发三次重启"），故移除。

## 卸载

卸载脚本会停内核、清 TPROXY 规则与策略路由，但**保留** `/data/adb/mihomo`
（你的 `config.yaml` 在里面）。要彻底清掉：

```sh
su -c 'rm -rf /data/adb/mihomo'
```

## 参考实现

- [Mihomo_For_Magisk](https://github.com/icewithcola/Mihomo_For_Magisk)：模板合并式
  配置（用模板覆盖用户配置），本模块刻意走了相反路线。
- [box_for_magisk](https://github.com/taamarin/box_for_magisk)：`package.list.cfg`
  格式与安装脚本的音量键交互参考自它。

## License

MIT
