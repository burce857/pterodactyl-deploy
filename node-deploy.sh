#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo '請用 root 執行：sudo bash node-deploy.sh'
  exit 1
fi

NODE_NAME=${NODE_NAME:-}
PANEL_URL=${PANEL_URL:-}
TOKEN=${TOKEN:-}
NODE_ID=${NODE_ID:-}

[[ -n "$NODE_NAME" ]] || read -rp '節點名稱（例如 node3）: ' NODE_NAME
[[ -n "$PANEL_URL" ]] || read -rp 'Panel URL（例如 https://p.example.com）: ' PANEL_URL
[[ -n "$TOKEN" ]] || read -rsp 'Auto-deploy Token: ' TOKEN
echo
[[ -n "$NODE_ID" ]] || read -rp 'Node ID（例如 3）: ' NODE_ID

hostnamectl set-hostname "$NODE_NAME"
sed -i '/^[[:space:]]*127\.0\.1\.1[[:space:]]+/d' /etc/hosts
echo "127.0.1.1 ${NODE_NAME}" >> /etc/hosts

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y curl ca-certificates gnupg socat tcpdump netcat-openbsd

if ! command -v docker >/dev/null 2>&1; then
  curl -sSL https://get.docker.com/ | CHANNEL=stable bash
fi
systemctl enable --now docker

mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x /usr/local/bin/wings

cat >/etc/systemd/system/wings.service <<'EOT'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
ExecStart=/usr/local/bin/wings
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload
systemctl enable wings

/usr/local/bin/wings configure --panel-url "${PANEL_URL}" --token "${TOKEN}" --node "${NODE_ID}"
systemctl restart wings

INTERNAL_IPV6=$(ip -6 addr show dev eth0 scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n1 || true)
echo "偵測到 eth0 IPv6: ${INTERNAL_IPV6:-未找到}"

read -rp '建立 Minecraft IPv6 代理 25565-25600 -> 172.18.0.1 嗎？ [y/N]: ' SETUP_PROXY
if [[ "$SETUP_PROXY" =~ ^[Yy]$ ]]; then
  if [[ -z "$INTERNAL_IPV6" ]]; then
    read -rp '請輸入內部 IPv6: ' INTERNAL_IPV6
  fi

  cat >/usr/local/bin/mc-ipv6-range-proxy.sh <<EOT
#!/usr/bin/env bash
START_PORT=25565
END_PORT=25600
LISTEN_IPV6="${INTERNAL_IPV6}"
BACKEND_IPV4="172.18.0.1"
for PORT in \$(seq \$START_PORT \$END_PORT); do
  socat TCP6-LISTEN:\${PORT},bind="[\${LISTEN_IPV6}]",reuseaddr,fork TCP4:\${BACKEND_IPV4}:\${PORT} &
done
wait
EOT
  chmod +x /usr/local/bin/mc-ipv6-range-proxy.sh

  cat >/etc/systemd/system/mc-ipv6-range-proxy.service <<'EOT'
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
EOT
  systemctl daemon-reload
  systemctl enable --now mc-ipv6-range-proxy.service
fi

echo 'Node 部署完成。'
echo 'Pterodactyl Allocation 建議使用 172.18.0.1:25565-25600'
