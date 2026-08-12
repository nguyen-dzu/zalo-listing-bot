# Zalo Web Bridge — Tampermonkey

Userscript kết nối **2 cửa sổ Zalo Web (Chrome)** với **AHK v2** qua HTTP localhost.

## Cài đặt

1. Cài [Tampermonkey](https://www.tampermonkey.net/) trên Chrome
2. Import `web/zalo-listing-bot.user.js`
3. Tạo **2 bookmark** (hoặc shortcut startup):
   - **Harvest:** `https://chat.zalo.me/#harvest` → title tab: `[Harvest] Zalo`
   - **Publish:** `https://chat.zalo.me/#publish` → title tab: `[Publish] Zalo`
4. Trong cửa sổ Harvest: sidebar mở các **nhóm nguồn**
5. Trong cửa sổ Publish: sidebar mở **nhóm output** (main) cố định
6. Chạy `windows\src\Bot.ahk`

Tab Zalo thường (không có `#harvest` / `#publish`) **không poll** lệnh bridge — tránh race condition.

## Kiến trúc 2 cửa sổ

```
[ Chrome #harvest ]                    [ AHK v2 ]
  DomEngine + MutationObserver           WebBridge :8080
  Poll commands (harvest role)    ◄──►   Harvester / Parser / Queue
  POST /api/event

[ Chrome #publish ]
  Poll ping + focus_compose only  ◄──►   ZaloUI paste Ctrl+V + Enter
```

| Cửa sổ | URL hash | Title | Vai trò |
|--------|----------|-------|---------|
| Harvest | `#harvest` | `[Harvest] Zalo` | Đọc DOM, navigate nhóm nguồn, copy ảnh |
| Publish | `#publish` | `[Publish] Zalo` | Focus compose, paste/gửi tin (AHK keystrokes) |

## API Bridge

| Endpoint | Mô tả |
|----------|-------|
| `GET /api/health` | Health + trạng thái 2 role |
| `POST /api/register` | JS đăng ký role (`harvest` / `publish`) |
| `GET /api/register` | AHK xem client đã sẵn sàng chưa |
| `GET /api/command?role=harvest` | Harvest poll lệnh |
| `GET /api/command?role=publish` | Publish poll lệnh (ping, focus_compose) |
| `POST /api/command-result` | JS trả kết quả |
| `POST /api/event` | Push tin mới (chỉ Harvest observer) |

### Lệnh JS

| action | Role | Mô tả |
|--------|------|-------|
| `ping` | cả hai | Health check |
| `navigate` | harvest | Mở nhóm nguồn (`group`) |
| `scan` | harvest | Quét tin trong chat |
| `dump_dom` | harvest | Diagnostic: selector, messageCount, sampleTexts |
| `unread` | harvest | Nhóm có badge chưa đọc |
| `find_images` | harvest | Tìm URL ảnh gần anchor |
| `copy_image` | harvest | Copy 1 ảnh vào clipboard |
| `focus_compose` | publish | Focus ô soạn tin |

### DomEngine

Userscript dùng **selector tiers** có thứ tự ưu tiên + scoring (text, ảnh, message pane). Fallback cuối: `div[contenteditable="false"]` trong message pane (loại trừ compose/sidebar/header).

Chạy diagnostic trên máy thật:

```text
AHK gọi bridge RunCommand("dump_dom") → xem matchedSelector, messageCount
```

Nếu `messageCount = 0`, cập nhật `SELECTORS.messageItemTiers` trong userscript theo DOM Zalo Web hiện tại.

## Config AHK

```ini
[ZaloWeb]
HarvestWindowTitle=[Harvest]
PublishWindowTitle=[Publish]
HarvestUrl=https://chat.zalo.me/#harvest
PublishUrl=https://chat.zalo.me/#publish
BridgePort=8080
```
