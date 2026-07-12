#!/usr/bin/env bash
# WireGuard 组网一键脚本 (hub-and-spoke)
#
# 拓扑:
#   VPS (Ubuntu 22.04, 10.0.0.1)  ── UDP 51820 ──┐
#                                                 │
#   被控端 Mac      (10.0.0.2)  ────────────────┤ 全部经 VPS 中转
#   控制端 Mac A/B  (10.0.0.3+) ────────────────┘
#
# 使用: 三端都跑 `sudo bash wg-setup.sh`,按菜单分别选 1/2/3;
#       peer 装完后到 VPS 上跑选项 4 追加公钥即可。

set -euo pipefail

# ==================== 常量 ====================
readonly WG_PORT=51820
readonly WG_SUBNET="10.0.0.0/24"
readonly VPS_IP="10.0.0.1"
readonly SERVER_IP="10.0.0.2"       # 被控端固定 IP
readonly KEEPALIVE=25
readonly IFACE="wg0"

# macOS 上,把 Homebrew 的路径塞进 PATH,方便以 root 身份调用 wg / wg-quick
if [[ "$(uname -s)" == "Darwin" ]]; then
  for p in /opt/homebrew/bin /usr/local/bin; do
    [[ -d "$p" ]] && export PATH="$p:$PATH"
  done
fi

# ==================== 工具函数 ====================
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

detect_os() {
  case "$(uname -s)" in
    Linux)  echo "linux"  ;;
    Darwin) echo "macos"  ;;
    *) die "不支持的操作系统: $(uname -s)" ;;
  esac
}

require_root() {
  [[ $EUID -eq 0 ]] || die "此操作需要 root 权限,请用 sudo 重跑"
}

# 公钥前 8 位作为人工比对的指纹
key_fingerprint() {
  echo "$1" | cut -c1-8
}

# macOS Homebrew 前缀 (Apple Silicon vs Intel 自动识别)
mac_brew_prefix() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    echo "/opt/homebrew"
  elif [[ -x /usr/local/bin/brew ]]; then
    echo "/usr/local"
  else
    return 1
  fi
}

# 询问并引导用户安装 Homebrew (不自动装,只打印命令)
install_homebrew() {
  [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || \
    die "需要 SUDO_USER 环境变量,请用 sudo bash $0 运行"

  warn "未检测到 Homebrew"
  cat <<EOF

  Homebrew 是 macOS 常用的第三方包管理器,不是系统自带。

  由于 macOS 的 sudo tty-ticket 机制,自动化安装 Homebrew 不稳定,
  请【退出本脚本】,以普通用户 $SUDO_USER 身份手动运行下面这条:

  ┌──────────────────────────────────────────────────────────────
  │ /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  └──────────────────────────────────────────────────────────────

  过程中它会:
    1. 提示你输入 sudo 密码
    2. 下载 Xcode Command Line Tools (几百 MB,几分钟)
    3. 在 /opt/homebrew (Apple Silicon) 或 /usr/local (Intel) 建立环境

  装完之后,再重新执行:
    sudo bash $0
  选择 2 或 3 继续本脚本流程。

EOF
  die "请先手动安装 Homebrew,再重新运行本脚本"
}

# 确保 Homebrew 已安装,返回前缀
ensure_homebrew() {
  local prefix
  if prefix=$(mac_brew_prefix); then
    echo "$prefix"
    return 0
  fi
  install_homebrew >&2
  mac_brew_prefix
}

# 生成密钥对到指定目录,已存在则复用
generate_keypair() {
  local conf_dir="$1"
  umask 077
  mkdir -p "$conf_dir"
  if [[ -f "$conf_dir/privatekey" && -f "$conf_dir/publickey" ]]; then
    warn "已存在密钥,复用: $conf_dir/privatekey"
    return
  fi
  wg genkey | tee "$conf_dir/privatekey" | wg pubkey > "$conf_dir/publickey"
  chmod 600 "$conf_dir/privatekey"
  chmod 644 "$conf_dir/publickey"
  log "已生成密钥对: $conf_dir/{privatekey,publickey}"
}

# 备份已有配置
backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local bak="${f}.bak.$(date +%s)"
    cp "$f" "$bak"
    warn "已备份原配置: $bak"
  fi
}

