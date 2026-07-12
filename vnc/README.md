# wg-setup.sh

一个用于在 **VPS + macOS 被控端 + macOS 控制端** 之间快速搭建 WireGuard 隧道的 Bash 脚本，专为通过 macOS 原生 **屏幕共享（VNC）** 实现远程控制的场景设计。

三端都跑同一个脚本，按菜单选角色，全程只需三次公钥复制粘贴即可完成组网。

---

## 为什么要用它

如果你有以下场景，这个脚本适合你：

- **被控端和控制端都在 NAT 后**（家宽、公司网、手机热点），没有公网 IP
- 想用一台**便宜的境外 VPS**（例如香港 VPS）做流量中转
- 控制端**不希望安装任何肉眼可见是"远控软件"的第三方 App**，仅使用系统自带的 `Terminal` 和 `屏幕共享.app`
- 被控端**需要开机自启**、无人值守也能被随时连上
- 拒绝 SSH 隧道套 VNC 那种 **TCP-over-TCP 卡顿**，希望走 UDP 获得平滑体验

隧道由 WireGuard（内核态、UDP）负责，只做"打通网络"这一件事；远控功能完全交给 macOS 原生的屏幕共享服务。**控制端菜单栏不会出现任何第三方图标**。

---

## 拓扑

```
                ┌──────────────────────────┐
                │  VPS (Ubuntu 22.04)      │
                │  隧道 IP: 10.0.0.1       │
                │  UDP 51820 对外监听      │
                └──────────┬───────────────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              │ WireGuard  │ WireGuard  │
              │ UDP 加密   │ UDP 加密   │
              │            │            │
       ┌──────┴─────┐ ┌────┴──────┐ ┌──┴──────────┐
       │ 被控端 Mac │ │ 控制端 A  │ │ 控制端 B    │
       │ 10.0.0.2   │ │ 10.0.0.3  │ │ 10.0.0.4    │
       │ 常驻在线   │ │ 用时才up  │ │ 用时才up    │
       └────────────┘ └───────────┘ └─────────────┘
```

- **VPS**：hub，唯一有公网 IP 的节点，负责转发子网内流量
- **被控端**：spoke，靠 `PersistentKeepalive=25` 维持在线；开机自启
- **控制端**：spoke，日常手动 `wg-quick up/down`，可有多台

---

## 前置条件

