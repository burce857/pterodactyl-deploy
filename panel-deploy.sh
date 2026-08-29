#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo '請用 root 執行：sudo bash panel-deploy.sh'
  exit 1
fi

read -rp 'Panel 網域（例如 p.example.com）: ' PANEL_DOMAIN
read -rp '資料庫名稱 [panel]: ' DB_NAME
DB_NAME=${DB_NAME:-panel}
read -rp '資料庫使用者 [pterodactyl]: ' DB_USER
DB_USER=${DB_USER:-pterodactyl}
read -rsp '資料庫密碼: ' DB_PASS
echo
read -rp '管理員 Email: ' ADMIN_EMAIL

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y curl ca-certificates gnupg lsb-release unzip tar git mariadb-server redis-server \
  php8.3 php8.3-cli php8.3-gd php8.3-mysql php8.3-pdo php8.3-mbstring php8.3-tokenizer \
  php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl php8.3-zip php8.3-intl php8.3-sqlite3 composer
systemctl enable --now mariadb redis-server php8.3-fpm

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt install -y nodejs
fi
npm install -g yarn

if ! command -v caddy >/dev/null 2>&1; then
  apt install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt update && apt install -y caddy
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
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage bootstrap/cache
cp -n .env.example .env || true
composer install --no-dev --optimize-autoloader
php artisan key:generate --force

php artisan p:environment:setup --author="${ADMIN_EMAIL}" --url="https://${PANEL_DOMAIN}" --timezone="Asia/Taipei" --cache=redis --session=redis --queue=redis --redis-host=127.0.0.1 --redis-pass=null --redis-port=6379
php artisan p:environment:database --host=127.0.0.1 --port=3306 --database="${DB_NAME}" --username="${DB_USER}" --password="${DB_PASS}"
php artisan migrate --seed --force

chown -R www-data:www-data /var/www/pterodactyl
find storage -type d -exec chmod 775 {} \;
find storage -type f -exec chmod 664 {} \;
chmod -R 775 bootstrap/cache

cat >/etc/systemd/system/pteroq.service <<'EOT'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload
systemctl enable --now pteroq
(crontab -l 2>/dev/null; echo '* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1') | crontab -

cat >/etc/caddy/Caddyfile <<EOT
${PANEL_DOMAIN} {
    root * /var/www/pterodactyl/public
    encode zstd gzip
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}
EOT
caddy validate --config /etc/caddy/Caddyfile
systemctl enable --now caddy
systemctl restart caddy

echo 'Panel 基礎部署完成。接著執行：'
echo 'cd /var/www/pterodactyl && php artisan p:user:make'
