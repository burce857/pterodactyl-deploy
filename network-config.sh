#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="28"
PTERO_DIR="/var/www/pterodactyl"
MAP_FILE="$PTERO_DIR/storage/app/publicaddress/node-ips.json"

IPV4_DIR="/etc/pterodactyl/ipv4-gateway"
IPV4_MAP_FILE="$IPV4_DIR/mappings.tsv"
IPV4_PUBLIC_FILE="$IPV4_DIR/public-ipv4"
IPV4_APPLY="/usr/local/sbin/ptero-ipv4-gateway-apply"
IPV4_SERVICE="/etc/systemd/system/ptero-ipv4-gateway.service"

WG_DIR="/etc/wireguard"
WG_IF="wg0"
WG_CONF="$WG_DIR/$WG_IF.conf"
WG_CLIENT_DIR="$IPV4_DIR/wireguard-clients"

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "❌ 需要 root 權限。"
    exit 1
fi

pause(){ read -rp "按 Enter 繼續..." _; }
info(){ echo "🔹 $*"; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️ $*"; }
err(){ echo "❌ $*" >&2; }

is_ipv4() {
    local ip="$1" IFS=. a b c d
    read -r a b c d <<<"$ip" || return 1
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

is_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

ensure_ipv4_dirs() {
    mkdir -p "$IPV4_DIR" "$WG_CLIENT_DIR"
    touch "$IPV4_MAP_FILE"
    chmod 700 "$IPV4_DIR" "$WG_CLIENT_DIR" 2>/dev/null || true
    chmod 600 "$IPV4_MAP_FILE" 2>/dev/null || true
}

detect_backend() {
    local ip
    ip="$(ip -4 -o addr show pterodactyl0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
    echo "${ip:-172.18.0.1}"
}

detect_internal_v4() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

detect_internal_v6() {
    ip -6 -o addr show dev eth0 scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true
}

detect_public_v4() {
    local current=""
    [[ -f "$IPV4_PUBLIC_FILE" ]] && current="$(tr -d '[:space:]' < "$IPV4_PUBLIC_FILE")"
    if is_ipv4 "$current" 2>/dev/null; then
        echo "$current"
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        current="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null | tr -d '[:space:]' || true)"
        if is_ipv4 "$current" 2>/dev/null; then
            echo "$current"
            return 0
        fi
    fi
    return 1
}

# ============================================================
# Existing IPv6 proxy functions
# ============================================================
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
    [[ -n "$internal" ]] || { err "IPv6 不可空白"; return 1; }

    read -rp "Backend IPv4 [$backend]: " input
    backend="${input:-$backend}"
    read -rp "起始 Port [25565]: " start
    start="${start:-25565}"
    read -rp "結束 Port [25600]: " end
    end="${end:-25600}"

    cat >/usr/local/bin/mc-ipv6-range-proxy.sh <<EOF2
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
    socat TCP6-LISTEN:\${PORT},bind="[\${LISTEN_IPV6}]",ipv6only=1,reuseaddr,fork \\
          TCP4:\${BACKEND_IPV4}:\${PORT} &
    PIDS+=("\$!")
done
wait
EOF2
    chmod +x /usr/local/bin/mc-ipv6-range-proxy.sh

    cat >/etc/systemd/system/mc-ipv6-range-proxy.service <<'EOF2'
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
EOF2

    systemctl daemon-reload
    systemctl enable --now mc-ipv6-range-proxy
    ok "Proxy: [$internal]:$start-$end -> $backend:same-port"
}

set_node_public_ipv6() {
    mkdir -p /etc/pterodactyl
    local current="" v6
    [[ -f /etc/pterodactyl/public-ipv6 ]] && current="$(cat /etc/pterodactyl/public-ipv6)"
    read -rp "Public IPv6 [${current}]: " v6
    v6="${v6:-$current}"
    [[ -n "$v6" ]] || { err "Public IPv6 不可空白"; return 1; }
    printf '%s\n' "$v6" >/etc/pterodactyl/public-ipv6
    chmod 600 /etc/pterodactyl/public-ipv6
    ok "已保存：$v6"
}

install_panel_runtime() {
    local panel_dir="/var/www/pterodactyl"
    local blueprint_url="https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/publicaddress.blueprint"
    local tmp="/var/tmp/publicaddress.blueprint"
    local local_bp="$panel_dir/publicaddress.blueprint"

    if [[ ! -d "$panel_dir" || ! -f "$panel_dir/artisan" ]]; then
        err "找不到有效的 Pterodactyl Panel：$panel_dir"
        echo "   這個功能必須在 Panel 主機執行。"
        return 1
    fi
    if ! command -v blueprint >/dev/null 2>&1; then
        err "找不到 blueprint 指令，請先安裝 Blueprint Framework。"
        return 1
    fi

    echo "⬇️ 下載最新版 Public Address Blueprint..."
    rm -f "$tmp" "$local_bp"
    curl -fL --retry 3 --retry-delay 2 \
        "${blueprint_url}?nocache=$(date +%s%N)" -o "$tmp" || {
        err "Public Address Blueprint 下載失敗"
        return 1
    }
    [[ -s "$tmp" ]] || { err "publicaddress.blueprint 是空檔案"; return 1; }

    if command -v unzip >/dev/null 2>&1; then
        unzip -t "$tmp" >/dev/null 2>&1 || {
            err "publicaddress.blueprint 不是有效的 Blueprint/ZIP"
            return 1
        }
    fi

    cp -f "$tmp" "$local_bp"
    chown root:root "$local_bp" 2>/dev/null || true
    chmod 644 "$local_bp"
    cd "$panel_dir"

    echo "📦 安裝/更新 Public Address Blueprint..."
    mkdir -p "$panel_dir/storage/app/publicaddress"
    [[ -f "$panel_dir/storage/app/publicaddress/node-ips.json" ]] || printf '{}\n' > "$panel_dir/storage/app/publicaddress/node-ips.json"

    if blueprint -list 2>/dev/null | grep -qiE '(^|[[:space:]])publicaddress([[:space:]]|$)|Public Address'; then
        echo "♻️ 偵測到 Public Address 已安裝，先移除舊 Extension 程式碼..."
        blueprint -remove publicaddress >/dev/null 2>&1 || true
    fi

    if ! blueprint -install "publicaddress.blueprint"; then
        err "Public Address Blueprint 安裝失敗"
        echo "   檔案已保留在：$local_bp"
        return 1
    fi

    chown -R www-data:www-data "$panel_dir/storage/app/publicaddress" 2>/dev/null || true
    chmod 775 "$panel_dir/storage/app/publicaddress" 2>/dev/null || true
    chmod 664 "$panel_dir/storage/app/publicaddress/node-ips.json" 2>/dev/null || true
    php artisan optimize:clear >/dev/null 2>&1 || true

    echo
    ok "Public Address Blueprint 已安裝/更新"
    echo "   Admin：/admin/extensions/publicaddress"
    echo "   Mapping：$panel_dir/storage/app/publicaddress/node-ips.json"
    echo "   注意：此 Blueprint 仍負責原本的 Public IPv6 顯示。"
}

manage_mapping() {
    [[ -f "$PTERO_DIR/artisan" ]] || { err "請在 Panel 主機執行"; return 1; }
    mkdir -p "$(dirname "$MAP_FILE")"
    [[ -f "$MAP_FILE" ]] || echo '{}' > "$MAP_FILE"
    echo "目前設定："
    cat "$MAP_FILE" 2>/dev/null || true
    echo

    local node ipv6
    read -rp "Node 名稱（例 node1）: " node
    read -rp "這台 Node 的 Public IPv6: " ipv6
    [[ -n "$node" && -n "$ipv6" ]] || { err "不可空白"; return 1; }

    php -r '
        $p=$argv[1]; $node=$argv[2]; $ip=$argv[3];
        $d=is_file($p)?json_decode(file_get_contents($p),true):[];
        if(!is_array($d))$d=[];
        $d[$node]=$ip;
        file_put_contents($p,json_encode($d,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES).PHP_EOL);
    ' "$MAP_FILE" "$node" "$ipv6"

    chown www-data:www-data "$MAP_FILE"
    chmod 664 "$MAP_FILE"
    ok "$node → $ipv6"
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
    ok "已刪除 $node"
}

# ============================================================
# IPv4 Gateway / Port sharing
# ============================================================
set_public_ipv4() {
    ensure_ipv4_dirs
    local detected current input
    detected="$(detect_public_v4 2>/dev/null || true)"
    current="$(cat "$IPV4_PUBLIC_FILE" 2>/dev/null || true)"
    echo "自動偵測 Public IPv4: ${detected:-找不到}"
    read -rp "Public IPv4 [${current:-$detected}]: " input
    input="${input:-${current:-$detected}}"
    is_ipv4 "$input" || { err "IPv4 格式不正確"; return 1; }
    printf '%s\n' "$input" > "$IPV4_PUBLIC_FILE"
    chmod 600 "$IPV4_PUBLIC_FILE"
    ok "Public IPv4 已設定為 $input"
    echo "提示：你的 VPS 即使網卡是 10.x.x.x，只要供應商做 1:1 NAT，這裡仍填外部 Public IPv4。"
}

install_ipv4_gateway_engine() {
    ensure_ipv4_dirs
    command -v nft >/dev/null 2>&1 || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y nftables iproute2
    }

    cat > "$IPV4_APPLY" <<'EOF2'
#!/usr/bin/env bash
set -Eeuo pipefail
MAP_FILE="/etc/pterodactyl/ipv4-gateway/mappings.tsv"

command -v nft >/dev/null 2>&1 || { echo "nft not installed" >&2; exit 1; }

nft list table ip ptero_ipv4_gateway >/dev/null 2>&1 && nft delete table ip ptero_ipv4_gateway || true
nft list table inet ptero_ipv4_forward >/dev/null 2>&1 && nft delete table inet ptero_ipv4_forward || true

nft add table ip ptero_ipv4_gateway
nft 'add chain ip ptero_ipv4_gateway prerouting { type nat hook prerouting priority dstnat; policy accept; }'
nft 'add chain ip ptero_ipv4_gateway postrouting { type nat hook postrouting priority srcnat; policy accept; }'

nft add table inet ptero_ipv4_forward
nft 'add chain inet ptero_ipv4_forward forward { type filter hook forward priority -5; policy accept; }'

[[ -f "$MAP_FILE" ]] || exit 0

while IFS=$'\t' read -r PUB_START PUB_END TARGET TARGET_START PROTO LABEL; do
    [[ -n "${PUB_START:-}" ]] || continue
    [[ "$PUB_START" == \#* ]] && continue

    PROTO="${PROTO:-tcp}"
    TARGET_START="${TARGET_START:-$PUB_START}"
    PUB_END="${PUB_END:-$PUB_START}"

    # SNAT only traffic forwarded to this mapped target, so unrelated routed traffic is untouched.
    nft add rule ip ptero_ipv4_gateway postrouting ip daddr "$TARGET" masquerade

    for ((P=PUB_START; P<=PUB_END; P++)); do
        TP=$((TARGET_START + P - PUB_START))
        case "$PROTO" in
            tcp)
                nft add rule ip ptero_ipv4_gateway prerouting tcp dport "$P" dnat to "$TARGET:$TP"
                nft add rule inet ptero_ipv4_forward forward ip daddr "$TARGET" tcp dport "$TP" ct state new,established,related accept
                ;;
            udp)
                nft add rule ip ptero_ipv4_gateway prerouting udp dport "$P" dnat to "$TARGET:$TP"
                nft add rule inet ptero_ipv4_forward forward ip daddr "$TARGET" udp dport "$TP" ct state new,established,related accept
                ;;
            both)
                nft add rule ip ptero_ipv4_gateway prerouting tcp dport "$P" dnat to "$TARGET:$TP"
                nft add rule ip ptero_ipv4_gateway prerouting udp dport "$P" dnat to "$TARGET:$TP"
                nft add rule inet ptero_ipv4_forward forward ip daddr "$TARGET" tcp dport "$TP" ct state new,established,related accept
                nft add rule inet ptero_ipv4_forward forward ip daddr "$TARGET" udp dport "$TP" ct state new,established,related accept
                ;;
            *) echo "Invalid protocol in mapping: $PROTO" >&2; exit 1 ;;
        esac
    done
