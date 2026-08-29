#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Wings Node 一鍵部署 v17
# Ubuntu 22.04 / 24.04
# ============================================================

LOG="/var/log/pterodactyl-node-deploy.log"

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "❌ 需要 root 權限。"
    exit 1
fi

exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive

info(){ echo -e "\n🔹 $*"; }
fail(){ echo "❌ $*" >&2; exit 1; }

apt_retry() {
    local tries=0
    until apt-get "$@"; do
        tries=$((tries+1))
        if (( tries >= 3 )); then return 1; fi
        sleep 3
    done
}
trap 'echo "❌ 安裝在第 $LINENO 行失敗。Log: '"$LOG"'"' ERR

. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "目前只支援 Ubuntu"
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) fail "不支援 Ubuntu ${VERSION_ID:-unknown}";; esac

echo "============================================================"
echo " Pterodactyl Wings Node 一鍵部署 v17"
echo "============================================================"

read -rp "Node 名稱（例 node3）: " NODE_NAME
read -rp "Panel URL（例 https://p.example.com）: " PANEL_URL
read -rp "Node ID（例 3）: " NODE_ID
read -rsp "Generate Token / Auto Deploy Token: " TOKEN
echo
read -rp "這台 Node 的 Public IPv6（可留空稍後設定）: " PUBLIC_IPV6
read -rp "自動建立 Minecraft IPv6 Proxy 25565-25600？ [Y/n]: " SETUP_PROXY
SETUP_PROXY="${SETUP_PROXY:-Y}"

[[ "$PANEL_URL" == http://* || "$PANEL_URL" == https://* ]] || PANEL_URL="https://${PANEL_URL}"
[[ -n "$NODE_NAME" && -n "$PANEL_URL" && -n "$NODE_ID" && -n "$TOKEN" ]] || fail "必要欄位不可空白"

hostnamectl set-hostname "$NODE_NAME"
if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1 ${NODE_NAME}/" /etc/hosts
else
    echo "127.0.1.1 ${NODE_NAME}" >> /etc/hosts
fi

info "安裝 Node 常用依賴"
apt_retry update -y
apt_retry install -y \
    ca-certificates curl wget gnupg gpg lsb-release apt-transport-https \
    software-properties-common unzip zip tar git rsync jq nano \
    socat tcpdump netcat-openbsd iproute2 iputils-ping dnsutils openssl

info "安裝/確認 Docker"
if ! command -v docker >/dev/null 2>&1; then
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
fi
systemctl enable --now docker

docker info >/dev/null 2>&1 || fail "Docker 無法正常運作；VPS 可能限制 nested Docker。"

info "安裝 Wings"
mkdir -p /etc/pterodactyl
chmod 755 /etc/pterodactyl

# 先建立一份可讀的範例設定，方便之後手動修改/比對。
# Wings configure 成功後會另外產生真正的 /etc/pterodactyl/config.yml。
cat >/etc/pterodactyl/config.yml.example <<'EOF'
# ============================================================
# Pterodactyl Wings config.yml 範例
# 這只是示範檔，不會被 Wings 直接使用。
# 真正設定檔：/etc/pterodactyl/config.yml
# ============================================================

debug: false

uuid: "NODE-UUID-HERE"
token_id: "TOKEN-ID-HERE"
token: "TOKEN-HERE"

api:
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false
    cert: /etc/letsencrypt/live/node.example.com/fullchain.pem
    key: /etc/letsencrypt/live/node.example.com/privkey.pem

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: 2022

allowed_mounts: []

remote: "https://panel.example.com"

docker:
  network:
    interface: 172.18.0.1
    dns:
      - 1.1.1.1
      - 1.0.0.1
    name: pterodactyl_nw
    ispn: false
    driver: bridge
    network_mode: pterodactyl_nw
    is_internal: false
    enable_icc: true
    network_mtu: 1500
    interfaces:
      v4:
        subnet: 172.18.0.0/16
        gateway: 172.18.0.1

throttles:
  enabled: true
  lines: 2000
  line_reset_interval: 100

remote_query:
  timeout: 30
  boot_servers_per_page: 50

crash_detection:
  enabled: true
  detect_clean_exit_as_crash: true
  timeout: 60
EOF

cat >/etc/pterodactyl/public-ipv6.example <<'EOF'
# 只放這台 Node 對外給玩家連線的 Public IPv6。
# 例如：
2602:f470:40:1:1234:5678:abcd:ef01
EOF

cat >/etc/pterodactyl/README.txt <<'EOF'
Pterodactyl Node 設定目錄
==========================

真正 Wings 設定：
  /etc/pterodactyl/config.yml

Wings 設定範例：
  /etc/pterodactyl/config.yml.example

Public IPv6 範例：
  /etc/pterodactyl/public-ipv6.example

Public IPv6 實際值（由腳本建立）：
  /etc/pterodactyl/public-ipv6

常用編輯：
  nano /etc/pterodactyl/config.yml

修改完 Wings 設定後：
  systemctl restart wings

查看 Wings Log：
  journalctl -u wings -n 100 --no-pager
EOF

chmod 644 /etc/pterodactyl/config.yml.example
chmod 644 /etc/pterodactyl/public-ipv6.example
chmod 644 /etc/pterodactyl/README.txt

echo "✅ 已建立 /etc/pterodactyl 範例設定檔"
if [[ -n "${PUBLIC_IPV6:-}" ]]; then
    printf '%s\n' "$PUBLIC_IPV6" > /etc/pterodactyl/public-ipv6
    chmod 600 /etc/pterodactyl/public-ipv6
fi

case "$(uname -m)" in
    x86_64|amd64) WARCH="amd64" ;;
    aarch64|arm64) WARCH="arm64" ;;
    *) fail "不支援架構：$(uname -m)" ;;
