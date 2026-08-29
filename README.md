# Pterodactyl Deploy Kit v10

v10 新增 Blueprint / Nebula 全自動安裝模式。

Panel 安裝開始時可以選：

- `1 = 全自動`（預設）
  - 遇到 Nebula 的 `Press 'RETURN' to continue` 會自動送 Enter
  - 其他需要單純 Enter 確認的 Blueprint extension 也會自動繼續
  - 每個 extension 仍有安裝 timeout，預設 300 秒
  - 某個 extension 卡死或不相容時會跳過，不拖死整套部署

- `2 = 互動`
  - 安裝器需要輸入時由你自己操作

## 主入口

```bash
curl -fL "https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh?nocache=$(date +%s)" -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```

啟動應顯示：

```text
Pterodactyl Deploy Manager v10
```
