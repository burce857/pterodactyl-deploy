#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Wings Node 一鍵部署腳本（Ubuntu 22.04 / 24.04）
# 會自動補齊常見缺少套件，盡量可重複執行。
#
# 會安裝：
# - Docker
# - Wings
# - socat
# - tcpdump
# - netcat
# - curl / wget / jq / nano / unzip / tar / ca-certificates
# - systemd service
#
# 可選：
# - 建立 Minecraft IPv6 -> Docker IPv4 轉發
#
# 注意：
# - Pterodactyl Allocation 建議使用 172.18.0.1
# - Public IPv6 僅用於玩家連線，不要直接給 Docker 綁
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "❌ 請用 root 執行：sudo bash node-deploy.sh"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo " Pterodactyl Wings Node 一鍵部署"
echo "=========================================="

read -rp "節點名稱（例如 node3）: " NODE_NAME
read -rp "Panel URL（例如 https://p.example.com）: " PANEL_URL
read -rp "Node ID（例如 3）: " NODE_ID
read -rsp "Auto Deploy Token / Application API Token: " TOKEN
echo

if [[ -z "$NODE_NAME" || -z "$PANEL_URL" || -z "$NODE_ID" || -z "$TOKEN" ]]; then
    echo "❌ 節點名稱、Panel URL、Node ID、Token 都不可空白。"
    exit 1
fi

echo
echo "🖥️ 設定 hostname..."
hostnamectl set-hostname "$NODE_NAME"

# 修正 sudo: unable to resolve host
if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1 ${NODE_NAME}/" /etc/hosts
else
    echo "127.0.1.1 ${NODE_NAME}" >> /etc/hosts
fi

echo "📦 更新套件..."
apt-get update

echo "📦 安裝常用工具與相依套件..."
apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    gpg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    unzip \
    zip \
    tar \
    git \
    rsync \
    jq \
    nano \
    socat \
    tcpdump \
    netcat-openbsd \
    iproute2 \
    iputils-ping \
    dnsutils \
    openssl

echo "🐳 檢查 Docker..."
if ! command -v docker >/dev/null 2>&1; then
    echo "📦 安裝 Docker..."
    curl -fsSL https://get.docker.com/ | CHANNEL=stable bash
fi

systemctl enable --now docker

echo "📁 建立 Wings 設定目錄..."
mkdir -p /etc/pterodactyl

echo "⬇️ 安裝最新版 Wings..."
curl -fL \
    -o /usr/local/bin/wings \
    https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64

chmod +x /usr/local/bin/wings

echo "⚙️ 建立 Wings systemd service..."
cat >/etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wings

echo
echo "🔗 從 Panel 抓取 node 設定..."

# 防止使用者漏打協定
if [[ "$PANEL_URL" != http://* && "$PANEL_URL" != https://* ]]; then
    PANEL_URL="https://${PANEL_URL}"
fi

# 如果已有 config.yml 先備份
if [[ -f /etc/pterodactyl/config.yml ]]; then
    cp /etc/pterodactyl/config.yml \
        "/etc/pterodactyl/config.yml.backup.$(date +%Y%m%d-%H%M%S)"
fi

/usr/local/bin/wings configure \
    --panel-url "$PANEL_URL" \
    --token "$TOKEN" \
    --node "$NODE_ID"

echo "🚀 啟動 Wings..."
systemctl restart wings

sleep 2

echo
echo "📋 Wings 狀態："
systemctl --no-pager --full status wings || true

echo
echo "🔎 Wings 8080 監聽："
ss -ltnp | grep ':8080' || true

# ------------------------------------------------------------
# Minecraft IPv6 proxy
# ------------------------------------------------------------

echo
read -rp "要建立 Minecraft IPv6 代理 (25565-25600 → 172.18.0.1) 嗎？ [y/N]: " SETUP_PROXY

if [[ "$SETUP_PROXY" =~ ^[Yy]$ ]]; then
    echo
    echo "🔎 偵測 eth0 的 global IPv6..."

    INTERNAL_IPV6="$(
        ip -6 addr show dev eth0 scope global 2>/dev/null \
        | awk '/inet6 / {print $2}' \
        | cut -d/ -f1 \
        | head -n1
    )"

    if [[ -n "${INTERNAL_IPV6:-}" ]]; then
        echo "偵測到：${INTERNAL_IPV6}"
        read -rp "使用這個 IPv6？ [Y/n]: " USE_DETECTED
        if [[ "$USE_DETECTED" =~ ^[Nn]$ ]]; then
            read -rp "請輸入內部 IPv6: " INTERNAL_IPV6
        fi
    else
        echo "⚠️ 無法自動偵測 eth0 global IPv6"
        read -rp "請輸入內部 IPv6（例如 fdf5:...）: " INTERNAL_IPV6
    fi

    read -rp "代理起始 Port [25565]: " START_PORT
    START_PORT="${START_PORT:-25565}"

    read -rp "代理結束 Port [25600]: " END_PORT
    END_PORT="${END_PORT:-25600}"

    read -rp "Docker Backend IPv4 [172.18.0.1]: " BACKEND_IPV4
    BACKEND_IPV4="${BACKEND_IPV4:-172.18.0.1}"

    echo "🧹 清除舊的手動 socat 程序..."
    systemctl stop mc-ipv6-range-proxy.service 2>/dev/null || true
    pkill -f '/usr/local/bin/mc-ipv6-range-proxy.sh' 2>/dev/null || true
    pkill socat 2>/dev/null || true

    echo "📝 建立 IPv6 proxy 腳本..."
    cat >/usr/local/bin/mc-ipv6-range-proxy.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

START_PORT=${START_PORT}
END_PORT=${END_PORT}
LISTEN_IPV6="${INTERNAL_IPV6}"
BACKEND_IPV4="${BACKEND_IPV4}"

PIDS=()

cleanup() {
    for PID in "\${PIDS[@]:-}"; do
        kill "\$PID" 2>/dev/null || true
    done
}

trap cleanup EXIT INT TERM

for PORT in \$(seq "\$START_PORT" "\$END_PORT"); do
    socat \
        TCP6-LISTEN:\${PORT},bind="[\${LISTEN_IPV6}]",ipv6only=1,reuseaddr,fork \
        TCP4:\${BACKEND_IPV4}:\${PORT} &
    PIDS+=("\$!")
done

wait
EOF

    chmod +x /usr/local/bin/mc-ipv6-range-proxy.sh

    echo "⚙️ 建立 IPv6 proxy systemd service..."
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

    sleep 1

    echo
    echo "📋 IPv6 proxy 狀態："
    systemctl --no-pager --full status mc-ipv6-range-proxy.service || true

    echo
    echo "🔎 Port ${START_PORT} 監聽狀態："
    ss -ltnp | grep ":${START_PORT}" || true
fi

echo
echo "=========================================="
echo "✅ Node 部署完成"
echo "=========================================="
echo "Node Name : ${NODE_NAME}"
echo "Node ID   : ${NODE_ID}"
echo "Panel URL : ${PANEL_URL}"
echo
echo "Wings："
echo "  systemctl status wings --no-pager"
echo
echo "Wings Log："
echo "  journalctl -u wings -n 100 --no-pager"
echo
echo "Docker："
echo "  docker ps"
echo
echo "如果有啟用 Minecraft IPv6 proxy："
echo "  Pterodactyl Allocation 使用 ${BACKEND_IPV4:-172.18.0.1}:PORT"
echo "  不要直接把 Public IPv6 當 Docker Allocation。"
echo "=========================================="