esac

curl -fL -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WARCH}"
chmod +x /usr/local/bin/wings

cat >/etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

if [[ -f /etc/pterodactyl/config.yml ]]; then
    cp -a /etc/pterodactyl/config.yml "/etc/pterodactyl/config.yml.bak.$(date +%Y%m%d-%H%M%S)"
fi

info "從 Panel 抓取 config.yml"
/usr/local/bin/wings configure \
    --panel-url "$PANEL_URL" \
    --token "$TOKEN" \
    --node "$NODE_ID"

systemctl enable --now wings
sleep 3

if ! systemctl is-active --quiet wings; then
    journalctl -u wings -n 100 --no-pager || true
    fail "Wings 啟動失敗"
fi

# Detect pterodactyl bridge address
for _ in {1..10}; do
    ip link show pterodactyl0 >/dev/null 2>&1 && break
    sleep 1
done

BACKEND_IPV4="$(ip -4 -o addr show pterodactyl0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
BACKEND_IPV4="${BACKEND_IPV4:-172.18.0.1}"
echo "ℹ️ Allocation/Backend IPv4: $BACKEND_IPV4"

if [[ "$SETUP_PROXY" =~ ^[Yy]$ ]]; then
    info "建立 Minecraft IPv6 Proxy"

    INTERNAL_IPV6="$(ip -6 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    if [[ -z "$INTERNAL_IPV6" ]]; then
        read -rp "無法自動偵測 eth0 global IPv6，請輸入內部 IPv6: " INTERNAL_IPV6
    else
        echo "偵測到內部 IPv6: $INTERNAL_IPV6"
    fi

    read -rp "代理 Port 起點 [25565]: " START_PORT
    START_PORT="${START_PORT:-25565}"
    read -rp "代理 Port 終點 [25600]: " END_PORT
    END_PORT="${END_PORT:-25600}"

    systemctl stop mc-ipv6-range-proxy.service 2>/dev/null || true
    pkill -f '/usr/local/bin/mc-ipv6-range-proxy.sh' 2>/dev/null || true
    pkill socat 2>/dev/null || true

    cat >/usr/local/bin/mc-ipv6-range-proxy.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
START_PORT=${START_PORT}
END_PORT=${END_PORT}
LISTEN_IPV6="${INTERNAL_IPV6}"
BACKEND_IPV4="${BACKEND_IPV4}"
PIDS=()

cleanup() {
    for P in "\${PIDS[@]:-}"; do
        kill "\$P" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

for PORT in \$(seq "\$START_PORT" "\$END_PORT"); do
    socat TCP6-LISTEN:\${PORT},bind="[\${LISTEN_IPV6}]",ipv6only=1,reuseaddr,fork \
          TCP4:\${BACKEND_IPV4}:\${PORT} &
    PIDS+=("\$!")
done
wait
EOF

    chmod +x /usr/local/bin/mc-ipv6-range-proxy.sh

    cat >/etc/systemd/system/mc-ipv6-range-proxy.service <<'EOF'
[Unit]
Description=Minecraft IPv6 Range Proxy
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mc-ipv6-range-proxy.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now mc-ipv6-range-proxy.service
fi

echo
echo "============================================================"
echo "✅ Node 部署完成"
echo "Node: $NODE_NAME"
echo "Panel: $PANEL_URL"
echo "Node ID: $NODE_ID"
echo "Allocation 建議 IP: $BACKEND_IPV4"
[[ -n "${PUBLIC_IPV6:-}" ]] && echo "Public IPv6: $PUBLIC_IPV6"
if [[ "$SETUP_PROXY" =~ ^[Yy]$ ]]; then
    echo "IPv6 Proxy: ${INTERNAL_IPV6}:${START_PORT}-${END_PORT} -> ${BACKEND_IPV4}:same-port"
fi
echo
echo "設定檔："
echo "  真正設定：/etc/pterodactyl/config.yml"
echo "  範例設定：/etc/pterodactyl/config.yml.example"
echo "  說明文件：/etc/pterodactyl/README.txt"
echo "Log: $LOG"
echo "============================================================"
