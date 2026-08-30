# Pterodactyl Deploy Kit v25

Public Address Blueprint 1.4.0：

修正「有時候沒有套用 Public IPv6」：
- API 暫時失敗會自動重試，不會一次失敗後永遠維持 127.0.0.1。
- React/SPA 重新渲染後會自動再次替換。
- 進入頁面後 100ms / 500ms / 1200ms 再補套用。
- 每 1.5 秒安全掃描一次，若 Pterodactyl 把 127.0.0.1 畫回來會再次替換。
- 切換 Server、上一頁/下一頁、頁籤切回、視窗重新 focus 都會重新同步。
- 每 30 秒重新確認 Server -> Node mapping。
- 防止 wrapper 重複載入造成多個 observer/timer。
- 保留 v1.3.0 的 Copy 按鈕修正。