# ==================== 1) VPS 端 ====================
setup_vps() {
  require_root
  [[ "$(detect_os)" == "linux" ]] || die "选项 1 只能在 Ubuntu VPS 上运行"

  if ! command -v apt-get >/dev/null 2>&1; then
    die "当前脚本仅支持 Debian/Ubuntu 系 VPS,未检测到 apt-get。请在 Ubuntu 22.04 上运行。"
  fi

  log "apt 安装 wireguard..."
  apt-get update -y
  apt-get install -y wireguard curl

  local conf_dir="/etc/wireguard"
  generate_keypair "$conf_dir"
  local privkey pubkey
  privkey=$(cat "$conf_dir/privatekey")
  pubkey=$(cat "$conf_dir/publickey")

  log "开启 IPv4 转发..."
  if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  log "写入 $conf_dir/$IFACE.conf ..."
  backup_if_exists "$conf_dir/$IFACE.conf"
  cat > "$conf_dir/$IFACE.conf" <<EOF
[Interface]
Address = $VPS_IP/24
ListenPort = $WG_PORT
PrivateKey = $privkey

# ↓↓↓ peers 由选项 4 追加到此文件末尾 ↓↓↓
EOF
  chmod 600 "$conf_dir/$IFACE.conf"

  log "防火墙放行 UDP $WG_PORT ..."
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$WG_PORT/udp" >/dev/null
    log "已通过 ufw 放行"
  else
    warn "未启用 ufw,请自行确认云厂商安全组已放行 UDP $WG_PORT"
  fi

  log "启动 wg-quick@$IFACE 并设置开机自启..."
  systemctl enable "wg-quick@$IFACE" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@$IFACE"

  local pub_ip
  pub_ip=$(curl -s4 --max-time 3 ifconfig.me || echo "<请自行确认>")

  cat <<EOF

$(log "======= VPS 配置完成 =======")
  公网 IP  : $pub_ip
  监听端口 : UDP $WG_PORT
  隧道 IP  : $VPS_IP

  【重要】把下面的公钥保存好,配置被控/控制端时要粘贴进去:
  ┌────────────────────────────────────────────────
  │ VPS 公钥 : $pubkey
  │ 指纹     : $(key_fingerprint "$pubkey")
  └────────────────────────────────────────────────

  验证:
    wg show
    ss -lun | grep $WG_PORT

  下一步: 到被控/控制端跑本脚本选 2 或 3
EOF
}

