#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl 維護 / 修復 / 更新工具
# 同時支援 Panel 主機與 Wings Node 主機。
#
# 功能：
# - 狀態檢查
# - 維護模式 on/off
# - 清快取 / 修權限
# - Panel 備份
# - Panel 更新
# - Composer/Yarn/前端重建
# - Blueprint 重裝/重建
# - Wings 更新
# - Docker/Wings/Proxy 修復
# - 服務重啟
# - Log 檢視
# - OS 套件更新
# ============================================================

PTERO_DIR="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl-backups"
LOG="/var/log/pterodactyl-maintenance.log"

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  echo "❌ 需要 root 權限。"; exit 1
fi

exec > >(tee -a "$LOG") 2>&1
export DEBIAN_FRONTEND=noninteractive
export COMPOSER_ALLOW_SUPERUSER=1

has_panel(){ [[ -f "$PTERO_DIR/artisan" ]]; }
has_wings(){ command -v wings >/dev/null 2>&1 || [[ -x /usr/local/bin/wings ]]; }
pause(){ read -rp "按 Enter 繼續..." _; }

panel_backup() {
  has_panel || { echo "❌ 這台沒有 Panel。"; return; }
  mkdir -p "$BACKUP_DIR"
  local ts env dbname dbuser dbpass
  ts="$(date +%Y%m%d-%H%M%S)"
  env="$PTERO_DIR/.env"
  dbname="$(grep '^DB_DATABASE=' "$env" | cut -d= -f2- | tr -d '"')"
  dbuser="$(grep '^DB_USERNAME=' "$env" | cut -d= -f2- | tr -d '"')"
  dbpass="$(grep '^DB_PASSWORD=' "$env" | cut -d= -f2- | tr -d '"')"

  echo "📦 備份 Panel files..."
  tar -czf "$BACKUP_DIR/panel-files-$ts.tar.gz" \
      -C /var/www pterodactyl

  echo "🗄️ 備份 database..."
  MYSQL_PWD="$dbpass" mariadb-dump -h 127.0.0.1 -u "$dbuser" "$dbname" \
      > "$BACKUP_DIR/panel-db-$ts.sql"

  cp -a "$env" "$BACKUP_DIR/panel-env-$ts"
  [[ -f /etc/caddy/Caddyfile ]] && cp -a /etc/caddy/Caddyfile "$BACKUP_DIR/Caddyfile-$ts"
  echo "✅ 備份完成：$BACKUP_DIR"
}

panel_status() {
  echo "===== Panel ====="
  if has_panel; then
    cd "$PTERO_DIR"
    php artisan p:info 2>/dev/null || true
    echo
    systemctl --no-pager --full status php8.3-fpm mariadb redis-server cron pteroq caddy 2>/dev/null || true
    echo
    df -h /
    free -h
  else
    echo "未偵測到 Panel。"
  fi
}

node_status() {
  echo "===== Wings / Node ====="
  if has_wings; then
    /usr/local/bin/wings --version 2>/dev/null || true
    systemctl --no-pager --full status wings 2>/dev/null || true
    systemctl --no-pager --full status mc-ipv6-range-proxy 2>/dev/null || true
    echo
    docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null || true
    echo
    ss -ltnp | grep -E ':8080|:2556[5-9]|:255[7-9][0-9]|:25600' || true
  else
    echo "未偵測到 Wings。"
  fi
}

enter_maintenance() {
  has_panel || return
  cd "$PTERO_DIR"
  php artisan down
  echo "✅ Panel 已進入維護模式。"
}

leave_maintenance() {
  has_panel || return
  cd "$PTERO_DIR"
  php artisan up
  echo "✅ Panel 已離開維護模式。"
}

repair_panel() {
  has_panel || { echo "❌ 這台沒有 Panel。"; return; }
  cd "$PTERO_DIR"
  echo "🔧 補套件..."
  apt-get update
  apt-get install -y cron curl wget git unzip zip tar rsync jq \
    mariadb-client redis-server composer \
    php8.3 php8.3-cli php8.3-common php8.3-fpm php8.3-gd php8.3-mysql \
    php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip php8.3-intl

  command -v crontab >/dev/null 2>&1 || apt-get install -y cron
  systemctl enable --now cron mariadb redis-server php8.3-fpm

  echo "🔧 Composer..."
  composer install --no-dev --optimize-autoloader --no-interaction

  echo "🔧 Laravel caches/permissions..."
  mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
  php artisan optimize:clear || true
  php artisan view:clear || true
  php artisan config:clear || true
  php artisan queue:restart || true

  chown -R www-data:www-data "$PTERO_DIR"
  find storage -type d -exec chmod 775 {} \;
  find storage -type f -exec chmod 664 {} \;
  chmod -R 775 bootstrap/cache

  systemctl daemon-reload
  systemctl restart php8.3-fpm pteroq caddy 2>/dev/null || true
  echo "✅ Panel 基礎修復完成。"
}

rebuild_frontend() {
  has_panel || return
  cd "$PTERO_DIR"
  command -v node >/dev/null 2>&1 || { echo "❌ Node.js 未安裝"; return; }
  command -v yarn >/dev/null 2>&1 || npm install -g yarn
  yarn install
  if command -v blueprint >/dev/null 2>&1; then
    NODE_OPTIONS=--openssl-legacy-provider blueprint -build || \
      NODE_OPTIONS=--openssl-legacy-provider yarn build:production
  else
    NODE_OPTIONS=--openssl-legacy-provider yarn build:production
  fi
  php artisan optimize:clear
  chown -R www-data:www-data storage bootstrap/cache
  echo "✅ 前端重建完成。"
}

