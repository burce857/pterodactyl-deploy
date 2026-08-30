# Pterodactyl Deploy Kit v26

Public Address Blueprint 1.5.0 改成「資料源先換掉」。

以前：
Panel API 回 127.0.0.1 → React 顯示 → JS 再把畫面改成 Public IPv6。

現在：
Panel API 回 127.0.0.1 → fetch 攔截 → 根據 Node mapping 把 allocation.ip 先換成 Public IPv6 → React 一開始就拿 Public IPv6。

好處：
- 畫面第一次 render 就比較不會閃 127.0.0.1。
- Copy 按鈕使用的 allocation 原始資料本身就是 Public IPv6。
- Network / Console / Server Details 若共用同一份 Client API allocation，會直接拿 Public IPv6。
- 仍保留 DOM/Clipboard fallback，處理第三方 extension 或 React 後續重畫。
- 真正 Pterodactyl Allocation 與 Wings 綁定完全不變，只修改瀏覽器收到的 Client API response。
