#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Panel + Blueprint + Nebula 一鍵安裝
# Target: Ubuntu 22.04 / 24.04 (amd64/arm64 where supported)
#
# 只在最前面詢問必要/自訂資料，後續全自動。
# 不要把密碼/API Token 寫死後上傳 GitHub。
# ============================================================

PTERO_DIR="/var/www/pterodactyl"
NOBITA_REPO="https://raw.githubusercontent.com/nobita329/Nobita-Cloud/main"
UI_BASE="${NOBITA_REPO}/thame/UI"
EXT_BASE="${NOBITA_REPO}/thame/Extension"
LOG="/var/log/pterodactyl-panel-deploy.log"

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

fail() { echo "❌ $*" >&2; exit 1; }
info() { echo -e "\n🔹 $*"; }
ok()   { echo "✅ $*"; }

trap 'echo "❌ 安裝在第 $LINENO 行失敗。Log: '"$LOG"'"' ERR

[[ -r /etc/os-release ]] || fail "無法識別作業系統。"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "目前腳本只針對 Ubuntu 22.04/24.04。"
case "${VERSION_ID:-}" in
  22.04|24.04) ;;
  *) fail "不支援 Ubuntu ${VERSION_ID:-unknown}。" ;;
esac

echo "============================================================"
echo " Pterodactyl Panel + Blueprint + Nebula 一鍵安裝"
echo "============================================================"

read -rp "Panel 網域（例 p.example.com）: " PANEL_DOMAIN
read -rp "管理員 Email: " ADMIN_EMAIL
read -rp "管理員 Username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"
read -rp "管理員名字 [Admin]: " ADMIN_FIRST
ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
read -rp "管理員姓氏 [User]: " ADMIN_LAST
ADMIN_LAST="${ADMIN_LAST:-User}"
read -rsp "管理員密碼（至少 8 碼，大小寫+數字）: " ADMIN_PASS
echo
read -rp "Timezone [Asia/Taipei]: " PANEL_TZ
PANEL_TZ="${PANEL_TZ:-Asia/Taipei}"

read -rp "資料庫名稱 [panel]: " DB_NAME
DB_NAME="${DB_NAME:-panel}"
read -rp "資料庫使用者 [pterodactyl]: " DB_USER
DB_USER="${DB_USER:-pterodactyl}"
read -rsp "資料庫密碼（留空自動產生）: " DB_PASS
echo
if [[ -z "$DB_PASS" ]]; then
  DB_PASS="$(openssl rand -hex 20 2>/dev/null || date +%s%N)"
  echo "ℹ️ 已自動產生 DB 密碼（最後會顯示，請保存）。"
fi

echo
echo "Blueprint 擴充安裝模式："
echo "  1 = 推薦（較穩定）"
echo "  2 = 全部（你之前列出的全部，較容易遇到版本衝突）"
echo "  3 = 不裝擴充，只裝 Blueprint + Nebula"
read -rp "選擇 [1]: " EXT_MODE
EXT_MODE="${EXT_MODE:-1}"

