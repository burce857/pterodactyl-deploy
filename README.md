# Pterodactyl Deploy Kit v16 — UI Only

這版先求穩定，只安裝：

- Pterodactyl Panel
- Caddy
- MariaDB
- Redis
- PHP / Composer
- cron / pteroq
- Node.js / Yarn
- Blueprint Framework
- `nebula.blueprint` UI

暫時 **不安裝任何其他 Blueprint Extensions**。

這樣可以先確認：
1. Panel 能不能正常啟動
2. Nebula UI 能不能正常顯示
3. Blueprint Framework 本身是否穩定

明天再逐一測試 Extension，相容的再加回去。

主入口：

```bash
curl -fL "https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh?nocache=$(date +%s)" -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```

啟動應看到：

```text
Pterodactyl Deploy Manager v16
```
