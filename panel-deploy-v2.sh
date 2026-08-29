#!/usr/bin/env bash
set -Eeuo pipefail

# Pterodactyl Panel 一鍵部署腳本（Ubuntu 24.04）
# 會自動安裝常見缺少套件，盡量可重複執行。

if [[ $EUID -ne 0 ]]; then
    echo "❌ 請用 root 執行：sudo bash panel-deploy-v2.sh"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

read -rp "Panel 網域（例如 p.example.com）: " PANEL_DOMAIN
read -rp "資料庫名稱 [panel]: " DB_NAME
DB_NAME="${DB_NAME:-panel}"
read -rp "資料庫使用者 [pterodactyl]: " DB_USER
DB_USER="${DB_USER:-pterodactyl}"
read -rsp "資料庫密碼: " DB_PASS
echo
read -rp "管理員 Email: " ADMIN_EMAIL

if [[ -z "$PANEL_DOMAIN" || -z "$DB_PASS" || -z "$ADMIN_EMAIL" ]]; then
    echo "❌ 網域、資料庫密碼、Email 不可空白"
    exit 1
fi

echo "📦 更新套件..."
apt-get update

echo "📦 安裝所有常用相依套件..."
apt-get install -y \
    ca-certificates curl wget gnupg gpg lsb-release apt-transport-https \
    software-properties-common unzip zip tar git rsync jq nano cron openssl \
    mariadb-server mariadb-client redis-server composer \
    php8.3 php8.3-cli php8.3-common php8.3-fpm php8.3-gd php8.3-mysql \
    php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip \
    php8.3-intl php8.3-sqlite3

systemctl enable --now mariadb redis-server php8.3-fpm cron

if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi

if command -v corepack >/dev/null 2>&1; then
    corepack enable || true
fi

if ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn
fi

if ! command -v caddy >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /etc/apt/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
fi

mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl

if [[ ! -f artisan ]]; then
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz
    rm -f panel.tar.gz
fi

mkdir -p storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
chmod -R 775 storage bootstrap/cache

if [[ ! -f .env ]]; then
    cp .env.example .env
fi

COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction

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

chown -R www-data:www-data /var/www/pterodactyl
find storage -type d -exec chmod 775 {} \;
find storage -type f -exec chmod 664 {} \;
chmod -R 775 bootstrap/cache

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

cat >/etc/caddy/Caddyfile <<EOF
${PANEL_DOMAIN} {
    root * /var/www/pterodactyl/public
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

cd /var/www/pterodactyl
php artisan optimize:clear

echo
echo "=========================================="
echo "✅ Panel 基礎部署完成"
echo "網址：https://${PANEL_DOMAIN}"
echo
echo "建立管理員："
echo "cd /var/www/pterodactyl && php artisan p:user:make"
echo
echo "檢查服務："
echo "systemctl status php8.3-fpm mariadb redis-server cron pteroq caddy --no-pager"
echo "=========================================="