[[ -n "$PANEL_DOMAIN" && -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" ]] || fail "必要欄位不可空白。"

# ------------------- packages -------------------
info "更新套件索引"
apt-get update -y

info "安裝所有 Panel / Blueprint / 編譯常用相依"
apt-get install -y \
  ca-certificates curl wget gnupg gpg lsb-release apt-transport-https \
  software-properties-common unzip zip tar git rsync jq nano cron openssl \
  build-essential python3 python3-pip make g++ pkg-config \
  mariadb-server mariadb-client redis-server \
  php8.3 php8.3-cli php8.3-common php8.3-fpm php8.3-gd php8.3-mysql \
  php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip \
  php8.3-intl php8.3-sqlite3

# Composer 官方安裝，避免 distro composer 過舊/缺失
if ! command -v composer >/dev/null 2>&1; then
  info "安裝 Composer 2"
  curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f /tmp/composer-setup.php
fi

# crontab 雙重保險（避免之前遇到 command not found）
if ! command -v crontab >/dev/null 2>&1; then
  apt-get install -y cron
fi

systemctl enable --now mariadb redis-server php8.3-fpm cron

# ------------------- Node.js + Yarn -------------------
if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'parseInt(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 22 ]]; then
  info "安裝 Node.js 22"
  install -d -m 0755 /etc/apt/keyrings
  rm -f /etc/apt/keyrings/nodesource.gpg
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y
  apt-get install -y nodejs
fi
if ! command -v yarn >/dev/null 2>&1; then
  npm install -g yarn
fi

# ------------------- Caddy -------------------
if ! command -v caddy >/dev/null 2>&1; then
  info "安裝 Caddy"
  install -d -m 0755 /etc/apt/keyrings
  rm -f /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

# ------------------- database -------------------
info "建立 MariaDB 資料庫"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

# ------------------- panel -------------------
info "下載 Pterodactyl Panel"
mkdir -p "$PTERO_DIR"
cd "$PTERO_DIR"

if [[ ! -f artisan ]]; then
  curl -fL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
else
  echo "ℹ️ 偵測到既有 Panel，保留現有檔案並補齊依賴。"
fi

mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
[[ -f .env ]] || cp .env.example .env

composer install --no-dev --optimize-autoloader --no-interaction

if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
  php artisan key:generate --force
fi

info "設定 Panel 環境"
php artisan p:environment:setup \
  --author="$ADMIN_EMAIL" \
  --url="https://${PANEL_DOMAIN}" \
  --timezone="$PANEL_TZ" \
  --cache=redis \
  --session=redis \
  --queue=redis \
  --redis-host=127.0.0.1 \
  --redis-pass=null \
  --redis-port=6379

php artisan p:environment:database \
  --host=127.0.0.1 \
  --port=3306 \
  --database="$DB_NAME" \
  --username="$DB_USER" \
  --password="$DB_PASS"

php artisan migrate --seed --force

# 管理員：若已存在則不讓整支腳本失敗
if ! php artisan p:user:make \
  --email="$ADMIN_EMAIL" \
  --username="$ADMIN_USER" \
  --name-first="$ADMIN_FIRST" \
  --name-last="$ADMIN_LAST" \
  --password="$ADMIN_PASS" \
  --admin=1; then
  echo "⚠️ 建立管理員失敗（可能帳號已存在），繼續安裝。"
fi

chown -R www-data:www-data "$PTERO_DIR"
find storage -type d -exec chmod 775 {} \;
find storage -type f -exec chmod 664 {} \;
chmod -R 775 bootstrap/cache

# ------------------- pteroq -------------------
info "建立 Queue Worker"
cat >/etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5s
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pteroq

# ------------------- cron -------------------
info "設定 Pterodactyl Cron"
command -v crontab >/dev/null 2>&1 || apt-get install -y cron
systemctl enable --now cron
CRON_LINE='* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1'
(
  crontab -l 2>/dev/null | grep -vF "/var/www/pterodactyl/artisan schedule:run" || true
  echo "$CRON_LINE"
) | crontab -

# ------------------- Caddy -------------------
info "設定 Caddy"
cat >/etc/caddy/Caddyfile <<EOF
${PANEL_DOMAIN} {
    root * ${PTERO_DIR}/public
    encode zstd gzip
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server

    @blocked {
        path /.env
        path /storage/*
    }
    respond @blocked 404
}
EOF
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl restart caddy

# ------------------- Blueprint -------------------
info "安裝 Blueprint Framework"
cd "$PTERO_DIR"

curl -fL -o release.zip https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip
unzip -o release.zip
rm -f release.zip

cat >"$PTERO_DIR/.blueprintrc" <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF

yarn install
chmod +x "$PTERO_DIR/blueprint.sh"
bash "$PTERO_DIR/blueprint.sh"

command -v blueprint >/dev/null 2>&1 || fail "Blueprint CLI 安裝失敗。"

# ------------------- extensions -------------------
WORK="$PTERO_DIR/.auto-blueprints"
mkdir -p "$WORK"
FAILED=()

download_and_install() {
  local base="$1"
  local name="$2"
  local f="$WORK/$name"

  echo "⬇️ $name"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$f" "$base/$name"; then
    FAILED+=("$name (download)")
    return 0
  fi
  cp -f "$f" "$PTERO_DIR/$name"

  echo "🧩 安裝 $name"
  if ! blueprint -install "$name"; then
    FAILED+=("$name")
  fi
}

info "安裝 Nebula"
download_and_install "$UI_BASE" "nebula.blueprint"

RECOMMENDED=(
  loader.blueprint adminauditlogs.blueprint consolelogs.blueprint laravellogs.blueprint
  resourcealerts.blueprint resourcemanager.blueprint mclogs.blueprint mctools.blueprint
  mcplugins.blueprint minecraftplayermanager.blueprint playerlisting.blueprint
  modrinthbrowser.blueprint motdmaker.blueprint serverpropsmanager.blueprint
  configeditor.blueprint monacoeditor.blueprint urldownloader.blueprint
  databaseimportexport.blueprint autobackups.blueprint stats.blueprint vminfo.blueprint
  shownodeids.blueprint simplefavicons.blueprint simplefooters.blueprint
  nopagination.blueprint activitypurges.blueprint trashbin.blueprint
)

ALL_EXTENSIONS=(
  adminauditlogs.blueprint huxregister.blueprint loader.blueprint lyrdyannounce.blueprint
  mclogs.blueprint mcplugins.blueprint mctools.blueprint minecraftplayermanager.blueprint
  playerlisting.blueprint resourcealerts.blueprint resourcemanager.blueprint
  serverbackgrounds.blueprint serversplitter.blueprint simplefavicons.blueprint
  snowflakes.blueprint sociallogin.blueprint startupchanger.blueprint subdomains.blueprint
  tawkto.blueprint versionchanger.blueprint pteromonaco.blueprint urldownloader.blueprint
  consolelogs.blueprint laravellogs.blueprint vanillatweaks.blueprint
  modrinthbrowser.blueprint nopagination.blueprint activitypurges.blueprint
  redirect.blueprint simplefooters.blueprint paneladdressoverride.blueprint
  shownodeids.blueprint votifiertester.blueprint sidebar.blueprint translations.blueprint
  monacoeditor.blueprint minecraftpluginmanager.blueprint subdomainmanager.blueprint
  serverimporter.blueprint pstatistics.blueprint pullfiles.blueprint
  serverpropsmanager.blueprint motdmaker.blueprint servericonimporter.blueprint
  sagaautosuspension.blueprint sagaminecraftmodpackinstaller.blueprint
  blueannoucements.blueprint trashbin.blueprint eggchanger.blueprint
  mysqlautobackup.blueprint configeditor.blueprint customserversort.blueprint
  databaseimportexport.blueprint minecraftmodmanager.blueprint serverid.blueprint
  stats.blueprint vminfo.blueprint customcss.blueprint autobackups.blueprint
  node.blueprint mcp.blueprint mcplayer.blueprint pterodactylramburst.blueprint
  pterodactylpanelban.blueprint pterodactylcpuburst.blueprint
)

case "$EXT_MODE" in
  1)
    info "安裝推薦 Extensions"
    for x in "${RECOMMENDED[@]}"; do download_and_install "$EXT_BASE" "$x"; done
    ;;
  2)
    info "安裝全部 Extensions（可能有互相衝突）"
    for x in "${ALL_EXTENSIONS[@]}"; do download_and_install "$EXT_BASE" "$x"; done
    ;;
  3)
    echo "ℹ️ 跳過額外 Extensions。"
    ;;
  *)
    echo "⚠️ 未知選項，改用推薦模式。"
    for x in "${RECOMMENDED[@]}"; do download_and_install "$EXT_BASE" "$x"; done
    ;;
esac

# Blueprint extension install scripts會自行安裝各自附件；
# 再補一次 JS dependencies/build，避免新元件未編譯。
info "補齊前端依賴並重新建置"
cd "$PTERO_DIR"
yarn install || true
NODE_OPTIONS=--openssl-legacy-provider blueprint -build || \
NODE_OPTIONS=--openssl-legacy-provider yarn build:production || true

php artisan optimize:clear || true
chown -R www-data:www-data storage bootstrap/cache
systemctl restart php8.3-fpm pteroq caddy

echo
echo "============================================================"
echo "✅ 安裝流程完成"
echo "Panel: https://${PANEL_DOMAIN}"
echo "Admin: ${ADMIN_EMAIL}"
echo "DB User: ${DB_USER}"
echo "DB Pass: ${DB_PASS}"
echo
echo "⚠️ 請另外安全保存 APP_KEY："
grep '^APP_KEY=' "$PTERO_DIR/.env" || true
echo
if ((${#FAILED[@]})); then
  echo "⚠️ 以下第三方 Extension 失敗（其他項目已繼續）："
  printf ' - %s\n' "${FAILED[@]}"
fi
echo
echo "Log: $LOG"
echo "============================================================"
