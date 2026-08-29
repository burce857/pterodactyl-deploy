# Pterodactyl Deploy Kit

包含：

- `panel-deploy.sh`：Panel + Caddy + MariaDB + Redis + Blueprint + Nebula + Extensions
- `node-deploy.sh`：Docker + Wings + 可選 Minecraft IPv6 socat proxy
- `maintenance.sh`：更新、修復、備份、維護模式、重新安裝 Blueprint、更新 Wings

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

## 維護

```bash
curl -fsSL https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/maintenance.sh -o maintenance.sh
chmod +x maintenance.sh
sudo ./maintenance.sh
```

> 不要把 Panel DB 密碼、Admin 密碼、Pterodactyl API Token、Wings config.yml、`.env` 上傳到公開 GitHub。
