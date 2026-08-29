#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Panel + Blueprint + Nebula + 推薦擴充 一鍵部署
# 適用：Ubuntu 24.04（Ubuntu 22.04 也通常可用）
#
# 來源：
#   Blueprint Framework: 官方最新 release
#   Nebula / Extensions:
#   https://github.com/nobita329/Nobita-Cloud
#
# 特性：
# - 自動安裝 Panel 基礎相依套件
# - 自動安裝 Node.js 22 / Yarn / Blueprint
# - 自動下載 nebula.blueprint
# - 自動下載並逐個安裝推薦 Extensions
# - 某個 Extension 失敗時不會整支腳本中止，會記錄失敗清單
# - Extension 自帶 install.sh 時，由 Blueprint 自動執行其附件/安裝流程
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "❌ 請用 root 執行：sudo bash panel-deploy.sh"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
PTERO_DIR="/var/www/pterodactyl"

echo "=============================================="
echo " Pterodactyl + Blueprint + Nebula 一鍵部署"
echo "=============================================="

read -rp "Panel 網域（例如 p.example.com）: " PANEL_DOMAIN
read -rp "資料庫名稱 [panel]: " DB_NAME
DB_NAME="${DB_NAME:-panel}"

read -rp "資料庫使用者 [pterodactyl]: " DB_USER
DB_USER="${DB_USER:-pterodactyl}"

read -rsp "資料庫密碼: " DB_PASS
echo

read -rp "管理員 Email: " ADMIN_EMAIL

if [[ -z "$PANEL_DOMAIN" || -z "$DB_PASS" || -z "$ADMIN_EMAIL" ]]; then
    echo "❌ 網域、資料庫密碼、管理員 Email 不可空白。"
    exit 1
fi

echo
echo "📦 更新套件索引..."
apt-get update

echo "📦 安裝 Panel / Blueprint / 編譯常用相依套件..."
apt-get install -y \
    ca-certificates curl wget gnupg gpg lsb-release apt-transport-https \
    software-properties-common unzip zip tar git rsync jq nano cron openssl \
    build-essential python3 python3-pip make g++ pkg-config \
    mariadb-server mariadb-client redis-server composer \
    php8.3 php8.3-cli php8.3-common php8.3-fpm php8.3-gd php8.3-mysql \
    php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip \
    php8.3-intl php8.3-sqlite3

systemctl enable --now mariadb redis-server php8.3-fpm cron

# ------------------------------------------------------------
# Node.js 22 / Yarn
# ------------------------------------------------------------
if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'parseInt(process.versions.node)' 2>/dev/null || echo 0)" -lt 22 ]]; then
    echo "📦 安裝 / 更新 Node.js 22..."
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
fi

if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
fi

if ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn
fi

# ------------------------------------------------------------
# Caddy
# ------------------------------------------------------------
if ! command -v caddy >/dev/null 2>&1; then
    echo "📦 安裝 Caddy..."
    install -d -m 0755 /etc/apt/keyrings
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
fi

# ------------------------------------------------------------
# Database
# ------------------------------------------------------------
echo "🗄️ 建立資料庫..."
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# ------------------------------------------------------------
# Pterodactyl Panel
# ------------------------------------------------------------
mkdir -p "$PTERO_DIR"
cd "$PTERO_DIR"

if [[ ! -f artisan ]]; then
    echo "⬇️ 下載最新版 Pterodactyl Panel..."
    curl -fLo panel.tar.gz \
        https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz
    rm -f panel.tar.gz
fi

mkdir -p \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

chmod -R 775 storage bootstrap/cache

if [[ ! -f .env ]]; then
    cp .env.example .env
fi

echo "📦 Composer install..."
COMPOSER_ALLOW_SUPERUSER=1 composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction

if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
    php artisan key:generate --force
fi

php artisan p:environment:setup \
    --author="${ADMIN_EMAIL}" \
    --url="https://${PANEL_DOMAIN}" \
    --timezone="Asia/Taipei" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass=null \
    --redis-port=6379

php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database="${DB_NAME}" \
    --username="${DB_USER}" \
    --password="${DB_PASS}"

php artisan migrate --seed --force

chown -R www-data:www-data "$PTERO_DIR"
find storage -type d -exec chmod 775 {} \;
find storage -type f -exec chmod 664 {} \;
chmod -R 775 bootstrap/cache

# ------------------------------------------------------------
# Queue Worker
# ------------------------------------------------------------
cat >/etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
Requires=redis-server.service

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

CRON_LINE='* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1'
(
    crontab -l 2>/dev/null | grep -vF "/var/www/pterodactyl/artisan schedule:run" || true
    echo "$CRON_LINE"
) | crontab -

