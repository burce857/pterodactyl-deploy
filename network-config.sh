#!/usr/bin/env bash
set -Eeuo pipefail

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
    [[ -f "$PTERO_DIR/artisan" ]] || { echo "❌ 這台不是 Panel 主機"; return 1; }

    mkdir -p "$(dirname "$MAP_FILE")"
    [[ -f "$MAP_FILE" ]] || echo '{}' > "$MAP_FILE"
    chown -R www-data:www-data "$(dirname "$MAP_FILE")"

    cat >"$PARTIAL" <<'BLADE'
@php
    $pteroToolPublicMapPath = storage_path('app/publicaddress/node-ips.json');
    $pteroToolPublicMap = [];
    if (is_file($pteroToolPublicMapPath)) {
        $decoded = json_decode((string) file_get_contents($pteroToolPublicMapPath), true);
        if (is_array($decoded)) $pteroToolPublicMap = $decoded;
    }
@endphp
<script>
(() => {
    const mapping = @json($pteroToolPublicMap);
    let currentPublicAddress = null;
    let lastPath = location.pathname;

    const serverId = () => {
        const m = location.pathname.match(/^\/server\/([^/]+)/);
        return m ? m[1] : null;
    };

    const replaceAddress = () => {
        if (!currentPublicAddress) return;

        document.querySelectorAll('body *').forEach((el) => {
            if (el.children.length !== 0) return;
            const t = (el.textContent || '').trim();

            let m = t.match(/^127\.0\.0\.1:(\d+)$/);
            if (m) {
                const shown = `[${currentPublicAddress}]:${m[1]}`;
                el.textContent = shown;
                el.setAttribute('data-public-address', shown);
                return;
            }

            if (t === '127.0.0.1') {
                el.textContent = currentPublicAddress;
                el.setAttribute('data-public-address-ip', currentPublicAddress);
            }
        });
    };

    const load = async () => {
        const id = serverId();
        currentPublicAddress = null;
        if (!id) return;

        try {
            const r = await fetch(`/api/client/servers/${encodeURIComponent(id)}`, {
                credentials: 'same-origin',
                headers: { Accept: 'application/json' },
            });
            if (!r.ok) return;

            const j = await r.json();
            const node = j?.attributes?.node;
            if (!node || !mapping[node]) return;

            currentPublicAddress = mapping[node];
            for (let i = 0; i < 8; i++) setTimeout(replaceAddress, i * 250);
        } catch (_) {}
    };

    const routeChanged = () => {
        if (location.pathname === lastPath) return;
        lastPath = location.pathname;
        setTimeout(load, 50);
    };

    const push = history.pushState;
    history.pushState = function (...args) {
        const r = push.apply(this, args);
        routeChanged();
        return r;
    };

    const replace = history.replaceState;
    history.replaceState = function (...args) {
        const r = replace.apply(this, args);
        routeChanged();
        return r;
    };

    window.addEventListener('popstate', routeChanged);

    new MutationObserver(() => {
        routeChanged();
        replaceAddress();
    }).observe(document.documentElement, { childList: true, subtree: true });

    document.addEventListener('click', (e) => {
        const target = e.target instanceof Element ? e.target : null;
        if (!target) return;
        const tagged = target.closest('[data-public-address]') ||
            target.querySelector?.('[data-public-address]') ||
            target.closest('div')?.querySelector?.('[data-public-address]');
        if (!tagged) return;

        const value = tagged.getAttribute('data-public-address');
        if (!value) return;

        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        navigator.clipboard?.writeText(value).catch(() => {});
    }, true);

    load();
})();
</script>
BLADE

    local blade
    blade="$(find_core_blade)" || { echo "❌ 找不到 Panel 主模板"; return 1; }

    if ! grep -q "@include('ptero-tool-public-address')" "$blade"; then
        cp -a "$blade" "${blade}.bak.$(date +%Y%m%d-%H%M%S)"
        sed -i "/<\/body>/i\\    @include('ptero-tool-public-address')" "$blade"
    fi

    cd "$PTERO_DIR"
    php artisan view:clear || true
    php artisan optimize:clear || true
    chown www-data:www-data "$PARTIAL"
    echo "✅ 已安裝 127.0.0.1 -> Public IPv6 顯示功能"
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

while true; do
    clear
    echo "============================================================"
    echo " Network / Public Address Manager v13"
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
