# Pterodactyl Deploy Kit v8

v8 修正主選單下載器的重要問題：

之前 `download_script()` 的「⬇️ 下載最新版...」提示文字和實際路徑都輸出到 stdout，
而 `run_component()` 使用：

```bash
path="$(download_script "$name")"
```

因此 `path` 可能變成多行文字，最後執行時就會出現：

```text
/var/tmp/pterodactyl-deploy/panel-deploy.sh: No such file or directory
```

v8 已改成：

- 所有下載提示輸出到 stderr
- stdout 只回傳真正檔案路徑
- 執行前再次確認檔案存在
- 自動建立 `/var/tmp/pterodactyl-deploy`
- 下載後檢查檔案非空
- 下載後先跑 `bash -n`
- 清除快取後自動重建目錄

## 使用

```bash
curl -fsSL https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```
