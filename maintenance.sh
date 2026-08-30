#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl 維護 / 修復 / 更新工具 v27
# ============================================================

PTERO_DIR="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl-backups"
LOG="/var/log/pterodactyl-maintenance.log"

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$0" "$@"
    fi
    echo "❌ 需要 root 權限。"
    exit 1
fi

exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive
export COMPOSER_ALLOW_SUPERUSER=1

has_panel(){ [[ -f "$PTERO_DIR/artisan" ]]; }
has_wings(){ [[ -x /usr/local/bin/wings ]]; }
pause(){ read -rp "按 Enter 繼續..." _; }

kill_stuck_blueprint() {
    echo "🧹 清理卡住的 Blueprint / Extension 安裝程序..."
    pkill -TERM -f 'blueprint -install' 2>/dev/null || true
    sleep 2
    pkill -KILL -f 'blueprint -install' 2>/dev/null || true
    pkill -KILL -f '/var/www/pterodactyl/.*install' 2>/dev/null || true
    echo "✅ 已嘗試清理卡住的 Blueprint 安裝程序"
}

install_yarn_classic() {
    echo "🔧 安裝 / 修復 Yarn Classic 1.22.22..."
    command -v npm >/dev/null 2>&1 || { echo "❌ npm 不存在"; return 1; }

    if command -v corepack >/dev/null 2>&1; then
        corepack disable >/dev/null 2>&1 || true
    fi

    npm uninstall -g yarn >/dev/null 2>&1 || true
    rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg
    npm install -g yarn@1.22.22 --force
    hash -r || true

    if ! command -v yarn >/dev/null 2>&1; then
        local yarn_js
        yarn_js="$(npm root -g)/yarn/bin/yarn.js"
        if [[ -f "$yarn_js" ]]; then
            chmod +x "$yarn_js"
            ln -sf "$yarn_js" /usr/local/bin/yarn
            ln -sf "$yarn_js" /usr/local/bin/yarnpkg
            hash -r || true
        fi
    fi

    command -v yarn >/dev/null 2>&1 && yarn --version >/dev/null 2>&1
}

ensure_node_yarn() {
    local node_major
    node_major="$(node -p 'parseInt(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"

    if [[ "$node_major" -lt 22 ]]; then
        install -d -m 0755 /etc/apt/keyrings
        rm -f /etc/apt/keyrings/nodesource.gpg
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        apt-get update
        apt-get install -y nodejs
    fi

    if ! command -v yarn >/dev/null 2>&1 || ! yarn --version >/dev/null 2>&1; then
        install_yarn_classic
    fi
}

safe_yarn_install() {
    ensure_node_yarn || return 1
    cd "$PTERO_DIR"

    if yarn install --network-timeout 600000; then
        return 0
    fi

    rm -rf node_modules
    rm -f package-lock.json
    yarn cache clean || true
    yarn install --network-timeout 600000 --ignore-engines
}

repair_caddy_repo() {
    echo "🔧 修復 Caddy repository/GPG key..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg

    rm -f /etc/apt/sources.list.d/caddy-stable.list
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    rm -f /etc/apt/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list

    chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod 0644 /etc/apt/sources.list.d/caddy-stable.list

    apt-get update
    apt-get install -y caddy
    echo "✅ Caddy repo/key 已修復"
}

panel_status() {
    echo "===== Panel ====="
    if has_panel; then
        cd "$PTERO_DIR"
        php artisan p:info 2>/dev/null || true
        systemctl --no-pager --full status php8.3-fpm mariadb redis-server cron pteroq caddy 2>/dev/null || true
        df -h /
        free -h
    else
        echo "未偵測到 Panel"
    fi
}

node_status() {
    echo "===== Node ====="
    if has_wings; then
        /usr/local/bin/wings --version 2>/dev/null || true
        systemctl --no-pager --full status wings 2>/dev/null || true
        systemctl --no-pager --full status mc-ipv6-range-proxy 2>/dev/null || true
        docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null || true
    else
        echo "未偵測到 Wings"
    fi
}

