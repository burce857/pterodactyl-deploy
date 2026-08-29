# Pterodactyl Deploy Kit v12

v12 先停用 Logs 類 Blueprint Extensions，避免舊版擴充卡住安裝：

- `mclogs.blueprint`
- `consolelogs.blueprint`
- `laravellogs.blueprint`

即使選「全部 Extensions」，這三個目前也不會自動安裝。

其他功能保留：

- Panel 一鍵部署
- Node / Wings
- Blueprint + Nebula
- Extension 硬性 timeout watchdog
- 全自動 Enter
- 25565-25600 IPv6 Proxy
- Public IPv6 顯示替換
- Maintenance / 更新 / 修復

主入口：

```bash
curl -fL "https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh?nocache=$(date +%s)" -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```

啟動時確認：

```text
Pterodactyl Deploy Manager v12
```
