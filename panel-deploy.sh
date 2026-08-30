#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Pterodactyl Panel + Blueprint + Nebula 一鍵部署 v27
# Ubuntu 22.04 / 24.04
# ============================================================

PTERO_DIR="/var/www/pterodactyl"
LOG="/var/log/pterodactyl-panel-deploy.log"
NOBITA_BASE="https://raw.githubusercontent.com/nobita329/Nobita-Cloud/main"
UI_BASE="${NOBITA_BASE}/thame/UI"
EXT_BASE="${NOBITA_BASE}/thame/Extension"

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

info(){ echo -e "\n🔹 $*"; }
ok(){ echo "✅ $*"; }
fail(){ echo "❌ $*" >&2; exit 1; }

trap 'echo "❌ 安裝在第 $LINENO 行失敗。Log: '"$LOG"'"' ERR

[[ -r /etc/os-release ]] || fail "找不到 /etc/os-release"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || fail "目前只支援 Ubuntu。"
case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) fail "目前不支援 Ubuntu ${VERSION_ID:-unknown}" ;;
esac

echo "============================================================"
echo " Pterodactyl Panel + Blueprint + Nebula 一鍵部署 v27"
echo "============================================================"

read -rp "Panel 網域（例 p.example.com）: " PANEL_DOMAIN
read -rp "管理員 Email: " ADMIN_EMAIL
read -rp "管理員 Username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"
read -rp "管理員名字 [Admin]: " ADMIN_FIRST
ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
read -rp "管理員姓氏 [User]: " ADMIN_LAST
ADMIN_LAST="${ADMIN_LAST:-User}"
read -rsp "管理員密碼: " ADMIN_PASS
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
    echo "ℹ️ 已自動產生資料庫密碼。"
fi

echo
echo "ℹ️ v27 UI-only 模式：只安裝 Blueprint Framework + Nebula UI"
echo "ℹ️ 所有其他 Blueprint Extensions 暫時全部跳過"
EXT_TIMEOUT=300
BP_INSTALL_MODE=1
[[ -n "$PANEL_DOMAIN" && -n "$ADMIN_EMAIL" && -n "$ADMIN_PASS" ]] || fail "必要欄位不可空白"

# ------------------------------------------------------------
# Package helper
# ------------------------------------------------------------
apt_retry() {
    local tries=0
    until apt-get "$@"; do
        tries=$((tries+1))
        if (( tries >= 3 )); then return 1; fi
        sleep 3
    done
}

install_yarn_classic() {
    info "安裝 / 修復 Yarn Classic 1.22.22"

    # 清掉 corepack shim 或壞掉的 global yarn，避免 npm 顯示成功但 PATH 找不到。
    if command -v corepack >/dev/null 2>&1; then
        corepack disable >/dev/null 2>&1 || true
    fi

    npm uninstall -g yarn >/dev/null 2>&1 || true
    rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg

    npm install -g yarn@1.22.22 --force
    hash -r || true

    # npm 某些版本/環境不會自動建立可執行連結，直接補上。
    if ! command -v yarn >/dev/null 2>&1; then
        YARN_JS="$(npm root -g)/yarn/bin/yarn.js"
        if [[ -f "$YARN_JS" ]]; then
            chmod +x "$YARN_JS"
            ln -sf "$YARN_JS" /usr/local/bin/yarn
            ln -sf "$YARN_JS" /usr/local/bin/yarnpkg
            hash -r || true
        fi
    fi

    command -v yarn >/dev/null 2>&1 || fail "Yarn 安裝後仍無法執行"
    yarn --version >/dev/null 2>&1 || fail "Yarn 指令存在但無法正常執行"

    ok "Yarn $(yarn --version)"
}

ensure_node_yarn() {
    NODE_MAJOR="$(node -p 'parseInt(process.versions.node.split(\".\")[0])' 2>/dev/null || echo 0)"
    if [[ "$NODE_MAJOR" -lt 22 ]]; then
        info "安裝 Node.js 22"
        install -d -m 0755 /etc/apt/keyrings
        rm -f /etc/apt/keyrings/nodesource.gpg
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list
        apt_retry update -y
        apt_retry install -y nodejs
    fi

    # 不只檢查 command -v，也實際執行版本檢查。
    if ! command -v yarn >/dev/null 2>&1 || ! yarn --version >/dev/null 2>&1; then
        install_yarn_classic
    fi
}