panel_backup() {
    has_panel || { echo "❌ 沒有 Panel"; return; }
    mkdir -p "$BACKUP_DIR"
    local ts env dbname dbuser dbpass
    ts="$(date +%Y%m%d-%H%M%S)"
    env="$PTERO_DIR/.env"
    dbname="$(grep '^DB_DATABASE=' "$env" | cut -d= -f2- | tr -d '"')"
    dbuser="$(grep '^DB_USERNAME=' "$env" | cut -d= -f2- | tr -d '"')"
    dbpass="$(grep '^DB_PASSWORD=' "$env" | cut -d= -f2- | tr -d '"')"

    tar -czf "$BACKUP_DIR/panel-files-$ts.tar.gz" -C /var/www pterodactyl
    MYSQL_PWD="$dbpass" mariadb-dump -h 127.0.0.1 -u "$dbuser" "$dbname" \
        > "$BACKUP_DIR/panel-db-$ts.sql"
    cp -a "$env" "$BACKUP_DIR/panel-env-$ts"
    [[ -f /etc/caddy/Caddyfile ]] && cp -a /etc/caddy/Caddyfile "$BACKUP_DIR/Caddyfile-$ts"
    echo "✅ 備份完成：$BACKUP_DIR"
}

repair_panel() {
    has_panel || { echo "❌ 沒有 Panel"; return; }

    apt-get update || repair_caddy_repo
    apt-get install -y \
        cron curl wget git unzip zip tar rsync jq mariadb-client redis-server \
        php8.3 php8.3-cli php8.3-common php8.3-fpm php8.3-gd php8.3-mysql \
        php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-intl

    command -v crontab >/dev/null 2>&1 || apt-get install -y cron
    systemctl enable --now cron mariadb redis-server php8.3-fpm

    cd "$PTERO_DIR"
    composer install --no-dev --optimize-autoloader --no-interaction

    mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
    php artisan optimize:clear || true
    php artisan queue:restart || true

    chown -R www-data:www-data "$PTERO_DIR"
    find storage -type d -exec chmod 775 {} \;
    find storage -type f -exec chmod 664 {} \;
    chmod -R 775 bootstrap/cache

    systemctl restart php8.3-fpm pteroq caddy 2>/dev/null || true
    echo "✅ Panel 修復完成"
}

reinstall_blueprint() {
    has_panel || return
    cd "$PTERO_DIR"

    apt-get update || true
    apt-get install -y ca-certificates curl git gnupg unzip wget zip build-essential

    ensure_node_yarn

    curl -fL -o release.zip https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip
    unzip -o release.zip
    rm -f release.zip

    cat >.blueprintrc <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF

    safe_yarn_install
    chmod +x blueprint.sh

    if command -v blueprint >/dev/null 2>&1; then
        echo "ℹ️ Blueprint 已安裝，改用 framework upgrade/repair 流程"
        if blueprint -help 2>/dev/null | grep -q -- '-upgrade'; then
            blueprint -upgrade || true
        else
            echo "ℹ️ 目前版本無 -upgrade 指令，保留既有 Blueprint 並重新建置"
        fi
    else
        bash blueprint.sh
    fi

    command -v blueprint >/dev/null 2>&1 || { echo "❌ Blueprint 仍不可用"; return 1; }
    echo "✅ Blueprint 修復完成"
}

rebuild_frontend() {
    has_panel || return
    cd "$PTERO_DIR"
    safe_yarn_install

    if command -v blueprint >/dev/null 2>&1; then
        NODE_OPTIONS=--openssl-legacy-provider blueprint -build || \
        NODE_OPTIONS=--openssl-legacy-provider yarn build:production
    else
        NODE_OPTIONS=--openssl-legacy-provider yarn build:production
    fi

    php artisan optimize:clear
    chown -R www-data:www-data storage bootstrap/cache
    echo "✅ 前端重建完成"
}

panel_update() {
    has_panel || return
    panel_backup
    cd "$PTERO_DIR"
    php artisan down || true

    if php artisan list --raw 2>/dev/null | grep -q '^p:upgrade'; then
        php artisan p:upgrade --user=www-data --group=www-data --release=latest
    else
        curl -fL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
        tar -xzf panel.tar.gz
        rm -f panel.tar.gz
        composer install --no-dev --optimize-autoloader --no-interaction
        php artisan migrate --force
        chown -R www-data:www-data "$PTERO_DIR"
    fi

    php artisan optimize:clear || true
    php artisan queue:restart || true
    systemctl restart php8.3-fpm pteroq caddy 2>/dev/null || true
    php artisan up || true
    echo "✅ Panel 更新完成"
}

update_wings() {
    has_wings || { echo "❌ 沒有 Wings"; return; }

    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo "不支援架構"; return ;;
    esac

    systemctl stop wings
    cp -a /usr/local/bin/wings "/usr/local/bin/wings.backup.$(date +%Y%m%d-%H%M%S)" || true
    curl -fL -o /usr/local/bin/wings \
        "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
    chmod +x /usr/local/bin/wings
    systemctl start wings
    echo "✅ Wings 更新完成"
}

