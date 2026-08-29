# Pterodactyl Deploy Kit v13

v13 新增「已知問題 Blueprint Extension 黑名單」。

目前會直接跳過：

- `mclogs.blueprint`
- `consolelogs.blueprint`
- `laravellogs.blueprint`
- `mcplugins.blueprint`

其中 `mcplugins.blueprint` 已確認在 Blueprint `beta-2026-08` 上會停在 46%，而它本身標示為 `beta-2024-08`。

即使選擇「全部 Extensions」，上述項目也會直接顯示：

```text
⏭️ 跳過已知不相容/會卡住的擴充：mcplugins.blueprint
```

不會浪費 300 秒等待 timeout。

其他 Extension 仍保留：
- 自動 Enter
- 硬性 watchdog timeout
- 安裝失敗自動跳下一個

主入口：

```bash
curl -fL "https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh?nocache=$(date +%s)" -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```

啟動應看到：

```text
Pterodactyl Deploy Manager v13
```
