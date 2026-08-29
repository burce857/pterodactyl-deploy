# Pterodactyl Deploy Kit v19

v19 專門修正「Network / Public Address Manager 看不到安裝 Public Address 功能」的問題。

現在主選單直接多一個：

```text
5) 直接安裝/更新 127.0.0.1 -> Public IPv6 顯示功能
```

不需要先進 Network 子選單。

另外：
- `network-config.sh install-public-address` 可直接安裝顯示功能
- `ptero-tool.sh` 下載子腳本時會加 nocache，避免 GitHub/CDN 還抓到舊版
- Network 子選單本身仍保留：
  `Panel：安裝/更新 127.0.0.1 -> Public IPv6 顯示功能`

注意：這個功能要在 **Panel 主機** 執行，因為它會修改：

```text
/var/www/pterodactyl/resources/views/
/var/www/pterodactyl/storage/app/publicaddress/
```

Node 主機只需要設定 Public IPv6 / proxy，不需要安裝 Panel 顯示 runtime。
