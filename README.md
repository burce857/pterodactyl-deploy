# Pterodactyl Deploy Kit v4

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
