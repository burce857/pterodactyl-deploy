#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Wings Node 一鍵部署 v4
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
trap 'echo "❌ 安裝在第 $LINENO 行失敗。Log: '"$LOG"'"' ERR

. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "目前只支援 Ubuntu"
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) fail "不支援 Ubuntu ${VERSION_ID:-unknown}";; esac

echo "============================================================"
echo " Pterodactyl Wings Node 一鍵部署 v4"
echo "============================================================"

read -rp "Node 名稱（例 node3）: " NODE_NAME
read -rp "Panel URL（例 https://p.example.com）: " PANEL_URL
read -rp "Node ID（例 3）: " NODE_ID
read -rsp "Generate Token / Auto Deploy Token: " TOKEN
echo
read -rp "自動建立 Minecraft IPv6 Proxy？ [Y/n]: " SETUP_PROXY
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
apt-get update -y
apt-get install -y \
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
if [[ "$SETUP_PROXY" =~ ^[Yy]$ ]]; then
    echo "IPv6 Proxy: ${INTERNAL_IPV6}:${START_PORT}-${END_PORT} -> ${BACKEND_IPV4}:same-port"
fi
echo "Log: $LOG"
echo "============================================================"