repair_node() {
    apt-get update || true
    apt-get install -y curl ca-certificates socat tcpdump netcat-openbsd iproute2
    command -v docker >/dev/null 2>&1 || curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker
    [[ -f /etc/systemd/system/wings.service ]] && systemctl enable --now wings
    [[ -f /etc/systemd/system/mc-ipv6-range-proxy.service ]] && systemctl enable --now mc-ipv6-range-proxy
    echo "✅ Node 修復完成"
}

restart_all() {
    systemctl daemon-reload
    for s in php8.3-fpm mariadb redis-server cron pteroq caddy docker wings mc-ipv6-range-proxy; do
        systemctl list-unit-files "$s.service" >/dev/null 2>&1 && systemctl restart "$s" 2>/dev/null || true
    done
    echo "✅ 相關服務已重啟"
}

logs_menu() {
    echo "1) Laravel"
    echo "2) pteroq"
    echo "3) Caddy"
    echo "4) Wings"
    echo "5) IPv6 Proxy"
    read -rp "選擇: " l
    case "$l" in
        1) tail -n 150 "$PTERO_DIR"/storage/logs/laravel*.log 2>/dev/null || true ;;
        2) journalctl -u pteroq -n 150 --no-pager ;;
        3) journalctl -u caddy -n 150 --no-pager ;;
        4) journalctl -u wings -n 150 --no-pager ;;
        5) journalctl -u mc-ipv6-range-proxy -n 150 --no-pager ;;
    esac
}

full_repair() {
    has_panel && repair_caddy_repo
    has_panel && repair_panel
    has_panel && reinstall_blueprint
    has_panel && rebuild_frontend
    has_wings && repair_node
    restart_all
    echo "✅ 完整修復完成"
}

while true; do
    clear
    echo "============================================================"
    echo " Pterodactyl 維護工具 v27"
    echo "============================================================"
    echo " 1) 全部狀態檢查"
    echo " 2) Panel 進入維護模式"
    echo " 3) Panel 離開維護模式"
    echo " 4) Panel 清快取 / 修權限 / 補依賴"
    echo " 5) Panel 備份"
    echo " 6) 更新 Pterodactyl Panel"
    echo " 7) 重建前端 / Blueprint Assets"
    echo " 8) 重裝 / 修復 Blueprint Framework"
    echo " 9) 修復 Caddy Repository / GPG Key"
    echo "10) 修復 Node.js / Yarn"
    echo "11) 更新 Wings"
    echo "12) 修復 Node / Docker / Proxy"
    echo "13) 重啟所有相關服務"
    echo "14) 查看 Log"
    echo "15) apt 系統更新"
    echo "16) 完整修復"
    echo "17) 強制清理卡住的 Blueprint Extension 安裝"
    echo " 0) 離開"
    echo

    read -rp "請選擇: " c
    case "$c" in
        1) panel_status; echo; node_status; pause ;;
        2) has_panel && (cd "$PTERO_DIR" && php artisan down); pause ;;
        3) has_panel && (cd "$PTERO_DIR" && php artisan up); pause ;;
        4) repair_panel; pause ;;
        5) panel_backup; pause ;;
        6) panel_update; pause ;;
        7) rebuild_frontend; pause ;;
        8) reinstall_blueprint; pause ;;
        9) repair_caddy_repo; pause ;;
        10) ensure_node_yarn; echo "✅ Node/Yarn 修復完成"; pause ;;
        11) update_wings; pause ;;
        12) repair_node; pause ;;
        13) restart_all; pause ;;
        14) logs_menu; pause ;;
        15) apt-get update && apt-get upgrade -y; pause ;;
        16) full_repair; pause ;;
        17) kill_stuck_blueprint; pause ;;
        0) exit 0 ;;
        *) echo "無效選項"; sleep 1 ;;
    esac
done


repair_caddy_sites_import() {
    mkdir -p /etc/caddy/sites
    touch /etc/caddy/Caddyfile
    if ! grep -Fq 'import /etc/caddy/sites/*.caddy' /etc/caddy/Caddyfile; then
        printf '\n# Managed by pterodactyl-deploy\nimport /etc/caddy/sites/*.caddy\n' >> /etc/caddy/Caddyfile
    fi
    caddy validate --config /etc/caddy/Caddyfile
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
}
