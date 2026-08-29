# Pterodactyl Deploy Kit v17

v17 在 Node 安裝器加入 `/etc/pterodactyl` 範例設定。

Node 安裝時會先建立：

```text
/etc/pterodactyl/
├── config.yml.example
├── public-ipv6.example
└── README.txt
```

Wings 從 Panel 抓設定成功後，真正設定檔會是：

```text
/etc/pterodactyl/config.yml
```

因此之後要改 Wings 可以直接：

```bash
nano /etc/pterodactyl/config.yml
systemctl restart wings
```

`config.yml.example` 只是範例，不會覆蓋或取代真正設定。

主入口：

```bash
curl -fL "https://raw.githubusercontent.com/burce857/pterodactyl-deploy/main/ptero-tool.sh?nocache=$(date +%s)" -o ptero-tool.sh
chmod +x ptero-tool.sh
sudo ./ptero-tool.sh
```

啟動應看到：

```text
Pterodactyl Deploy Manager v17
```
