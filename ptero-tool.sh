#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Deploy Manager v6
#
# 一支腳本入口：
# 先顯示選單 -> 選要做的事 -> 才下載對應的子腳本 -> 執行
#
# GitHub:
# https://github.com/burce857/pterodactyl-deploy
# ============================================================

VERSION="14"
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

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

bootstrap_tools() {
    if ! need_cmd curl; then
        apt-get update
        apt-get install -y curl ca-certificates
    fi
}

DOWNLOADED_PATH=""

download_script() {
    local name="$1"
    local dest="$CACHE_DIR/$name"

    DOWNLOADED_PATH=""

    bootstrap_tools
    mkdir -p "$CACHE_DIR"
    chmod 755 "$CACHE_DIR"

    echo "⬇️ 下載最新版 $name ..."
    rm -f "$dest"

    if ! curl -fL --retry 3 --retry-delay 2 \
        "${REPO_RAW}/${name}?nocache=$(date +%s)" \
        -o "$dest"; then
        echo "❌ 無法下載 $name"
        rm -f "$dest"
        return 1
    fi

    if [[ ! -f "$dest" || ! -s "$dest" ]]; then
        echo "❌ 下載結果不存在或是空檔案：$dest"
        rm -f "$dest"
        return 1
    fi

    # 防止 GitHub/Proxy 回傳 HTML 錯誤頁卻是 HTTP 200。
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

    if ! download_script "$name"; then
        echo "❌ $name 下載失敗"
        return 1
    fi

    if [[ -z "$DOWNLOADED_PATH" || ! -f "$DOWNLOADED_PATH" ]]; then
        echo "❌ 下載器沒有取得有效檔案路徑"
        return 1
    fi

    echo
    echo "🚀 執行 $name"
    echo "📁 $DOWNLOADED_PATH"
    echo "────────────────────────────────────────"

    /usr/bin/env bash "$DOWNLOADED_PATH"
}

show_status() {
    echo
    echo "===== 系統 ====="
    hostnamectl 2>/dev/null | head -8 || true
    echo
    df -h / || true
    free -h || true

    echo
    echo "===== Panel ====="
    if [[ -f /var/www/pterodactyl/artisan ]]; then
        echo "✅ Panel detected"
        (cd /var/www/pterodactyl && php artisan p:info 2>/dev/null) || true
        for s in mariadb redis-server php8.3-fpm cron pteroq caddy; do
            printf "%-24s " "$s"
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
        printf "%-24s " "wings"
        systemctl is-active wings 2>/dev/null || true
        printf "%-24s " "docker"
        systemctl is-active docker 2>/dev/null || true
        printf "%-24s " "mc-ipv6-range-proxy"
        systemctl is-active mc-ipv6-range-proxy 2>/dev/null || true
    else
        echo "— Wings not detected"
    fi
}

update_manager() {
    bootstrap_tools
    local tmp="$CACHE_DIR/ptero-tool.sh.new"

    curl -fL --retry 3 --retry-delay 2 \
        "${REPO_RAW}/ptero-tool.sh?t=$(date +%s)" \
        -o "$tmp"

    bash -n "$tmp"
    chmod +x "$tmp"

    # 若目前腳本是實體檔案且可寫，直接更新自己。
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
        "${REPO_RAW}/ptero-tool.sh?t=$(date +%s)" \
        -o /usr/local/bin/ptero-tool
    chmod +x /usr/local/bin/ptero-tool
    ok "之後直接輸入 ptero-tool 即可開啟選單"
}

while true; do
    clear
    echo "============================================================"
    echo " Pterodactyl Deploy Manager v${VERSION}"
    echo "============================================================"
    echo
    echo " 1) 安裝 / 補完 Panel（Blueprint 全自動 + 硬性超時強殺）"
    echo "    Pterodactyl + Caddy + DB + Redis + Blueprint + Nebula"
    echo
    echo " 2) 安裝 / 補完 Node"
    echo "    Docker + Wings + Minecraft IPv6 Proxy"
    echo
    echo " 3) 開啟維護 / 修復 / 更新工具"
    echo " 4) 網路 / Public IPv6 / 25565-25600 設定"
    echo
    echo " 5) 查看目前 Panel / Node 狀態"
    echo
    echo " 6) 重新下載最新版 Panel 安裝器並執行"
    echo " 7) 重新下載最新版 Node 安裝器並執行"
    echo
    echo " 8) 安裝 ptero-tool 全域指令"
    echo " 9) 更新這個主選單"
    echo
    echo "10) 清除下載快取"
    echo
    echo " 0) 離開"
    echo
    read -rp "請選擇: " choice

    case "$choice" in
        1|6)
            run_component "panel-deploy.sh"
            read -rp "按 Enter 回主選單..." _
            ;;
        2|7)
            run_component "node-deploy.sh"
            read -rp "按 Enter 回主選單..." _
            ;;
        3)
            run_component "maintenance.sh"
            ;;
        4)
            run_component "network-config.sh"
            ;;
        5)
            show_status
            read -rp "按 Enter 回主選單..." _
            ;;
        8)
            install_manager_command
            read -rp "按 Enter 回主選單..." _
            ;;
        9)
            update_manager
            read -rp "按 Enter 回主選單..." _
            ;;
        10)
            rm -rf "$CACHE_DIR"
            mkdir -p "$CACHE_DIR"
            chmod 755 "$CACHE_DIR"
            ok "快取已清除"
            sleep 1
            ;;
        0)
            exit 0
            ;;
        *)
            warn "無效選項"
            sleep 1
            ;;
    esac
done
