#!/usr/bin/env bash
set -Eeuo pipefail
# ============================================================
# Pterodactyl Deploy Manager v28
# GitHub: https://github.com/burce857/pterodactyl-deploy
# ============================================================

VERSION="28"
REPO_RAW="https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main"
CACHE_DIR="/var/tmp/pterodactyl-deploy"
LOG="/var/log/pterodactyl-manager.log"

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "❌ 需要 root 權限。"
    exit 1
fi

mkdir -p "$CACHE_DIR"
touch "$LOG"
chmod 600 "$LOG"

echo "Pterodactyl Deploy Manager v${VERSION}"
echo "Script: ${BASH_SOURCE[0]}"

info(){ echo -e "\n🔹 $*"; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️ $*"; }
need_cmd(){ command -v "$1" >/dev/null 2>&1; }

bootstrap_tools() {
    if ! need_cmd curl; then
        apt-get update
        apt-get install -y curl ca-certificates
    fi
}

DOWNLOADED_PATH=""
download_script() {
    local name="$1" dest="$CACHE_DIR/$1"
    DOWNLOADED_PATH=""
    bootstrap_tools
    mkdir -p "$CACHE_DIR"
    chmod 755 "$CACHE_DIR"
    echo "⬇️ 下載最新版 $name ..."
    rm -f "$dest"
    if ! curl -fL --retry 3 --retry-delay 2 \
        "${REPO_RAW}/${name}?nocache=$(date +%s)" -o "$dest"; then
        echo "❌ 無法下載 $name"
        rm -f "$dest"
        return 1
    fi
    [[ -s "$dest" ]] || { echo "❌ 下載結果不存在或是空檔案：$dest"; rm -f "$dest"; return 1; }
    if head -c 256 "$dest" | grep -qiE '<!doctype html|<html'; then
        echo "❌ GitHub 回傳的是 HTML，不是 shell script：$dest"
        rm -f "$dest"
        return 1
    fi
    chmod +x "$dest"
    if ! bash -n "$dest"; then
        echo "❌ $name 語法檢查失敗，拒絕執行"
        rm -f "$dest"
        return 1
    fi
    DOWNLOADED_PATH="$dest"
    echo "✅ 已下載：$DOWNLOADED_PATH"
}

run_component() {
    local name="$1"
    download_script "$name" || return 1
    [[ -n "$DOWNLOADED_PATH" && -f "$DOWNLOADED_PATH" ]] || return 1
    echo
    echo "🚀 執行 $name"
    echo "📁 $DOWNLOADED_PATH"
    echo "────────────────────────────────────────"
    /usr/bin/env bash "$DOWNLOADED_PATH"
}

run_network_action() {
    local action="$1"
    download_script "network-config.sh" || return 1
    /usr/bin/env bash "$DOWNLOADED_PATH" "$action"
}

show_status() {
    echo
    echo "===== 系統 ====="
    hostnamectl 2>/dev/null | head -8 || true
    echo
    ip -4 addr 2>/dev/null || true
    echo
    df -h / || true
    free -h || true
    echo
    echo "===== Panel ====="
    if [[ -f /var/www/pterodactyl/artisan ]]; then
        echo "✅ Panel detected"
        (cd /var/www/pterodactyl && php artisan p:info 2>/dev/null) || true
        for s in mariadb redis-server php8.3-fpm cron pteroq caddy; do
            printf "%-28s " "$s"
            systemctl is-active "$s" 2>/dev/null || true
        done
    else
        echo "— Panel not detected"
    fi
    echo
    echo "===== Node ====="
    if [[ -x /usr/local/bin/wings ]]; then
        echo "✅ Wings detected"
        /usr/local/bin/wings --version 2>/dev/null || true
        for s in wings docker mc-ipv6-range-proxy ptero-ipv4-gateway wg-quick@wg0; do
            printf "%-28s " "$s"
            systemctl is-active "$s" 2>/dev/null || true
        done
    else
        echo "— Wings not detected"
    fi
}

update_manager() {
    bootstrap_tools
    local tmp="$CACHE_DIR/ptero-tool.sh.new"
    curl -fL --retry 3 --retry-delay 2 \
        "${REPO_RAW}/ptero-tool.sh?t=$(date +%s)" -o "$tmp"
    bash -n "$tmp"
    chmod +x "$tmp"
    if [[ -f "$0" && -w "$0" ]]; then
        cp "$tmp" "$0"
        chmod +x "$0"
        ok "主選單已更新：$0"
    else
        cp "$tmp" /usr/local/bin/ptero-tool
        chmod +x /usr/local/bin/ptero-tool
        ok "已更新到 /usr/local/bin/ptero-tool"
    fi
}

install_manager_command() {
    bootstrap_tools
    curl -fL --retry 3 --retry-delay 2 \
        "${REPO_RAW}/ptero-tool.sh?t=$(date +%s)" -o /usr/local/bin/ptero-tool
    chmod +x /usr/local/bin/ptero-tool
    ok "之後直接輸入 ptero-tool 即可開啟選單"
}

while true; do
    clear
    echo "============================================================"
    echo " Pterodactyl Deploy Manager v${VERSION}"
    echo "============================================================"
    echo
    echo " 1) 安裝 / 補完 Panel"
    echo "    Pterodactyl + Caddy + DB + Redis + Blueprint + Nebula"
    echo
    echo " 2) 安裝 / 補完 Node"
    echo "    Docker + Wings + Minecraft IPv6 Proxy"
    echo
    echo " 3) 開啟維護 / 修復 / 更新工具"
    echo " 4) 網路 / Public IPv6 / IPv4 Gateway / WireGuard"
    echo " 5) 查看目前 Panel / Node / Gateway 狀態"
    echo
    echo " 6) Panel：安裝/更新 Public Address Blueprint"
    echo " 7) IPv4 Gateway：設定 Public IPv4"
    echo " 8) IPv4 Gateway：安裝/修復 nftables"
    echo " 9) IPv4 Gateway：新增 Port Mapping"
    echo "10) IPv4 Gateway：查看 Mapping / 狀態"
    echo
    echo "11) 安裝 ptero-tool 全域指令"
    echo "12) 更新這個主選單"
    echo "13) 清除下載快取"
    echo
    echo " 0) 離開"
    echo
    read -rp "請選擇: " choice
    case "$choice" in
        1) run_component "panel-deploy.sh"; read -rp "按 Enter 回主選單..." _ ;;
        2) run_component "node-deploy.sh"; read -rp "按 Enter 回主選單..." _ ;;
        3) run_component "maintenance.sh" ;;
        4) run_component "network-config.sh" ;;
        5) show_status; read -rp "按 Enter 回主選單..." _ ;;
        6) run_network_action "install-public-address"; read -rp "按 Enter 回主選單..." _ ;;
        7) run_network_action "ipv4-set-public"; read -rp "按 Enter 回主選單..." _ ;;
        8) run_network_action "ipv4-install"; read -rp "按 Enter 回主選單..." _ ;;
        9) run_network_action "ipv4-add"; read -rp "按 Enter 回主選單..." _ ;;
        10) run_network_action "ipv4-status"; read -rp "按 Enter 回主選單..." _ ;;
        11) install_manager_command; read -rp "按 Enter 回主選單..." _ ;;
        12) update_manager; read -rp "按 Enter 回主選單..." _ ;;
        13) rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"; chmod 755 "$CACHE_DIR"; ok "快取已清除"; sleep 1 ;;
        0) exit 0 ;;
        *) warn "無效選項"; sleep 1 ;;
    esac
done
