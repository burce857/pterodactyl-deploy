# Pterodactyl Deploy Kit v9

v9 重新設計了主選單的下載器，不再使用：

```bash
path="$(download_script ...)"
```

所以「⬇️ 下載最新版 ...」等提示文字不可能再被誤當成檔案路徑。

新的流程：

1. `download_script` 直接下載到 `/var/tmp/pterodactyl-deploy/<script>`
2. 驗證檔案存在且非空
3. 防止 HTML 錯誤頁被當成 shell script
4. `bash -n` 語法檢查
5. 將真實路徑存進 `DOWNLOADED_PATH`
6. `run_component` 直接執行該路徑

## 重要

請先把 GitHub repo 裡的 `ptero-tool.sh` 覆蓋成 v9。
如果 GitHub 還是舊版，重新 curl 當然仍會下載舊的主選單。

## 執行

```bash
rm -f ptero-tool.sh
curl -fL "https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh?nocache=$(date +%s)" -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```

啟動時應看到：

```text
Pterodactyl Deploy Manager v9
```
