# Pterodactyl Deploy Kit v5

包含三支腳本：

- `panel-deploy.sh`：Panel + MariaDB + Redis + PHP + Caddy + Blueprint + Nebula + Extensions
- `node-deploy.sh`：Docker + Wings + 可選 IPv6 -> Docker backend proxy
- `maintenance.sh`：更新、修復、備份、維護模式、重建 Blueprint、修 Caddy GPG key、更新 Wings

## Panel

```bash
curl -fsSL https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/panel-deploy.sh -o panel-deploy.sh
chmod +x panel-deploy.sh
sudo ./panel-deploy.sh
```

## Node

```bash
curl -fsSL https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/node-deploy.sh -o node-deploy.sh
chmod +x node-deploy.sh
sudo ./node-deploy.sh
```

## 維護工具

```bash
curl -fsSL https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/maintenance.sh -o maintenance.sh
chmod +x maintenance.sh
sudo ./maintenance.sh
```

## v4 修正

- Caddy GPG key 改用 `/usr/share/keyrings/caddy-stable-archive-keyring.gpg`
- 每次安裝 Caddy 前清除舊錯誤 key/repo
- cron / crontab 雙重檢查
- 非 root 自動嘗試 sudo
- Blueprint / Node.js 22 / Yarn 自動安裝
- 第三方 Extension 單一失敗不會中止整個流程
- 維護工具新增「修復 Caddy Repository / GPG Key」
- Node 支援 amd64 / arm64 Wings
- IPv6 proxy 自動抓 eth0 global IPv6 與 pterodactyl0 IPv4

> 不要將 `.env`、DB 密碼、API Token、Wings `config.yml`、SSH private key 上傳到公開 GitHub。


## v5 追加修正

- 修正 `npm install -g yarn` 顯示成功但 `yarn: command not found`
- 固定 Yarn Classic `1.22.22`
- 若 npm 沒建立 symlink，會自動建立 `/usr/local/bin/yarn` 與 `yarnpkg`
- Blueprint 安裝前會真的執行 `yarn --version` 驗證，不只看 npm 回傳值
- `yarn install` 失敗會自動清理 `node_modules` / cache 並重試
- 維護工具新增「修復 Node.js / Yarn」
- Panel 最後會自動檢查 php/composer/node/npm/yarn/caddy/blueprint 與主要 systemd 服務
