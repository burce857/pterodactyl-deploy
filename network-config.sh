#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="21"
PTERO_DIR="/var/www/pterodactyl"
MAP_FILE="$PTERO_DIR/storage/app/publicaddress/node-ips.json"
PARTIAL="$PTERO_DIR/resources/views/ptero-tool-public-address.blade.php"

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "❌ 需要 root 權限。"
    exit 1
fi

pause(){ read -rp "按 Enter 繼續..." _; }

detect_backend() {
    local ip
    ip="$(ip -4 -o addr show pterodactyl0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    echo "${ip:-172.18.0.1}"
}

detect_internal_v6() {
    ip -6 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true
}

setup_proxy() {
    command -v socat >/dev/null 2>&1 || {
        apt-get update
        apt-get install -y socat iproute2
    }

    local internal backend start end input
    internal="$(detect_internal_v6)"
    backend="$(detect_backend)"

    echo "偵測內部 IPv6: ${internal:-找不到}"
    echo "偵測 Docker backend: $backend"

    read -rp "內部 IPv6 [${internal}]: " input
    internal="${input:-$internal}"
    [[ -n "$internal" ]] || { echo "❌ IPv6 不可空白"; return 1; }

    read -rp "Backend IPv4 [$backend]: " input
    backend="${input:-$backend}"

    read -rp "起始 Port [25565]: " start
    start="${start:-25565}"
    read -rp "結束 Port [25600]: " end
    end="${end:-25600}"

    cat >/usr/local/bin/mc-ipv6-range-proxy.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
START_PORT=${start}
END_PORT=${end}
LISTEN_IPV6="${internal}"
BACKEND_IPV4="${backend}"
PIDS=()
cleanup() {
    for P in "\${PIDS[@]:-}"; do kill "\$P" 2>/dev/null || true; done
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
    systemctl enable --now mc-ipv6-range-proxy
    echo "✅ Proxy: [$internal]:$start-$end -> $backend:same-port"
}

set_node_public_ipv6() {
    mkdir -p /etc/pterodactyl
    local current="" v6
    [[ -f /etc/pterodactyl/public-ipv6 ]] && current="$(cat /etc/pterodactyl/public-ipv6)"
    read -rp "Public IPv6 [${current}]: " v6
    v6="${v6:-$current}"
    [[ -n "$v6" ]] || { echo "❌ Public IPv6 不可空白"; return 1; }
    printf '%s\n' "$v6" >/etc/pterodactyl/public-ipv6
    chmod 600 /etc/pterodactyl/public-ipv6
    echo "✅ 已保存：$v6"
}

find_core_blade() {
    for f in \
        "$PTERO_DIR/resources/views/templates/base/core.blade.php" \
        "$PTERO_DIR/resources/views/layouts/app.blade.php"
    do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

install_panel_runtime() {
    local panel_dir="/var/www/pterodactyl"
    local blueprint_url="https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/publicaddress.blueprint"
    local tmp="/var/tmp/publicaddress.blueprint"

    if [[ ! -d "$panel_dir" ]]; then
        echo "❌ 找不到 $panel_dir"
        echo "   這個功能要在 Panel 主機執行。"
        return 1
    fi

    if ! command -v blueprint >/dev/null 2>&1; then
        echo "❌ 找不到 blueprint 指令，請先安裝 Blueprint Framework。"
        return 1
    fi

    echo "⬇️ 下載最新版 Public Address Blueprint..."
    rm -f "$tmp"

    curl -fL "${blueprint_url}?nocache=$(date +%s%N)" -o "$tmp" || {
        echo "❌ Public Address Blueprint 下載失敗"
        echo "   $blueprint_url"
        return 1
    }

    [[ -s "$tmp" ]] || {
        echo "❌ publicaddress.blueprint 是空檔案"
        return 1
    }

    if command -v unzip >/dev/null 2>&1; then
        unzip -t "$tmp" >/dev/null 2>&1 || {
            echo "❌ publicaddress.blueprint 不是有效的 Blueprint/ZIP"
            return 1
        }
    fi

    cd "$panel_dir"

    echo "📦 安裝/更新 Public Address Blueprint..."

    if blueprint -list 2>/dev/null | grep -qi 'publicaddress'; then
        set +e
        blueprint -update "$tmp"
        local rc=$?
        set -e

        if [[ "$rc" -ne 0 ]]; then
            echo "ℹ️ update 不可用，改用移除 Extension 程式碼後重新安裝..."
            blueprint -remove publicaddress >/dev/null 2>&1 || true
            blueprint -install "$tmp"
        fi
    else
        blueprint -install "$tmp"
    fi

    mkdir -p "$panel_dir/storage/app/publicaddress"
    [[ -f "$panel_dir/storage/app/publicaddress/node-ips.json" ]] || printf '{}\n' > "$panel_dir/storage/app/publicaddress/node-ips.json"

    chown -R www-data:www-data "$panel_dir/storage/app/publicaddress" 2>/dev/null || true
    chmod 775 "$panel_dir/storage/app/publicaddress" 2>/dev/null || true
    chmod 664 "$panel_dir/storage/app/publicaddress/node-ips.json" 2>/dev/null || true

    php artisan optimize:clear >/dev/null 2>&1 || true

    echo
    echo "✅ Public Address Blueprint 已安裝/更新"
    echo "   Admin：/admin/extensions/publicaddress"
    echo "   127.0.0.1:PORT → [Public IPv6]:PORT（只改顯示）"
}

manage_mapping() {
    [[ -f "$PTERO_DIR/artisan" ]] || { echo "❌ 請在 Panel 主機執行"; return 1; }
    mkdir -p "$(dirname "$MAP_FILE")"
    [[ -f "$MAP_FILE" ]] || echo '{}' > "$MAP_FILE"

    echo "目前設定："
    cat "$MAP_FILE" 2>/dev/null || true
    echo

    local node ipv6
    read -rp "Node 名稱（例 node1）: " node
    read -rp "這台 Node 的 Public IPv6: " ipv6
    [[ -n "$node" && -n "$ipv6" ]] || { echo "❌ 不可空白"; return 1; }

    php -r '
        $p=$argv[1]; $node=$argv[2]; $ip=$argv[3];
        $d=is_file($p)?json_decode(file_get_contents($p),true):[];
        if(!is_array($d))$d=[];
        $d[$node]=$ip;
        file_put_contents($p,json_encode($d,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES).PHP_EOL);
    ' "$MAP_FILE" "$node" "$ipv6"

    chown www-data:www-data "$MAP_FILE"
    chmod 664 "$MAP_FILE"
    echo "✅ $node → $ipv6"
}

remove_mapping() {
    [[ -f "$MAP_FILE" ]] || { echo "目前沒有 mapping"; return; }
    cat "$MAP_FILE"
    local node
    read -rp "要刪除的 Node 名稱: " node
    php -r '
        $p=$argv[1]; $node=$argv[2];
        $d=is_file($p)?json_decode(file_get_contents($p),true):[];
        if(!is_array($d))$d=[];
        unset($d[$node]);
        file_put_contents($p,json_encode($d,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES).PHP_EOL);
    ' "$MAP_FILE" "$node"
    echo "✅ 已刪除 $node"
}


# ------------------------------------------------------------
# Direct actions (for ptero-tool)
# ------------------------------------------------------------
case "${1:-}" in
    install-public-address)
        install_panel_runtime
        exit $?
        ;;
    mapping)
        manage_mapping
        exit $?
        ;;
    proxy)
        setup_proxy
        exit $?
        ;;
    node-public-ipv6)
        set_node_public_ipv6
        exit $?
        ;;
esac

while true; do
    clear
    echo "============================================================"
    echo " Network / Public Address Manager v21"
    echo "============================================================"
    echo " 1) 設定/重建 Minecraft IPv6 Proxy 25565-25600"
    echo " 2) 設定這台 Node 的 Public IPv6"
    echo " 3) Panel：新增/修改 Node -> Public IPv6"
    echo " 4) Panel：安裝/更新 127.0.0.1 -> Public IPv6 顯示功能"
    echo " 5) Panel：查看 Public IPv6 對應表"
    echo " 6) Panel：刪除某個 Node 對應"
    echo " 7) 查看 Proxy 狀態"
    echo " 0) 離開"
    read -rp "請選擇: " c

    case "$c" in
        1) setup_proxy; pause ;;
        2) set_node_public_ipv6; pause ;;
        3) manage_mapping; pause ;;
        4) install_panel_runtime; pause ;;
        5) cat "$MAP_FILE" 2>/dev/null || echo "尚未設定"; pause ;;
        6) remove_mapping; pause ;;
        7) systemctl --no-pager --full status mc-ipv6-range-proxy 2>/dev/null || true; pause ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