safe_yarn_install() {
    local dir="${1:-$PTERO_DIR}"
    cd "$dir"

    ensure_node_yarn

    if yarn install --network-timeout 600000; then
        return 0
    fi

    echo "⚠️ 第一次 yarn install 失敗，自動清理 node_modules/cache 後重試..."
    rm -rf node_modules
    rm -f package-lock.json
    yarn cache clean || true

    yarn install --network-timeout 600000 --ignore-engines
}

# ------------------------------------------------------------
# Base packages
# ------------------------------------------------------------
info "更新套件索引"
apt_retry update -y

info "安裝 Panel / Blueprint / 編譯依賴"
apt_retry install -y \
    ca-certificates curl wget gnupg gpg lsb-release apt-transport-https \
    software-properties-common debian-keyring debian-archive-keyring \
    unzip zip tar git rsync jq nano cron openssl coreutils util-linux \
    build-essential python3 python3-pip make g++ pkg-config \
    mariadb-server mariadb-client redis-server \
    php8.3 php8.3-cli php8.3-common php8.3-fpm php8.3-gd php8.3-mysql \
    php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-curl php8.3-zip \
    php8.3-intl php8.3-sqlite3

# Composer
if ! command -v composer >/dev/null 2>&1; then
    info "安裝 Composer"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
fi

# cron double-check
if ! command -v crontab >/dev/null 2>&1; then
    apt_retry install -y cron
fi

systemctl enable --now mariadb redis-server php8.3-fpm cron

# ------------------------------------------------------------
# Node.js 22 + Yarn
# ------------------------------------------------------------
ensure_node_yarn

# ------------------------------------------------------------
# Caddy - robust official key path
# ------------------------------------------------------------
install_caddy() {
    info "安裝 / 修復 Caddy 官方套件庫"

    rm -f /etc/apt/sources.list.d/caddy-stable.list
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    rm -f /etc/apt/keyrings/caddy-stable-archive-keyring.gpg

    apt_retry install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list

    chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod 0644 /etc/apt/sources.list.d/caddy-stable.list

    apt_retry update -y
    apt_retry install -y caddy
}

if ! command -v caddy >/dev/null 2>&1; then
    install_caddy
else
    ok "Caddy 已存在"
fi

# ------------------------------------------------------------
# Database
# ------------------------------------------------------------
info "建立 MariaDB 資料庫"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# ------------------------------------------------------------
# Panel
# ------------------------------------------------------------
info "下載 / 補齊 Pterodactyl Panel"
mkdir -p "$PTERO_DIR"
cd "$PTERO_DIR"

if [[ ! -f artisan ]]; then
    curl -fL -o panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzf panel.tar.gz
    rm -f panel.tar.gz
else
    echo "ℹ️ 偵測到既有 Panel，保留現有資料。"
fi

mkdir -p \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

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

# Try non-interactive admin creation; if unsupported, don't kill whole install.
if ! php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST" \
    --password="$ADMIN_PASS" \
    --admin=1; then
    echo "⚠️ 無法自動建立管理員（可能已存在或版本參數不同）。"
    echo "   安裝完成後可手動執行：php artisan p:user:make"
fi

chown -R www-data:www-data "$PTERO_DIR"
find storage -type d -exec chmod 775 {} \;
find storage -type f -exec chmod 664 {} \;
chmod -R 775 bootstrap/cache

# ------------------------------------------------------------
# Queue worker
# ------------------------------------------------------------
info "建立 pteroq"
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

# ------------------------------------------------------------
# Cron
# ------------------------------------------------------------
info "設定 Pterodactyl Cron"
command -v crontab >/dev/null 2>&1 || apt_retry install -y cron
systemctl enable --now cron

CRON_LINE='* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1'
(
    crontab -l 2>/dev/null | grep -vF "/var/www/pterodactyl/artisan schedule:run" || true
    echo "$CRON_LINE"
) | crontab -

# ------------------------------------------------------------
# Caddy config
# ------------------------------------------------------------
info "設定 Caddy"
# ------------------------------------------------------------
# Caddy — 使用獨立 site snippet，避免 Panel / Node 互相覆蓋
# ------------------------------------------------------------
mkdir -p /etc/caddy/sites

# 保留原本 Caddyfile；只確保它有載入 sites/*.caddy
touch /etc/caddy/Caddyfile
if ! grep -Fq 'import /etc/caddy/sites/*.caddy' /etc/caddy/Caddyfile; then
    printf '