| 节点 | 系统要求 | 必备条件 |
|---|---|---|
| VPS | Ubuntu 22.04（或其他 Debian 系） | 有 root 权限；云厂商安全组放行 **UDP 51820** |
| 被控端 Mac | macOS（Apple Silicon / Intel 均可） | 有 sudo 权限；需预先安装 [Homebrew](https://brew.sh)（未装时脚本会打印命令引导） |
| 控制端 Mac | macOS（Apple Silicon / Intel 均可） | 有 sudo 权限；需预先安装 Homebrew（未装时脚本会打印命令引导） |

**只有一个一次性手动步骤脚本不管**：被控端 Mac 需要在 `系统设置 → 通用 → 共享` 里开启 **"屏幕共享"** 或 **"远程管理"**。

---

## 使用方法

### Step 1 — VPS 端安装

登录 VPS：

```bash
curl -fsSLO https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/wg-setup.sh
sudo bash wg-setup.sh
# 菜单选 1
```

脚本会：

1. `apt install wireguard`
2. 生成密钥对到 `/etc/wireguard/`
3. 开启 `net.ipv4.ip_forward=1`
4. 写入 `/etc/wireguard/wg0.conf`
5. 若 `ufw` 已启用，自动放行 UDP 51820
6. `systemctl enable --now wg-quick@wg0`

**结束后屏幕会打印 VPS 的公网 IP 和公钥，请复制保存**，后面配置被控/控制端时要用。

验证：

```bash
sudo wg show          # 应看到 wg0 接口
ss -lun | grep 51820  # 应看到监听
```

---

### Step 2 — 被控端 Mac 安装

在被控端 Mac 打开 Terminal：

```bash
curl -fsSLO https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/wg-setup.sh
sudo bash wg-setup.sh
# 菜单选 2
# 按提示粘贴: VPS 公网 IP、VPS 公钥
```

脚本会：

1. 通过 Homebrew 安装 `wireguard-tools`
2. 生成密钥对到 `$(brew --prefix)/etc/wireguard/`
3. 写入 `wg0.conf`（隧道 IP 固定为 `10.0.0.2`，含 `PersistentKeepalive=25`）
4. 安装 `/Library/LaunchDaemons/com.wireguard.wg0.plist`，开机自动拉起隧道
5. 打印**本机公钥**

**记下这个公钥**，Step 4 要粘贴到 VPS。

**同时别忘了一次性手工操作**：`系统设置 → 通用 → 共享 → 屏幕共享（或远程管理）打开`。

---

### Step 3 — 每台控制端 Mac 安装

```bash
curl -fsSLO https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/wg-setup.sh
sudo bash wg-setup.sh
# 菜单选 3
# 按提示输入: 该控制端分配的 IP (10.0.0.3, 10.0.0.4, ...)
# 粘贴: VPS 公网 IP、VPS 公钥
```

脚本会做与 Step 2 类似的动作，但**不会**安装 LaunchDaemon，日常需要手动 `wg-quick up/down`。

**记下这台控制端的公钥**。

---

### Step 4 — 回 VPS 追加所有 peer

每有一台新的 spoke（被控或控制端），都要回 VPS 追加一次：

```bash
sudo bash wg-setup.sh
# 菜单选 4
# 粘贴 peer 公钥
# 输入分配给它的 IP (10.0.0.2 是被控,10.0.0.3+ 是控制端)
```

脚本使用 `wg syncconf` **热加载**，不会中断已有隧道。

---

### Step 5 — 日常使用

**控制端**：

```bash
# 开工
sudo wg-quick up wg0
open vnc://10.0.0.2       # 拉起 macOS 屏幕共享,连被控端

# 收工
sudo wg-quick down wg0
```

**被控端**：什么都不用做，永远在线（LaunchDaemon 已代劳）。

---

## 网络参数一览

| 项 | 值 |
|---|---|
| 虚拟子网 | `10.0.0.0/24` |
| VPS 隧道 IP | `10.0.0.1` |
| 被控端隧道 IP | `10.0.0.2` |
| 控制端隧道 IP | `10.0.0.3` 起，脚本推荐 `.3 ~ .99` |
| WireGuard 端口 | UDP `51820` |
| `PersistentKeepalive` | `25` 秒（被控/控制端都启用，VPS 侧不需要） |

**为什么用 `10.0.0.0/24` 不会和家里冲突？** 因为 `10.10.10.0/24`（常见家用路由器）和 `10.0.0.0/24` 是 `10.0.0.0/8` 里两个完全不相交的 `/24` 子网。脚本里 `AllowedIPs` 精确到 `/24`，路由表不会打架。

---

## 文件与路径清单

### VPS (Ubuntu)

| 文件 | 用途 |
|---|---|
| `/etc/wireguard/wg0.conf` | WireGuard 主配置 |
| `/etc/wireguard/privatekey` | 私钥（600 权限） |
| `/etc/wireguard/publickey` | 公钥 |
| `/etc/sysctl.conf` | 追加 `net.ipv4.ip_forward=1` |
| `systemd:wg-quick@wg0` | 开机自启服务 |

### macOS（被控端 / 控制端）

| 文件 | 用途 |
|---|---|
| `$(brew --prefix)/etc/wireguard/wg0.conf` | WireGuard 主配置 |
| `$(brew --prefix)/etc/wireguard/privatekey` | 私钥 |
| `$(brew --prefix)/etc/wireguard/publickey` | 公钥 |
| `/Library/LaunchDaemons/com.wireguard.wg0.plist` | **仅被控端**，开机自启 |
| `/var/log/wireguard-wg0.log` / `.err` | **仅被控端**，LaunchDaemon 输出日志 |

Homebrew 前缀：
- Apple Silicon：`/opt/homebrew`
- Intel Mac：`/usr/local`

脚本会自动探测并写入正确路径。

---

## 常见问题排查

### 1. 控制端 `sudo wg-quick up wg0` 成功，但 `ping 10.0.0.2` 不通

依次检查：

```bash
sudo wg show
```

- **对端 `latest handshake` 一直没有更新**：
  - 云厂商安全组是否放行 UDP 51820？（不是 TCP！）
  - VPS 上 `sudo ufw status` 是否放行？
  - 对端 `wg0.conf` 的 `Endpoint` 是否指向正确的 VPS 公网 IP？

- **VPS `wg show` 里能看到握手但 spoke 之间 ping 不通**：
  - VPS 上 `sysctl net.ipv4.ip_forward` 是否为 `1`？
  - VPS 上其他 peer 是否已经通过选项 4 追加过了？

### 2. macOS 上 `sudo wg-quick up wg0` 报 `command not found: wg`

sudo 环境的 `PATH` 里没有 Homebrew。脚本内部已经用绝对路径处理了 LaunchDaemon，但你手动跑时可以：

```bash
sudo $(brew --prefix)/bin/wg-quick up wg0
```

或者把 Homebrew 加入 root 的 PATH。

### 3. 屏幕共享连上后是黑屏 / 一直转圈

- 被控端是否登录了图形会话？如果是刚开机且 FileVault 关闭，应该会停在 loginwindow，可以直接看到登录界面
- 检查 `系统设置 → 通用 → 共享 → 屏幕共享/远程管理` 是否已开启并勾选了允许的用户

### 4. 手机热点切换 / 断网重连后隧道假死

WireGuard 内部会自动重协商握手，一般 25 秒内会恢复。如果长时间不通：

```bash
sudo wg-quick down wg0 && sleep 1 && sudo wg-quick up wg0
```

被控端的 LaunchDaemon 只在开机时拉起隧道，运行中断线不会自动 restart（这是刻意设计的）；实际场景中 `PersistentKeepalive` + WireGuard 的无状态重连已经够用。

### 5. 想删除某个 peer

VPS 上手动编辑 `/etc/wireguard/wg0.conf`，删掉对应的 `[Peer]` 段，然后：

```bash
sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
```

### 6. 想彻底卸载

**VPS**：

```bash
sudo systemctl disable --now wg-quick@wg0
sudo apt remove --purge wireguard
sudo rm -rf /etc/wireguard
```

**macOS 被控端**：

```bash
sudo launchctl unload /Library/LaunchDaemons/com.wireguard.wg0.plist
sudo rm /Library/LaunchDaemons/com.wireguard.wg0.plist
sudo $(brew --prefix)/bin/wg-quick down wg0
brew uninstall wireguard-tools
sudo rm -rf $(brew --prefix)/etc/wireguard
```

**macOS 控制端**：同上，但不需要 `launchctl unload`。

---

## 安全注意事项

- **VPS 的公网 IP 会暴露 UDP 51820**：WireGuard 对未知源默认静默丢包，扫描器看不到端口开放，相对安全；仍建议 VPS 关闭 root 密码登录、只用密钥
- **私钥文件权限必须 600**：脚本已经处理，但如果你手动改配置，注意 `umask 077`
- **备份好 VPS 的 `wg0.conf`**：里面包含所有 peer 的公钥和 IP 分配表；私钥单独保管
- **不要把 `privatekey` 传到 GitHub**：本项目只上传脚本，密钥都是运行时在本机生成，绝不写死在脚本里
- 若被控端有敏感数据，考虑开启 FileVault 并放弃"开机自启即可远控 loginwindow"的便利（详见项目讨论历史）

---

## 脚本设计要点

- **密钥复用**：脚本会检测已有 `privatekey`，不覆盖，避免误操作导致对端集体掉线
- **配置备份**：每次覆盖 `wg0.conf` 前自动生成 `.bak.<timestamp>`
- **公钥校验**：粘贴的公钥若非 44 字符或不以 `=` 结尾会告警（但允许继续）
- **peer 查重**：VPS 追加 peer 时，重复公钥或 IP 占用会直接拒绝
- **热加载**：追加 peer 使用 `wg syncconf`，其他 peer 不掉线
- **芯片自适应**：`$(brew --prefix)` 自动识别 Apple Silicon 与 Intel，plist 写死当次探测到的绝对路径
- **`umask 077`**：所有敏感文件生成时确保权限正确

---

## License

MIT

---

## 免责声明

脚本会修改以下位置，请确认后再运行：

- VPS：`/etc/wireguard/`、`/etc/sysctl.conf`、UFW 规则、systemd 服务
- macOS：`$(brew --prefix)/etc/wireguard/`、`/Library/LaunchDaemons/`

建议在 VPS 上先打快照，在 macOS 上先 Time Machine 备份，再运行本脚本。
