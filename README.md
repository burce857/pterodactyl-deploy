# Pterodactyl Deploy Kit v21

已把你上傳的 Node 修復內容正式合併進完整工具。

Node 部署現在會自動：
- HTTPS Panel 強制要求獨立 Node FQDN。
- 驗證 Node FQDN 格式，避免跟 Panel 網域相同。
- 沒有 Caddy 就自動安裝。
- 建立獨立 `/etc/caddy/sites/<node-fqdn>.caddy`，不覆蓋 Panel。
- 設定 `https://Node:443 -> http://127.0.0.1:8080`。
- 驗證 Caddy 是否真的啟動。
- 驗證 reverse_proxy 是否正確。
- 驗證 Wings 8080；HTTP 401 視為正常。
- 顯示 Panel Node 正確設定：SSL Yes / Behind Proxy Yes / Port 443 / SFTP 2022。
- 修正 systemd PIDFile `/var/run` legacy warning。
- 保留 Public IPv6、25565-25600 Proxy、Public Address Blueprint 自動下載/更新。