done < "$MAP_FILE"
EOF2
    chmod 750 "$IPV4_APPLY"

    cat > /etc/sysctl.d/99-ptero-ipv4-gateway.conf <<'EOF2'
net.ipv4.ip_forward=1
EOF2
    sysctl -q -w net.ipv4.ip_forward=1

    cat > "$IPV4_SERVICE" <<EOF2
[Unit]
Description=Pterodactyl IPv4 Gateway Port Forwarding
After=network-online.target docker.service wg-quick@${WG_IF}.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${IPV4_APPLY}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

    systemctl daemon-reload
    systemctl enable ptero-ipv4-gateway.service
    "$IPV4_APPLY"
    ok "IPv4 Gateway engine 已安裝並套用。"
}

mapping_conflicts() {
    local ns="$1" ne="$2" proto="$3" s e _target _tstart p _label
    [[ -s "$IPV4_MAP_FILE" ]] || return 1
    while IFS=$'\t' read -r s e _target _tstart p _label; do
        [[ -n "${s:-}" && "$s" != \#* ]] || continue
        e="${e:-$s}"
        p="${p:-tcp}"
        if (( ns <= e && ne >= s )); then
            if [[ "$proto" == "both" || "$p" == "both" || "$proto" == "$p" ]]; then
                return 0
            fi
        fi
    done < "$IPV4_MAP_FILE"
    return 1
}

add_ipv4_mapping() {
    ensure_ipv4_dirs
    local pub_start pub_end target target_start proto label count target_end

    read -rp "Public 起始 Port [25565]: " pub_start
    pub_start="${pub_start:-25565}"
    read -rp "Public 結束 Port [$pub_start]: " pub_end
    pub_end="${pub_end:-$pub_start}"
    is_port "$pub_start" && is_port "$pub_end" && (( pub_end >= pub_start )) || {
        err "Port 範圍不正確"; return 1;
    }

    read -rp "目標內網/WireGuard IPv4（例 10.50.0.2）: " target
    is_ipv4 "$target" || { err "目標 IPv4 格式不正確"; return 1; }

    read -rp "目標起始 Port [$pub_start]: " target_start
    target_start="${target_start:-$pub_start}"
    is_port "$target_start" || { err "目標 Port 不正確"; return 1; }

    count=$((pub_end - pub_start))
    target_end=$((target_start + count))
    (( target_end <= 65535 )) || { err "目標 Port 範圍超過 65535"; return 1; }

    read -rp "協定 tcp / udp / both [tcp]: " proto
    proto="${proto:-tcp}"
    [[ "$proto" =~ ^(tcp|udp|both)$ ]] || { err "協定只能是 tcp、udp 或 both"; return 1; }

    if mapping_conflicts "$pub_start" "$pub_end" "$proto"; then
        err "Public Port 範圍與現有 mapping 衝突。"
        return 1
    fi

    if (( pub_start <= 22 && pub_end >= 22 )); then
        warn "範圍包含 SSH 22。DNAT 後可能讓你無法從 Public IPv4 SSH 到 Gateway。"
        read -rp "仍要繼續？ [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return 1
    fi

    read -rp "名稱/備註 [node]: " label
    label="${label:-node}"
    label="${label//$'\t'/ }"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pub_start" "$pub_end" "$target" "$target_start" "$proto" "$label" >> "$IPV4_MAP_FILE"
    chmod 600 "$IPV4_MAP_FILE"

    install_ipv4_gateway_engine >/dev/null
    ok "已新增：:$pub_start-$pub_end → $target:$target_start-$target_end ($proto) [$label]"
}

list_ipv4_mappings() {
    ensure_ipv4_dirs
    local public
    public="$(detect_public_v4 2>/dev/null || echo PUBLIC_IP)"
    echo "Public IPv4: $public"
    echo "--------------------------------------------------------------------------"
    printf '%-4s %-20s %-22s %-7s %s\n' "ID" "Public" "Target" "Proto" "Label"
    echo "--------------------------------------------------------------------------"
    local n=0 s e target ts proto label te
    while IFS=$'\t' read -r s e target ts proto label; do
        [[ -n "${s:-}" && "$s" != \#* ]] || continue
        n=$((n+1)); e="${e:-$s}"; ts="${ts:-$s}"; proto="${proto:-tcp}"
        te=$((ts + e - s))
        printf '%-4s %-20s %-22s %-7s %s\n' "$n" "$public:$s-$e" "$target:$ts-$te" "$proto" "$label"
    done < "$IPV4_MAP_FILE"
    (( n > 0 )) || echo "目前沒有 IPv4 mapping。"
}

remove_ipv4_mapping() {
    ensure_ipv4_dirs
    list_ipv4_mappings
    local id tmp n=0 line
    read -rp "要刪除的 ID: " id
    [[ "$id" =~ ^[0-9]+$ ]] || { err "ID 不正確"; return 1; }
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "$line" && "$line" != \#* ]]; then
            n=$((n+1))
            [[ "$n" -eq "$id" ]] && continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$IPV4_MAP_FILE"
    if (( id < 1 || id > n )); then
        rm -f "$tmp"; err "找不到這個 ID"; return 1
    fi
    mv "$tmp" "$IPV4_MAP_FILE"
    chmod 600 "$IPV4_MAP_FILE"
    [[ -x "$IPV4_APPLY" ]] && "$IPV4_APPLY"
    ok "已刪除 mapping #$id"
}

show_ipv4_gateway_status() {
    echo "===== IPv4 Gateway ====="
    echo "Internal IPv4 : $(detect_internal_v4 2>/dev/null || echo unknown)"
    echo "Public IPv4   : $(detect_public_v4 2>/dev/null || echo 未設定)"
    echo "IP forwarding : $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
    echo
    list_ipv4_mappings
    echo
    echo "===== Service ====="
    systemctl --no-pager --full status ptero-ipv4-gateway.service 2>/dev/null || true
    echo
    echo "===== nftables ====="
    nft list table ip ptero_ipv4_gateway 2>/dev/null || echo "尚未建立 nftables IPv4 Gateway table"
}

# ============================================================
# WireGuard private network for remote Pterodactyl nodes
# ============================================================
setup_wireguard_gateway() {
    ensure_ipv4_dirs
    command -v wg >/dev/null 2>&1 || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-tools qrencode
    }

    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    local addr port public private pubkey
    read -rp "Gateway WireGuard IPv4/CIDR [10.50.0.1/24]: " addr
    addr="${addr:-10.50.0.1/24}"
    read -rp "WireGuard UDP Port [51820]: " port
    port="${port:-51820}"
    is_port "$port" || { err "WireGuard Port 不正確"; return 1; }

    if [[ -f "$WG_CONF" ]]; then
        warn "$WG_CONF 已存在。"
        read -rp "覆蓋並重新建立？ [y/N]: " yn
        [[ "$yn" =~ ^[Yy]$ ]] || return 0
        cp -a "$WG_CONF" "$WG_CONF.bak.$(date +%s)"
    fi

    private="$(wg genkey)"
    pubkey="$(printf '%s' "$private" | wg pubkey)"
    public="$(detect_public_v4 2>/dev/null || true)"

    cat > "$WG_CONF" <<EOF2
[Interface]
Address = $addr
ListenPort = $port
PrivateKey = $private
SaveConfig = false
EOF2
    chmod 600 "$WG_CONF"

    systemctl enable --now "wg-quick@$WG_IF"
    sysctl -q -w net.ipv4.ip_forward=1

    ok "WireGuard Gateway 已建立"
    echo "Gateway Public Key: $pubkey"
    echo "Endpoint 建議: ${public:-PUBLIC_IPV4}:$port"
    echo "介面: $WG_IF  /  Address: $addr"
}

add_wireguard_node() {
    [[ -f "$WG_CONF" ]] || { err "請先建立 WireGuard Gateway"; return 1; }
    ensure_ipv4_dirs
    command -v wg >/dev/null 2>&1 || { err "找不到 wg"; return 1; }

    local name ip endpoint endpoint_in server_pub client_priv client_pub client_conf wg_port wg_network
    read -rp "Node 名稱（例 node-jp-1）: " name
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { err "名稱只能使用英文、數字、._-"; return 1; }
    read -rp "分配給 Node 的 WireGuard IPv4 [10.50.0.2]: " ip
    ip="${ip:-10.50.0.2}"
    is_ipv4 "$ip" || { err "IPv4 格式不正確"; return 1; }

    if grep -qE "AllowedIPs[[:space:]]*=[[:space:]]*$ip/32([[:space:]]|$)" "$WG_CONF"; then
        err "$ip 已存在於 $WG_CONF"
        return 1
    fi

    endpoint="$(detect_public_v4 2>/dev/null || true)"
    read -rp "Gateway Public IPv4 [${endpoint}]: " endpoint_in
    endpoint="${endpoint_in:-$endpoint}"
    is_ipv4 "$endpoint" || { err "Gateway Public IPv4 不正確"; return 1; }

    wg_port="$(awk -F'=' '/^[[:space:]]*ListenPort/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$WG_CONF")"
    wg_port="${wg_port:-51820}"
    server_pub="$(awk -F'=' '/^[[:space:]]*PrivateKey/{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$WG_CONF" | wg pubkey)"
    wg_network="$(ip -4 route show dev "$WG_IF" proto kernel scope link 2>/dev/null | awk 'NR==1{print $1}')"
    wg_network="${wg_network:-10.50.0.0/24}"
    client_priv="$(wg genkey)"
    client_pub="$(printf '%s' "$client_priv" | wg pubkey)"

    cat >> "$WG_CONF" <<EOF2

# $name
[Peer]
PublicKey = $client_pub
AllowedIPs = $ip/32
EOF2

    client_conf="$WG_CLIENT_DIR/$name.conf"
    cat > "$client_conf" <<EOF2
[Interface]
Address = $ip/32
PrivateKey = $client_priv

[Peer]
PublicKey = $server_pub
Endpoint = $endpoint:$wg_port
AllowedIPs = $wg_network
PersistentKeepalive = 25
EOF2
    chmod 600 "$client_conf"

    systemctl restart "wg-quick@$WG_IF"
    ok "WireGuard Node 已新增：$name = $ip"
    echo "Client config: $client_conf"
    echo
    cat "$client_conf"
    if command -v qrencode >/dev/null 2>&1; then
        echo
        echo "QR："
        qrencode -t ansiutf8 < "$client_conf" || true
    fi
}

list_wireguard() {
    echo "===== WireGuard ====="
    if [[ -f "$WG_CONF" ]]; then
        wg show "$WG_IF" 2>/dev/null || true
        echo
        echo "Client configs:"
        find "$WG_CLIENT_DIR" -maxdepth 1 -type f -name '*.conf' -printf '  %f\n' 2>/dev/null || true
    else
        echo "尚未設定 WireGuard Gateway"
    fi
}

# ------------------------------------------------------------
# Direct actions (for ptero-tool / automation)
# ------------------------------------------------------------
case "${1:-}" in
    install-public-address) install_panel_runtime; exit $? ;;
    mapping) manage_mapping; exit $? ;;
    proxy) setup_proxy; exit $? ;;
    node-public-ipv6) set_node_public_ipv6; exit $? ;;
    ipv4-set-public) set_public_ipv4; exit $? ;;
    ipv4-install) install_ipv4_gateway_engine; exit $? ;;
    ipv4-add) add_ipv4_mapping; exit $? ;;
    ipv4-list) list_ipv4_mappings; exit $? ;;
    ipv4-remove) remove_ipv4_mapping; exit $? ;;
    ipv4-status) show_ipv4_gateway_status; exit $? ;;
    wireguard-setup) setup_wireguard_gateway; exit $? ;;
    wireguard-add-node) add_wireguard_node; exit $? ;;
    wireguard-status) list_wireguard; exit $? ;;