# ==================== macOS 通用配置 ====================
# 参数: $1=role (server|client)   $2=分配 IP
setup_mac_common() {
  local role="$1"
  local assign_ip="$2"

  [[ "$(detect_os)" == "macos" ]] || die "此选项只能在 macOS 上运行"
  require_root
  [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] || \
    die "请以普通用户 sudo bash $0 运行,不要直接用 root 登录"

  local brew_prefix
  brew_prefix=$(ensure_homebrew)
  local conf_dir="$brew_prefix/etc/wireguard"
  local wgquick="$brew_prefix/bin/wg-quick"

  if ! command -v wg >/dev/null 2>&1; then
    log "以用户 $SUDO_USER 身份 brew install wireguard-tools ..."
    sudo -u "$SUDO_USER" -H "$brew_prefix/bin/brew" install wireguard-tools
    export PATH="$brew_prefix/bin:$PATH"
  else
    log "wireguard-tools 已安装"
  fi

  generate_keypair "$conf_dir"
  local privkey pubkey
  privkey=$(cat "$conf_dir/privatekey")
  pubkey=$(cat "$conf_dir/publickey")

  echo
  read -r -p "请输入 VPS 公网 IP (或域名): " vps_endpoint
  [[ -n "$vps_endpoint" ]] || die "VPS Endpoint 不能为空"
  read -r -p "请粘贴 VPS 公钥 (选项 1 输出的那串): " vps_pubkey
  [[ -n "$vps_pubkey" ]] || die "VPS 公钥不能为空"
  # 简单校验:WireGuard 公钥固定 44 字符 base64 (末尾 =)
  if [[ ${#vps_pubkey} -ne 44 || "${vps_pubkey: -1}" != "=" ]]; then
    warn "VPS 公钥长度或格式看起来异常 (标准是 44 字符 base64,以 = 结尾)"
    read -r -p "确认继续? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || die "已取消"
  fi

  log "写入 $conf_dir/$IFACE.conf ..."
  backup_if_exists "$conf_dir/$IFACE.conf"
  cat > "$conf_dir/$IFACE.conf" <<EOF
[Interface]
Address = $assign_ip/24
PrivateKey = $privkey

[Peer]
PublicKey = $vps_pubkey
Endpoint = $vps_endpoint:$WG_PORT
AllowedIPs = $WG_SUBNET
PersistentKeepalive = $KEEPALIVE
EOF
  chmod 600 "$conf_dir/$IFACE.conf"

  if [[ "$role" == "server" ]]; then
    install_launchdaemon "$wgquick" "$brew_prefix"
    log "被控端 LaunchDaemon 已装,开机自动拉起隧道"
  fi

  cat <<EOF

$(log "======= macOS 端配置完成 (角色: $role) =======")
  本机隧道 IP: $assign_ip
  配置文件   : $conf_dir/$IFACE.conf

  【下一步】把下面这段拿到 VPS 上,跑本脚本选 4 追加 peer:
  ┌────────────────────────────────────────────────
  │ 本机公钥: $pubkey
  │ 指纹    : $(key_fingerprint "$pubkey")
  │ 分配 IP : $assign_ip
  └────────────────────────────────────────────────
EOF

  if [[ "$role" == "server" ]]; then
    cat <<EOF

  被控端还需要一次性手工操作 (脚本不管):
    系统设置 → 通用 → 共享 → 开启 "屏幕共享" 或 "远程管理"

  VPS 端追加 peer 后验证隧道:
    ping $VPS_IP
    sudo wg show
EOF
  else
    cat <<EOF

  控制端日常使用:
    sudo $wgquick up   $IFACE     # 开隧道
    open vnc://$SERVER_IP         # 连被控端屏幕共享
    sudo $wgquick down $IFACE     # 收工
EOF
  fi
}

# 被控端 LaunchDaemon (只 RunAtLoad,不做健康检查)
install_launchdaemon() {
  local wgquick="$1"
  local brew_prefix="$2"
  local plist="/Library/LaunchDaemons/com.wireguard.$IFACE.plist"

  # 卸载旧的 (如果存在)
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null || true
  fi

  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wireguard.$IFACE</string>
    <key>ProgramArguments</key>
    <array>
        <string>$wgquick</string>
        <string>up</string>
        <string>$IFACE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$brew_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/wireguard-$IFACE.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/wireguard-$IFACE.err</string>
</dict>
</plist>
EOF
  chown root:wheel "$plist"
  chmod 644 "$plist"
  launchctl load "$plist"
}

# ==================== 2) 被控端 ====================
setup_server_mac() {
  setup_mac_common "server" "$SERVER_IP"
}

# ==================== 3) 控制端 ====================
setup_client_mac() {
  echo
  read -r -p "请输入本控制端分配的 IP (10.0.0.3 / 10.0.0.4 / 10.0.0.5 ...): " client_ip
  [[ -n "$client_ip" ]] || die "IP 不能为空"
  if [[ ! "$client_ip" =~ ^10\.0\.0\.([3-9]|[1-9][0-9])$ ]]; then
    warn "IP $client_ip 不在推荐范围 10.0.0.3 - 10.0.0.99"
    read -r -p "确认继续? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || die "已取消"
  fi
  setup_mac_common "client" "$client_ip"
}

# ==================== 4) VPS 追加 peer ====================
add_peer_on_vps() {
  require_root
  [[ "$(detect_os)" == "linux" ]] || die "选项 4 只能在 VPS 上运行"

  local conf="/etc/wireguard/$IFACE.conf"
  [[ -f "$conf" ]] || die "$conf 不存在,请先跑选项 1"

  echo
  read -r -p "peer 公钥 (从被控/控制端脚本输出复制): " peer_pubkey
  [[ -n "$peer_pubkey" ]] || die "公钥不能为空"
  if [[ ${#peer_pubkey} -ne 44 || "${peer_pubkey: -1}" != "=" ]]; then
    warn "公钥长度或格式异常 (标准 44 字符 base64,末尾 =)"
    read -r -p "确认继续? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || die "已取消"
  fi

  read -r -p "分配给该 peer 的隧道 IP (如 10.0.0.2 / 10.0.0.3): " peer_ip
  [[ -n "$peer_ip" ]] || die "IP 不能为空"
  [[ "$peer_ip" =~ ^10\.0\.0\.[0-9]+$ ]] || die "IP 必须在 10.0.0.0/24 网段"

  # 查重
  if grep -qF "$peer_pubkey" "$conf"; then
    die "该公钥已存在于 $conf,请先清理再追加"
  fi
  if grep -qE "AllowedIPs[[:space:]]*=[[:space:]]*$peer_ip/32" "$conf"; then
    die "IP $peer_ip 已被占用,请换一个"
  fi

  log "追加 peer 到 $conf ..."
  cat >> "$conf" <<EOF

[Peer]
# 追加于 $(date '+%F %T'),指纹 $(key_fingerprint "$peer_pubkey")
PublicKey = $peer_pubkey
AllowedIPs = $peer_ip/32
EOF

  log "热加载配置 (无需重启隧道)..."
  wg syncconf "$IFACE" <(wg-quick strip "$IFACE")

  echo
  log "======= peer 追加成功 ======="
  wg show "$IFACE"
  cat <<EOF

  对端一旦 wg-quick up,该 peer 的 "latest handshake" 会更新。
  若长时间无握手,排查:
    1. 对端是否已 sudo wg-quick up $IFACE ?
    2. 云厂商安全组是否放行 UDP $WG_PORT ?
    3. 对端 Endpoint 是否指向本 VPS 公网 IP ?
    4. 对端 PersistentKeepalive 是否为 $KEEPALIVE ?
EOF
}

# ==================== 主菜单 ====================
show_menu() {
  cat <<'EOF'

╔══════════════════════════════════════════════════════════╗
║              WireGuard 组网一键脚本                      ║
║   VPS(10.0.0.1) ─ 被控(10.0.0.2) ─ 控制端(10.0.0.3+)     ║
╠══════════════════════════════════════════════════════════╣
║  1) VPS 端安装配置        (Ubuntu 22.04)                ║
║  2) 被控端安装配置        (macOS,含 LaunchDaemon 自启)  ║
║  3) 控制端安装配置        (macOS,手动 wg-quick up/down) ║
║  4) 在 VPS 上追加一个 peer                               ║
║  q) 退出                                                 ║
╚══════════════════════════════════════════════════════════╝
EOF
  read -r -p "请选择 [1/2/3/4/q]: " choice
  case "$choice" in
    1)   setup_vps ;;
    2)   setup_server_mac ;;
    3)   setup_client_mac ;;
    4)   add_peer_on_vps ;;
    q|Q) exit 0 ;;
    *)   die "无效选择: $choice" ;;
  esac
}

show_menu