reinstall_blueprint() {
  has_panel || return
  cd "$PTERO_DIR"
  apt-get update
  apt-get install -y ca-certificates curl git gnupg unzip wget zip
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'parseInt(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]]; then
    install -d -m 0755 /etc/apt/keyrings
    rm -f /etc/apt/keyrings/nodesource.gpg
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list
    apt-get update && apt-get install -y nodejs
  fi
  command -v yarn >/dev/null 2>&1 || npm install -g yarn

  curl -fL -o release.zip https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip
  unzip -o release.zip
  rm -f release.zip
  cat >.blueprintrc <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF
  yarn install
  chmod +x blueprint.sh
  bash blueprint.sh
  echo "✅ Blueprint 重裝/修復完成。"
}

panel_update() {
  has_panel || return
  echo "⚠️ 更新 Panel 前會先備份並進維護模式。"
  panel_backup
  cd "$PTERO_DIR"
  php artisan down || true

  # 優先使用 Pterodactyl 內建 upgrade 指令
  if php artisan list --raw 2>/dev/null | grep -q '^p:upgrade'; then
    php artisan p:upgrade --user=www-data --group=www-data --release=latest
  else
    curl -fL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz
    rm -f panel.tar.gz
    composer install --no-dev --optimize-autoloader --no-interaction
    php artisan view:clear
    php artisan config:clear
    php artisan migrate --force
    php artisan db:seed --force
    chown -R www-data:www-data "$PTERO_DIR"
    php artisan queue:restart
  fi

  php artisan optimize:clear || true
  systemctl restart php8.3-fpm pteroq caddy 2>/dev/null || true
  php artisan up || true
  echo "✅ Panel 更新完成。若 Blueprint Extensions 不相容，請執行「重裝 Blueprint」與「重建前端」。"
}

update_wings() {
  has_wings || { echo "❌ 沒有 Wings。"; return; }
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "不支援架構"; return ;;
  esac
  systemctl stop wings
  cp -a /usr/local/bin/wings "/usr/local/bin/wings.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  curl -fL -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${arch}"
  chmod +x /usr/local/bin/wings
  systemctl start wings
  systemctl --no-pager status wings || true
  echo "✅ Wings 更新完成。"
}

repair_node() {
  apt-get update
  apt-get install -y curl ca-certificates socat tcpdump netcat-openbsd iproute2
  command -v docker >/dev/null 2>&1 || curl -sSL https://get.docker.com/ | CHANNEL=stable bash
  systemctl enable --now docker
  [[ -f /etc/systemd/system/wings.service ]] && systemctl enable --now wings
  [[ -f /etc/systemd/system/mc-ipv6-range-proxy.service ]] && systemctl enable --now mc-ipv6-range-proxy
  echo "✅ Node 基礎修復完成。"
}

restart_all() {
  systemctl daemon-reload
  for s in php8.3-fpm mariadb redis-server cron pteroq caddy docker wings mc-ipv6-range-proxy; do
    systemctl list-unit-files "$s.service" >/dev/null 2>&1 && systemctl restart "$s" 2>/dev/null || true
  done
  echo "✅ 已重啟偵測到的相關服務。"
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
  has_panel && repair_panel
  has_panel && reinstall_blueprint
  has_panel && rebuild_frontend
  has_wings && repair_node
  restart_all
  echo "✅ 完整修復流程完成。"
}

while true; do
  clear
  echo "============================================================"
  echo " Pterodactyl 維護工具"
  echo "============================================================"
  echo " 1) 全部狀態檢查"
  echo " 2) Panel 進入維護模式"
  echo " 3) Panel 離開維護模式"
  echo " 4) Panel 清快取 / 修權限 / 補依賴"
  echo " 5) Panel 備份（檔案 + DB + .env）"
  echo " 6) 更新 Pterodactyl Panel"
  echo " 7) 重建前端 / Blueprint Assets"
  echo " 8) 重裝 / 修復 Blueprint Framework"
  echo " 9) 更新 Wings"
  echo "10) 修復 Node / Docker / Wings 基礎依賴"
  echo "11) 重啟所有相關服務"
  echo "12) 查看 Log"
  echo "13) apt 系統更新"
  echo "14) 完整修復（Panel + Blueprint + Frontend + Node）"
  echo " 0) 離開"
  echo
  read -rp "請選擇: " c
  case "$c" in
    1) panel_status; echo; node_status; pause ;;
    2) enter_maintenance; pause ;;
    3) leave_maintenance; pause ;;
    4) repair_panel; pause ;;
    5) panel_backup; pause ;;
    6) panel_update; pause ;;
    7) rebuild_frontend; pause ;;
    8) reinstall_blueprint; pause ;;
    9) update_wings; pause ;;
    10) repair_node; pause ;;
    11) restart_all; pause ;;
    12) logs_menu; pause ;;
    13) apt-get update && apt-get upgrade -y; pause ;;
    14) full_repair; pause ;;
    0) exit 0 ;;
    *) echo "無效選項"; sleep 1 ;;
  esac
done
