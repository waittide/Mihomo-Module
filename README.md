# Mihomo Module

给 Magisk / KernelSU / APatch 用的 mihomo 透明代理模块。

**核心原则：`config.yaml` 是唯一的配置来源。** 模块不生成运行时配置、不注入任何
键、不改写你的 `config.yaml`——内核永远直接用 `-f /data/adb/mihomo/config/config.yaml`
运行。你写什么，就跑什么。

**模块只做启停。** 不建立任何 `iptables` / `ip rule` / `ip route`：网络模式、网卡、
路由、DNS 劫持全部由内核自己的配置决定。配置写错时内核启动不起来，模块把内核的
报错原样报给你，不猜也不补。

## 特性

- **单一配置源**：没有 `settings.ini`、没有运行时配置生成、没有模板替换、没有
  文件监听。改完 `config.yaml` 后执行一次 `mihomo.tool restart` 即可。
- **零 iptables**：模块不碰防火墙。TUN 模式的网卡/路由/规则由内核自建；TPROXY
  模式只由内核提供 `tproxy-port`，策略路由与 nat 重定向需要你自己配置。
- **模式只用于展示**：`status` / `check` 会从配置里读出 `tun.enable`、`tproxy-port`、
  `dns.listen`、`external-controller`，告诉你当前是哪种模式、端口通不通。模块本身
  不据此改写任何东西。
- **启停串行化**：手动 `restart`、「执行」按钮、开机自启可能同时触发。用符号链接
  做锁（`ln -s` 是设备上唯一可靠的原语），持有者被杀时能自动清理死锁，不会再同时
  拉起两个内核实例。
- **内置 web 面板**：安装包自带 zashboard 到 `core/ui`，`external-ui: ui` 由你写在
  配置里。管理器里点「执行」按钮会启动内核并打开 `http://127.0.0.1:9090/ui/`。
- **action 日志落盘**：管理器终端窗口一闪而过看不清时，看
  `/data/adb/mihomo/core/action.log`。

## 安装

1. 在管理器里刷入 zip。
2. 安装脚本解包、把 `bin/mihomo` 与 geo 数据放到 `/data/adb/mihomo`、在 `config/`
   下放一份默认 `config.yaml`（**已存在则绝不覆盖**）。
3. 重启设备生效。重启前想先试可以：
   ```sh
   su -c 'sh /data/adb/modules/mihomo_module/scripts/mihomo.tool start'
   ```

## 目录结构

```
/data/adb/mihomo/
├── bin/mihomo              # 内核（随安装包提供）
├── config/config.yaml      # ← 唯一配置源，内核直接读它
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

默认配置给的是 TUN 模式（开箱可用）。

### TUN

```yaml
tun:
  enable: true
  stack: mixed
  auto-route: true            # TUN 必需：跟随网络切换重建路由
  auto-detect-interface: true # 出站绑定正确的物理网卡
  dns-hijack:
    - "any:53"
  # include-package:          # 只代理名单内的应用
  # exclude-package:          # 名单内的应用直连
```

内核自己建网卡、策略路由、nat 重定向，停止时自动清理干净，模块不需要写任何规则。
按应用分流直接写 `tun.include-package` / `tun.exclude-package`。

### TPROXY

```yaml
tproxy-port: 7893

dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: redir-host # ← 不能是 fake-ip，见下
```

模块只负责把内核拉起来并让它监听 `tproxy-port`，**不建立** mangle `TPROXY` /
`MARK`、nat DNS 重定向、`ip rule` 策略路由——这些都需要你自己配置，否则内核在跑
但流量不会进来。

> **TPROXY 不能配 fake-ip**：`198.18.0.0/16` 的包会被内核判为 `local` 直接放行，
> 永远进不了 tproxy，表现为"能解析但连不上"。必须用 `redir-host`。

## 命令

```sh
TOOL=/data/adb/modules/mihomo_module/scripts/mihomo.tool

$TOOL start|stop|restart    # 启停内核
$TOOL status                # 配置路径、模式、pid、端口、面板地址、最近错误
$TOOL check | t             # 一键诊断（内核/二进制/配置校验/端口/网卡/分流/日志）
$TOOL toggle <on|off>       # 临时启停
$TOOL dashboard [目录]      # 重新下载 zashboard 到 core/ui（默认）
$TOOL update-geo            # 删掉旧 geo 数据后重启（内核会重新下载）
```

## 已知限制

- **模块不做网络层的事情**：TPROXY 需要自己写 iptables 与策略路由；这也是默认
  配置给 TUN 的原因。
- **TUN 与 TPROXY 不能同时写**：TUN 的 `auto-route` 把默认路由指向 TUN 网卡，
  TPROXY 的 mark 又把包抢回 `lo`，两者互相喂包会让流量全部不通。
- **mihomo 多个 `-f` 是 last-wins**，不能当覆盖层用——所以本模块坚持单文件。
- **不监听配置变更**：改完 `config.yaml` 需要手动 `mihomo.tool restart`（或管理器里
  点「执行」按钮）。曾实现过轮询与 `inotifyd` 两版，前者多耗电，后者在本类设备上
  一次保存连发 `c/c/w` 三个事件、编辑器还会 rename 产生目录 `M` 事件，去抖很容易
  做错（出现过"一次保存触发三次重启"），故移除。

## 卸载

卸载脚本会停内核，并清理旧版本（TPROXY 时代）可能残留的 `ip rule` / `ip route`，
但**保留** `/data/adb/mihomo`（你的 `config.yaml` 在里面）。要彻底清掉：

```sh
su -c 'rm -rf /data/adb/mihomo'
```

## 参考实现

- [Mihomo_For_Magisk](https://github.com/icewithcola/Mihomo_For_Magisk)：模板合并式
  配置（用模板覆盖用户配置），本模块刻意走了相反路线。
- [box_for_magisk](https://github.com/taamarin/box_for_magisk)：安装脚本的交互与
  目录布局参考自它。

## License

MIT
