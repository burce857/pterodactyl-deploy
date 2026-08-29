# Pterodactyl Deploy Kit v7

新增 `network-config.sh`：

- 設定/重建 25565-25600 IPv6 socat proxy
- 設定 Node Public IPv6
- Panel 管理 node1/node2/... -> Public IPv6
- Panel 顯示把 `127.0.0.1:PORT` 轉成 `[PublicIPv6]:PORT`
- 只改顯示，不會把 Docker Allocation 真正改成 Public IPv6
- Docker backend 仍自動偵測 `pterodactyl0`，通常是 `172.18.0.1`

主入口：

```bash
curl -fsSL https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```