# Managed by pterodactyl-deploy
import /etc/caddy/sites/*.caddy
' >> /etc/caddy/Caddyfile
fi

cat >/etc/caddy/sites/pterodactyl-panel.caddy <<EOF
${PANEL_DOMAIN} {
    root * /var/www/pterodactyl/public
    encode gzip zstd
    php_fastcgi unix//run/php/php8.3-fpm.sock
    file_server
}
EOF

caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy >/dev/null 2>&1 || true
systemctl reload caddy 2>/dev/null || systemctl restart caddy
systemctl enable --now caddy
systemctl restart caddy

# ------------------------------------------------------------
# Blueprint
# ------------------------------------------------------------
cd "$PTERO_DIR"

if command -v blueprint >/dev/null 2>&1; then
    info "偵測到 Blueprint 已安裝，跳過首次安裝流程"
    echo "✅ Blueprint: $(blueprint -version 2>/dev/null || echo installed)"

    # 仍補齊 .blueprintrc 與前端依賴，讓重跑腳本可以繼續安裝 Extensions。
    cat > .blueprintrc <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF

    safe_yarn_install "$PTERO_DIR" || true
else
    info "安裝 Blueprint Framework"

    curl -fL -o release.zip https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip
    unzip -o release.zip
    rm -f release.zip

    cat > .blueprintrc <<'EOF'
WEBUSER="www-data";
OWNERSHIP="www-data:www-data";
USERSHELL="/bin/bash";
EOF

    safe_yarn_install "$PTERO_DIR"
    chmod +x blueprint.sh

    set +e
    bash blueprint.sh
    bp_install_rc=$?
    set -e

    # Blueprint 的安裝器如果回覆 "already installed"，不要讓整支腳本失敗。
    if ! command -v blueprint >/dev/null 2>&1; then
        if [[ "$bp_install_rc" -ne 0 ]]; then
            fail "Blueprint CLI 安裝失敗 (exit=$bp_install_rc)"
        fi
        fail "Blueprint CLI 安裝後仍找不到"
    fi

    echo "✅ Blueprint: $(blueprint -version 2>/dev/null || echo installed)"
fi

# ------------------------------------------------------------
# Extensions
# ------------------------------------------------------------
WORK="$PTERO_DIR/.auto-blueprints"
mkdir -p "$WORK"
FAILED=()
SKIPPED=()

run_blueprint_with_watchdog() {
    local name="$1"
    local seconds="$2"
    local mode="${3:-auto}"
    local pid rc watcher

    # 用新的 session/process group 跑 Extension。
    # 超時時直接殺整個 process group，避免 custom install script
    # 產生的子程序脫離 timeout 後繼續卡住。
    if [[ "$mode" == "interactive" ]]; then
        setsid bash -c 'exec blueprint -install "$1"' _ "$name" &
    else
        setsid bash -c '
            set +o pipefail
            yes "" | blueprint -install "$1"
            exit ${PIPESTATUS[1]}
        ' _ "$name" &
    fi

    pid=$!

    (
        sleep "$seconds"

        if kill -0 "$pid" 2>/dev/null; then
            echo
            echo "⏱️ $name 已達 ${seconds}s，正在停止整個安裝程序群組..."
            kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
            sleep 10

            if kill -0 "$pid" 2>/dev/null; then
                echo "🛑 $name 仍未退出，強制 KILL..."
                kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    ) &
    watcher=$!

    set +e
    wait "$pid"
    rc=$?
    set -e

    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    # 124 作為我們自己的 timeout 狀態。
    if [[ "$rc" == "143" || "$rc" == "137" ]]; then
        return 124
    fi

    return "$rc"
}

download_install() {
    local base="$1"
    local name="$2"
    local dst="$WORK/$name"
    local rc=0

    case "$name" in
        mclogs.blueprint|consolelogs.blueprint|laravellogs.blueprint|mcplugins.blueprint|minecraftplayermanager.blueprint)
            echo "⏭️ 跳過已知不相容/會卡住的擴充：$name"
            SKIPPED+=("$name")
            return 0
            ;;
    esac

    echo
    echo "⬇️ 下載 $name"
    if ! curl -fL --retry 3 --retry-delay 2 -o "$dst" "$base/$name"; then
        FAILED+=("$name (download)")
        echo "⚠️ $name 下載失敗，跳過"
        return 0
    fi

    cp -f "$dst" "$PTERO_DIR/$name"

    if [[ "${BP_INSTALL_MODE:-1}" == "2" ]]; then
        echo "🧩 互動安裝 $name（硬性上限 ${EXT_TIMEOUT}s）"
        set +e
        run_blueprint_with_watchdog "$name" "$EXT_TIMEOUT" interactive
        rc=$?
        set -e
    else
        echo "🤖 全自動安裝 $name（自動送 Enter，硬性上限 ${EXT_TIMEOUT}s）"
        set +e
        run_blueprint_with_watchdog "$name" "$EXT_TIMEOUT" auto
        rc=$?
        set -e
    fi

    case "$rc" in
        0)
            echo "✅ $name 安裝完成"
            ;;
        124|137|143)
            echo "⚠️ $name 已超過 ${EXT_TIMEOUT}s，已強制終止並跳過"
            FAILED+=("$name (timeout)")
            ;;
        *)
            echo "⚠️ $name 安裝失敗（exit=$rc），已跳過"
            FAILED+=("$name (exit=$rc)")
            ;;
    esac

    # 再清一次可能殘留的同名 Blueprint 安裝程序。
    pkill -9 -f "blueprint.*-install.*${name}" 2>/dev/null || true
}

echo "ℹ️ v27：暫停自動安裝 Logs 類擴充：mclogs / consolelogs / laravellogs"
info "安裝 Nebula"
download_install "$UI_BASE" "nebula.blueprint"

echo
echo "⏭️ UI-only 模式：其他 Blueprint Extensions 全部不安裝。"
echo "   明天再逐一測試相容性後再決定要加哪些。"

# ------------------------------------------------------------
# Final build / repair
# ------------------------------------------------------------
info "補齊前端依賴並重建"
cd "$PTERO_DIR"
if ! safe_yarn_install "$PTERO_DIR"; then
    echo "⚠️ 前端依賴安裝仍失敗，但不讓整個部署流程中止；請查看 $LOG"
else
    ok "前端依賴完成"
fi

if ! NODE_OPTIONS=--openssl-legacy-provider blueprint -build; then
    echo "⚠️ blueprint -build 失敗，嘗試 yarn build:production"
    NODE_OPTIONS=--openssl-legacy-provider yarn build:production || true
fi

php artisan optimize:clear || true
php artisan queue:restart || true

chown -R www-data:www-data "$PTERO_DIR/storage" "$PTERO_DIR/bootstrap/cache"
systemctl restart php8.3-fpm pteroq caddy

echo
echo "🔎 最終自我檢查"
for cmd in php composer node npm yarn caddy blueprint; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "✅ $cmd: $(command -v "$cmd")"
    else
        echo "⚠️ $cmd: 找不到"
    fi
done

systemctl is-active --quiet mariadb && echo "✅ mariadb active" || echo "⚠️ mariadb not active"
systemctl is-active --quiet redis-server && echo "✅ redis active" || echo "⚠️ redis not active"
systemctl is-active --quiet php8.3-fpm && echo "✅ php-fpm active" || echo "⚠️ php-fpm not active"
systemctl is-active --quiet cron && echo "✅ cron active" || echo "⚠️ cron not active"
systemctl is-active --quiet pteroq && echo "✅ pteroq active" || echo "⚠️ pteroq not active"
systemctl is-active --quiet caddy && echo "✅ caddy active" || echo "⚠️ caddy not active"

echo
echo "============================================================"
echo "✅ Panel 部署 v27 完成"
echo "網址: https://${PANEL_DOMAIN}"
echo "Admin Email: ${ADMIN_EMAIL}"
echo "DB User: ${DB_USER}"
echo "DB Pass: ${DB_PASS}"
echo
echo "APP_KEY（請另外備份）:"
grep '^APP_KEY=' "$PTERO_DIR/.env" || true
echo
if ((${#SKIPPED[@]})); then
    echo "⏭️ 已自動跳過的已知問題 Extension："
    printf ' - %s\n' "${SKIPPED[@]}"
fi
if ((${#FAILED[@]})); then
    echo "⚠️ 以下第三方 Extension 失敗："
    printf ' - %s\n' "${FAILED[@]}"
fi
echo "Blueprint 模式: UI-only（Blueprint + Nebula）"
command -v blueprint >/dev/null 2>&1 && echo "Blueprint: $(blueprint -version 2>/dev/null || echo installed)"
echo "Log: $LOG"
echo "============================================================"
