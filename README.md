# Pterodactyl Deploy Kit v27

v27 修正兩個 Node 實際遇到的問題：

## Docker / GHCR
- 自動測試 `https://ghcr.io/v2/`
- 自動測試 `docker pull ghcr.io/pterodactyl/installers:alpine`
- 如果 Docker pull 出現 TLS handshake timeout，會依序測 MTU 1450 / 1400 / 1350 / 1300
- 只有實際 pull 成功的 MTU 才永久套用
- 全部失敗會還原原本 MTU
- 成功後建立 `pterodactyl-mtu.service`，開機時在 Docker 前套用 MTU
- 預拉 `installers:alpine` 與 `yolks:java_25`
- 降低新 Server 卡 `Installing` 的機率

## Wings / Caddy
- 建立 `/usr/local/sbin/pterodactyl-wings-prepare`
- 每次 Wings 啟動前自動強制：
  - `api.port: 8080`
  - `ssl.enabled: false`
- Caddy 繼續使用 443
- 即使 Panel-generated config 又把 Wings 改回 443，systemd 啟動 Wings 前也會自動修回 8080
