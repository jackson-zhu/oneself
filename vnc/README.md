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

## 被控端预配置清单（一次性手工操作）

以下几项都是**远控脚本不管、但无人值守必须做**的一次性配置。建议在跑 `wg-setup.sh` **之前或之后**都行，但必须做完，否则远控会遇到"合盖后连不上""屏幕黑屏"等问题。

### 1. 开启屏幕共享 / 远程管理

- 路径：`系统设置 → 通用 → 共享 → 屏幕共享`（或 `远程管理`）
- 选择"仅允许这些用户"并勾选你的办公账户
- **屏幕共享 与 远程管理二选一，不要同时开**（互相冲突）

### 2. 关闭所有空闲休眠（开盖状态下生效）

打开 Terminal 执行：

```bash
# 系统层面禁止睡眠
sudo pmset -a disablesleep 1

# 交流电源接入时: 系统 / 显示器 / 硬盘永不休眠
sudo pmset -c sleep 0
sudo pmset -c displaysleep 0
sudo pmset -c disksleep 0

# 电池模式下同上 (合盖后会被 clamshell sleep 覆盖,这个仅影响开盖时)
sudo pmset -b sleep 0
sudo pmset -b displaysleep 0

# 关闭 Power Nap (周期性唤醒同步邮件,远控用不上)
sudo pmset -a powernap 0

# 断电恢复后自动开机
sudo pmset -a autorestart 1

# 检查当前设置
pmset -g
pmset -g custom
```

### 3. 【M 系 Mac 关键】解除合盖休眠

**这是 M 系 Mac 无人值守最大的坑**：`pmset` 无法禁用合盖休眠，合盖后系统会强制进入 `clamshell sleep`，此时**网络断开、WireGuard 掉线、无法被远控**。

苹果官方的"合盖仍工作"要求外接显示器 + 外接电源 + 外接键鼠，你没有外接显示器就没法满足。绕过方法有两种：

#### 方案 A：软件（推荐，免费）

1. Mac App Store 安装 [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704)（免费）
2. 从 GitHub 下载配套工具 [Amphetamine Enhancer](https://github.com/x74353/Amphetamine-Enhancer)
3. 打开 Amphetamine Enhancer → 安装 "Close Display Sleep Prevention"（会引导授权辅助功能 + 完整磁盘访问）
4. Amphetamine → 偏好设置 → **勾选 "Allow display sleep while session is active"** 及合盖相关选项
5. 建议直接创建一个"永久激活"的 Session，或者用触发器绑定 wg0 隧道

**注意**：Amphetamine Enhancer 是社区维护的开源工具，装的时候会弹权限对话框，按提示允许即可。

#### 方案 B：硬件（终极稳定）

- 淘宝购买 **USB-C HDMI EDID 欺骗器**（俗称"假显示器 / dummy plug"），几块到几十块
- 插上 Mac 会误认为外接了 4K 显示器，即使合盖也保持 clamshell 工作模式
- 优点：完全不依赖软件、系统升级也不会失效
- 缺点：占用一个 USB-C 口

**建议**：先用方案 A，同时买一个 dummy plug 放抽屉里备用。

### 4. 关闭自动更新（避免半夜自动重启）

- `系统设置 → 通用 → 软件更新 → ⓘ → 关闭所有自动更新选项`
- 否则某个凌晨系统自动装安全更新 + 重启，你合盖状态就再也连不上了

### 5. 【可选】准备低分辨率切换工具

如果你的 VPS 带宽不足（<20 Mbps 稳定），建议装个分辨率切换工具，远控前切低分辨率降低 VNC 数据量。M 系 Mac 推荐：

```bash
brew install displayplacer
```

用法见 [常见问题排查](#常见问题排查) 第 3 条。

### 6. 【可选】关闭 macOS 所有动画和特效（带宽不足必做）

#### 系统设置可视化操作
- `系统设置 → 辅助功能 → 显示`：
  - ✅ 打开"减少透明度"
  - ✅ 打开"减少动态效果"
- 换纯色壁纸（关闭动态壁纸）

#### Terminal 一键关闭动画（可选但有效）
粘贴这些命令到被控端 Mac Terminal，执行后会杀掉 Dock/Finder/SystemUIServer 立即生效：

```bash
# 1. 窗口系统动画
defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001

# 2. Dock 动画优化
defaults write com.apple.dock launchanim -bool false
defaults write com.apple.dock autohide-time-modifier -float 0
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock no-bouncing -bool TRUE
defaults write com.apple.dock expose-animation-duration -float 0
defaults write com.apple.dock workspaces-swoosh-animation-off -bool TRUE
defaults write com.apple.dock mineffect -string "scale"
defaults write com.apple.dock minimize-to-application -bool true

# 3. Finder 动画
defaults write com.apple.finder DisableAllAnimations -bool true

# 重启服务生效
killall Dock
killall Finder
killall SystemUIServer
```

这些能进一步降低 VNC 画面重绘的数据量。

### 7. 校验一次

做完以上所有配置后，做一次"真无人值守"演练：

1. 断开外接电源（如果有）
2. 合盖
3. 走开 5 分钟
4. 回来用控制端连 `vnc://10.0.0.2`，能连上 = 合盖不休眠配置成功

**这一步千万别省**，很多人以为配好了，结果第一次真无人值守就掉线。

---

## 使用方法

### Step 1 — VPS 端安装

登录 VPS：

```bash
curl -fsSLO https://raw.githubusercontent.com/jackson-zhu/oneself/refs/heads/main/vnc/wg-setup.sh
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
curl -fsSLO https://raw.githubusercontent.com/jackson-zhu/oneself/refs/heads/main/vnc/wg-setup.sh
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
curl -fsSLO https://raw.githubusercontent.com/jackson-zhu/oneself/refs/heads/main/vnc/wg-setup.sh
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

## VNC 极致优化（带宽不足必备）

如果你的 VPS 实际带宽 < 20 Mbps（像之前实测的 7 Mbps），这一节**非常重要**，能让你从"勉强能用"变成"基本流畅"。

### 1. macOS 原生屏幕共享服务优化（关键）

这些优化直接作用于 ARD（Apple Remote Desktop）/ 屏幕共享的底层压缩和传输，比单纯降分辨率效果更明显。

在被控端 Mac Terminal 执行：

```bash
# 开启屏幕共享压缩 (0=关, 1=低, 2=中, 3=高) - 推荐 2
sudo defaults write /Library/Preferences/com.apple.RemoteManagement ARDCompressionLevel -int 2

# 禁止远程桌面传输桌面背景图片（静态壁纸还可以，动态/高清壁纸彻底禁止）
sudo defaults write /Library/Preferences/com.apple.RemoteManagement LoadMovies -bool false

# 禁止远程桌面显示系统特效（与前面关闭动画配合）
sudo defaults write /Library/Preferences/com.apple.RemoteManagement EnableRemoteDesktop -bool true

# 重启屏幕共享服务热加载
sudo launchctl kickstart -k system/com.apple.screensharing
```

### 2. 分辨率降档（已在预配置里提到，这里再强调）

M 系 MacBook Air M4 默认 framebuffer 是 ~3420×2214，直接传会占满 30 Mbps。用 `displayplacer` 切到真正的非 Retina 低分辨率：

```bash
# 先看你有哪些可用的分辨率
displayplacer list

# 切到 1440×900 non-HiDPI（用上面 list 输出的 id 替换下面的 XXX）
displayplacer "id:XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX res:1440x900 hz:60 scaling:off"
```

本地屏幕会变得糊，但 VNC 数据量会降到原来的 1/5。

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
