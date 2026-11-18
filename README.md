# Xray Bandwidth Manager

交互式 Linux 双向带宽整形管理工具，使用 **CAKE + IFB + tc** 分别限制服务器出站和入站流量，适用于运行 Xray / x-ui 的 Debian 系统。

> 当前版本：1.0.0  
> 默认网卡：eth0  
> 默认 IFB：ifb0  
> 默认出站/入站限速：24 Mbps（两个方向分别限速，并非合计 24 Mbps）

## 功能

- 分别设置服务器出站与入站带宽上限
- 使用 CAKE 的 diffserv3 和 triple-isolate 队列策略
- 通过 IFB 将入站流量重定向后整形
- 交互式菜单查看 qdisc 状态和统计
- 支持暂停、恢复、修改网卡和开机自动应用
- 检测 BBR、CAKE、当前 TCP 拥塞控制算法及默认 qdisc
- 持久化启用/关闭 BBR，并记录和恢复启用前的拥塞控制算法
- 检查 BBR + CAKE 组合状态；不擅自将 CAKE 根队列替换为 FQ
- 使用 systemd oneshot 服务在网络启动后应用规则

## 系统要求

- Debian 11 或兼容的 systemd Linux
- root 权限
- iproute2（提供 tc、ip）
- kmod（提供 modprobe）
- Linux 内核具备 CAKE、IFB、mirred、matchall 支持

安装依赖：

```bash
apt update
apt install -y iproute2 kmod curl
```

确认内核支持 CAKE：

```bash
tc qdisc add dev lo root cake bandwidth 1mbit
tc qdisc del dev lo root
```

如果第一条命令提示不支持 cake，先确认当前内核是否提供 CAKE 功能，不要继续应用配置。

## 安装与启动

下载脚本并赋予执行权限：

```bash
curl -fsSL https://raw.githubusercontent.com/long369486562/xray-bandwidth-manager/main/xray-bandwidth-manager.sh -o /usr/local/sbin/xray-bandwidth-manager
chmod 0755 /usr/local/sbin/xray-bandwidth-manager
```

以 root 身份启动交互菜单：

```bash
/usr/local/sbin/xray-bandwidth-manager
```

首次启动会创建配置文件和 systemd 服务，并启用开机启动。**首次启动不会立即更改当前 qdisc**；确认网卡和带宽参数后，在菜单中选择“1. 应用当前配置”才会应用整形规则。

## 菜单功能

| 菜单 | 说明 |
| --- | --- |
| 1 | 应用当前配置 |
| 2 | 修改出站、入站限速 |
| 3 | 查看当前配置、服务与 qdisc 状态 |
| 4 | 每 2 秒刷新实时 qdisc 统计，Ctrl+C 返回 |
| 5 | 暂停整形 |
| 6 | 恢复整形 |
| 7 | 启用或禁用开机自动启动 |
| 8 | 修改物理网卡 |
| 9 | 重启整形服务 |
| 10 | BBR 管理与诊断（检测、启用、关闭、恢复此前算法） |
| U | 卸载管理工具 |
| 0 | 退出 |

systemd 管理命令：

```bash
systemctl status xray-bandwidth-shaping
systemctl restart xray-bandwidth-shaping
journalctl -u xray-bandwidth-shaping -b
```

## BBR + CAKE 协同管理

菜单 10 提供 BBR 检测与管理：

- 检测内核可用 TCP 拥塞控制算法、当前算法和内核版本
- 检测物理网卡与 IFB 上是否存在 CAKE
- 持久化启用 net.ipv4.tcp_congestion_control=bbr
- 关闭时恢复首次启用前记录的拥塞控制算法
- BBR 配置写入 /etc/sysctl.d/99-xray-bandwidth-manager-bbr.conf

**重要：BBR 与 CAKE 负责不同层面。** BBR 是 TCP 拥塞控制算法；CAKE 是 qdisc，负责整形、队列管理和流/主机公平。Linux 4.20 及更新内核支持 TCP 层内部 pacing，因此在当前 CAKE 根队列下不需要为了 BBR 强行把物理网卡根 qdisc 改为 FQ。net.core.default_qdisc 只影响后续创建的默认队列，不会替换本工具显式配置的 CAKE。

本工具不会修改 net.core.default_qdisc，也不会把 eth0 或 ifb0 的 CAKE 替换为 FQ。BBR 只作用于 TCP；UDP 流量仍由 CAKE 等队列规则处理。

关闭 BBR 时，工具会尝试恢复首次通过本菜单启用 BBR 前保存的 TCP 拥塞控制算法。如果之前的算法已不可用，则回退到 cubic；如果 cubic 也不可用，则选择内核可用算法列表中的第一个算法。

## 配置文件

位置：/etc/default/xray-bandwidth-manager

默认参数：

```bash
IFACE='eth0'
IFB='ifb0'
OUT_RATE='24'
IN_RATE='24'
ENABLED='1'
```

- IFACE：服务器物理网卡
- IFB：用于入站整形的虚拟网卡
- OUT_RATE：服务器出站速率，单位 Mbps
- IN_RATE：服务器入站速率，单位 Mbps
- ENABLED：1 启用，0 暂停

配置文件由工具以 root 所有者和 600 权限创建。不要允许非可信用户修改该文件。

## 工作方式与公平性

- **出站**：在物理网卡根 qdisc 上使用 CAKE 限速。
- **入站**：将物理网卡 ingress 流量重定向到 IFB，再由 IFB 上的 CAKE 限速。
- 两个方向的限速相互独立。例如 OUT_RATE=24、IN_RATE=24，表示两个方向各自最高约 24 Mbps。
- triple-isolate 提供基于流/主机的隔离与公平调度，但不能识别同一 NAT 公网 IP 后面的真实用户身份，也不等于给每位用户提供固定带宽保证。

## 重要注意事项

1. **请先确认网卡名称。** 默认值为 eth0，不同 VPS/云主机可能使用 ens3、enp1s0 等名称。错误配置可能导致整形没有作用。
2. **确认 CAKE 可用。** 内核不支持 CAKE 或 IFB 时，应用会失败。
3. **qdisc 会被删除并重新创建。** 每次应用或修改限速时，工具会删除物理网卡和 IFB 上现有的根 qdisc，再创建新的 CAKE 实例。这可以重置 CAKE 保留的旧容量估算状态（例如从 24 Mbps 修改为 80 Mbps 后仍显示旧的 `capacity estimate`）。重新创建会清零 CAKE 统计数据，并可能造成短暂流量抖动；同时会替换原有根 qdisc，请确认没有其他网络管理工具管理这些队列。工具还会在 ingress 优先级 49152 添加重定向规则，请确认该优先级没有被其他脚本占用。
4. **暂停/卸载并非精确还原。** 工具会尝试将物理网卡根 qdisc 恢复为 mq，但不会备份并还原此前自定义的 qdisc 层级、参数或子队列；如果原来使用了自定义队列配置，暂停或卸载后需要管理员自行恢复。
5. 请勿同时使用其他网络管理工具反复改写同一网卡的 qdisc / ingress 规则。
6. 建议在有 VPS 控制台或带外管理能力时首次应用，避免网络配置错误影响远程连接。

## 卸载

在交互菜单选择 U，输入 REMOVE 二次确认。卸载会停止并删除 systemd 服务、配置文件和管理脚本，同时尝试清理整形规则。请先阅读上面的 qdisc 恢复说明。

## License

MIT