esac

while true; do
    clear
    echo "============================================================"
    echo " Network / Public Address Manager v${SCRIPT_VERSION}"
    echo "============================================================"
    echo " IPv6 / Panel"
    echo "  1) 設定/重建 Minecraft IPv6 Proxy 25565-25600"
    echo "  2) 設定這台 Node 的 Public IPv6"
    echo "  3) Panel：新增/修改 Node -> Public IPv6"
    echo "  4) Panel：安裝/更新 Public Address Blueprint"
    echo "  5) Panel：查看 Public IPv6 對應表"
    echo "  6) Panel：刪除某個 Node 對應"
    echo "  7) 查看 IPv6 Proxy 狀態"
    echo
    echo " IPv4 Gateway / Port Sharing"
    echo " 10) 設定 Public IPv4"
    echo " 11) 安裝/修復 IPv4 Gateway (nftables)"
    echo " 12) 新增 IPv4 Port Mapping"
    echo " 13) 查看 IPv4 Port Mapping"
    echo " 14) 刪除 IPv4 Port Mapping"
    echo " 15) 重新套用 IPv4 Gateway rules"
    echo " 16) 查看 IPv4 Gateway 狀態"
    echo
    echo " WireGuard 私網（跨 VPS / 跨機房 Node）"
    echo " 20) 建立 WireGuard Gateway"
    echo " 21) 新增 WireGuard Node 並產生 Client Config"
    echo " 22) 查看 WireGuard 狀態"
    echo
    echo "  0) 離開"
    read -rp "請選擇: " c
    case "$c" in
        1) setup_proxy; pause ;;
        2) set_node_public_ipv6; pause ;;
        3) manage_mapping; pause ;;
        4) install_panel_runtime; pause ;;
        5) cat "$MAP_FILE" 2>/dev/null || echo "尚未設定"; pause ;;
        6) remove_mapping; pause ;;
        7) systemctl --no-pager --full status mc-ipv6-range-proxy 2>/dev/null || true; pause ;;
        10) set_public_ipv4; pause ;;
        11) install_ipv4_gateway_engine; pause ;;
        12) add_ipv4_mapping; pause ;;
        13) list_ipv4_mappings; pause ;;
        14) remove_ipv4_mapping; pause ;;
        15) [[ -x "$IPV4_APPLY" ]] && "$IPV4_APPLY" || install_ipv4_gateway_engine; ok "已重新套用"; pause ;;
        16) show_ipv4_gateway_status; pause ;;
        20) setup_wireguard_gateway; pause ;;
        21) add_wireguard_node; pause ;;
        22) list_wireguard; pause ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