# ------------------------------------------------------------
# Caddy
# ------------------------------------------------------------
cat >/etc/caddy/Caddyfile <<EOF
${PANEL_DOMAIN} {
    root * ${PTERO_DIR}/public
    encode zstd gzip
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server

    @hidden path /.env /storage/*
    respond @hidden 404
}
EOF

caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl restart caddy

# ------------------------------------------------------------
# Blueprint Framework
# ------------------------------------------------------------
echo
echo "🧩 安裝 Blueprint Framework..."

cd "$PTERO_DIR"

wget -q \
    "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip" \
    -O release.zip

unzip -o release.zip
rm -f release.zip

cat >"$PTERO_DIR/.blueprintrc" <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF

# Blueprint 官方要求 Panel Node dependencies
yarn install

chmod +x "$PTERO_DIR/blueprint.sh"
bash "$PTERO_DIR/blueprint.sh"

if ! command -v blueprint >/dev/null 2>&1; then
    echo "❌ Blueprint CLI 沒有成功建立。"
    exit 1
fi

echo "✅ Blueprint: $(blueprint -version 2>/dev/null || echo installed)"

# ------------------------------------------------------------
# Nebula + Extensions
# ------------------------------------------------------------
RAW_UI="https://raw.githubusercontent.com/nobita329/Nobita-Cloud/main/thame/UI"
RAW_EXT="https://raw.githubusercontent.com/nobita329/Nobita-Cloud/main/thame/Extension"

EXT_DIR="$PTERO_DIR/.auto-blueprints"
mkdir -p "$EXT_DIR"

download_blueprint() {
    local base="$1"
    local name="$2"
    local dst="$EXT_DIR/$name"

    echo "⬇️ 下載 $name"
    if ! curl -fL --retry 3 --retry-delay 2 -o "$dst" "$base/$name"; then
        echo "⚠️ 下載失敗：$name"
        rm -f "$dst"
        return 1
    fi

    if [[ ! -s "$dst" ]]; then
        echo "⚠️ 空檔案：$name"
        rm -f "$dst"
        return 1
    fi

    return 0
}

install_blueprint_file() {
    local file="$1"
    local name
    name="$(basename "$file")"

    cp -f "$file" "$PTERO_DIR/$name"

    echo "🧩 安裝 $name"
    if blueprint -install "$name"; then
        echo "✅ $name"
        return 0
    else
        echo "❌ $name 安裝失敗"
        return 1
    fi
}

FAILED=()

# 先裝 Nebula
echo
echo "🎨 下載並安裝 Nebula..."
if download_blueprint "$RAW_UI" "nebula.blueprint"; then
    if ! install_blueprint_file "$EXT_DIR/nebula.blueprint"; then
        FAILED+=("nebula.blueprint")
    fi
else
    FAILED+=("nebula.blueprint(download)")
fi

# ------------------------------------------------------------
# 推薦擴充清單
#
# 原則：
# - 先裝實用、常用、與 Minecraft/Pterodactyl 管理直接相關的
# - 暫不自動裝明顯重複/高衝突/高度客製化的擴充
#
# 你可自行在 GitHub 腳本裡增減陣列。
# ------------------------------------------------------------
RECOMMENDED_EXTENSIONS=(
    "loader.blueprint"
    "adminauditlogs.blueprint"
    "consolelogs.blueprint"
    "laravellogs.blueprint"
    "resourcealerts.blueprint"
    "resourcemanager.blueprint"
    "mclogs.blueprint"
    "mctools.blueprint"
    "mcplugins.blueprint"
    "minecraftplayermanager.blueprint"
    "playerlisting.blueprint"
    "modrinthbrowser.blueprint"
    "motdmaker.blueprint"
    "serverpropsmanager.blueprint"
    "configeditor.blueprint"
    "monacoeditor.blueprint"
    "urldownloader.blueprint"
    "databaseimportexport.blueprint"
    "autobackups.blueprint"
    "stats.blueprint"
    "vminfo.blueprint"
    "shownodeids.blueprint"
    "simplefavicons.blueprint"
    "simplefooters.blueprint"
    "nopagination.blueprint"
    "activitypurges.blueprint"
    "trashbin.blueprint"
)

echo
echo "🧩 開始安裝推薦 Extensions..."

for ext in "${RECOMMENDED_EXTENSIONS[@]}"; do
    echo
    if download_blueprint "$RAW_EXT" "$ext"; then
        if ! install_blueprint_file "$EXT_DIR/$ext"; then
            FAILED+=("$ext")
        fi
    else
        FAILED+=("$ext(download)")
    fi
done

# 清理 Laravel / Blueprint cache
cd "$PTERO_DIR"
php artisan optimize:clear || true
chown -R www-data:www-data "$PTERO_DIR/storage" "$PTERO_DIR/bootstrap/cache"
systemctl restart php8.3-fpm
systemctl restart pteroq
systemctl restart caddy

echo
echo "=============================================="
echo "✅ Panel + Blueprint 自動部署流程完成"
echo "=============================================="
echo "Panel：https://${PANEL_DOMAIN}"
echo
echo "建立管理員："
echo "cd ${PTERO_DIR} && php artisan p:user:make"
echo
echo "Blueprint："
echo "blueprint -info"
echo
echo "已下載的 blueprint 暫存："
echo "${EXT_DIR}"
echo

if (( ${#FAILED[@]} > 0 )); then
    echo "⚠️ 以下項目下載或安裝失敗："
    printf ' - %s\n' "${FAILED[@]}"
    echo
    echo "可稍後手動重試，例如："
    echo "cd ${PTERO_DIR} && blueprint -install 檔名.blueprint"
else
    echo "✅ Nebula 與推薦 Extensions 全部安裝成功。"
fi

echo
echo "注意：第三方 Extension 是否相容取決於其 target / Panel / Blueprint 版本。"
echo "腳本會讓單一 Extension 失敗時繼續安裝其他項目。"
echo "=============================================="
