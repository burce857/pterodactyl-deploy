# Pterodactyl Deploy Kit v23

v23 修正 Public Address Blueprint 安裝錯誤：

```text
FATAL: Cannot import extensions from external paths.
```

原因：
Blueprint beta-2026-08 不允許直接使用 `/var/tmp/publicaddress.blueprint` 這種 Panel 外部路徑。

現在流程：
1. 從 GitHub 下載到 `/var/tmp/publicaddress.blueprint`
2. 驗證檔案
3. 複製到 `/var/www/pterodactyl/publicaddress.blueprint`
4. `cd /var/www/pterodactyl`
5. 使用相對檔名：
   `blueprint -install publicaddress.blueprint`
6. 已安裝舊版時先移除 Extension 程式碼再重新安裝
7. 保留 `storage/app/publicaddress/node-ips.json`
8. 清除 Laravel cache

所以之後在主選單選「安裝/更新 127.0.0.1 -> Public IPv6 顯示功能」即可。
