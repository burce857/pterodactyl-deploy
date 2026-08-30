# Pterodactyl Deploy Kit v22

這版針對剛剛實際遇到的 Node 問題修正：

- `wings configure` 從 Panel 抓完 config 後，**在第一次啟動 Wings 前**強制校正：
  - `api.port: 8080`
  - `api.ssl.enabled: false`
  - `trusted_proxies: 127.0.0.1 / ::1`
  - `remote` 自動移除尾端 `/`
- 避免 Panel 的 Node 設定使用 SSL:443 時，把 Wings config 又寫成 443，造成 Wings 跟 Caddy 搶 Port。
- Caddy Node reverse proxy 明確使用 HTTP/1.1 upstream，適合 Console WebSocket。
- DNS 檢查改成「能不能解析」，不再錯誤比較 Cloudflare Proxy IP 與 origin IP。
- 如果 Node FQDN 尚未建立 DNS，會直接提醒 `ERR_NAME_NOT_RESOLVED`。
- Caddy 建好後會用 `--resolve ...:127.0.0.1` 測試本機 HTTPS → Caddy → Wings。
- 部署最後自動檢查：
  - `443 = Caddy`
  - `8080 = Wings`
  - `2022 = Wings SFTP`
- 保留 Public IPv6、25565-25600 proxy、Public Address Blueprint 等既有功能。
