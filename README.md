# Pterodactyl Deploy Kit v14

v14 新增黑名單：

- mclogs.blueprint
- consolelogs.blueprint
- laravellogs.blueprint
- mcplugins.blueprint
- minecraftplayermanager.blueprint

`minecraftplayermanager.blueprint` 也確認是 beta-2024-08，會在 beta-2026-08 卡在 46%，因此現在會直接跳過，不再等 300 秒。

主入口：

```bash
curl -fL "https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh?nocache=$(date +%s)" -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```

啟動確認：

```text
Pterodactyl Deploy Manager v14
```
