# Zalo Web Bridge — Tampermonkey

Userscript kết nối **1 tab Zalo Web (Chrome)** với **AHK v2** qua HTTP localhost.

Zalo Web chỉ cho **một phiên đăng nhập**. Mở 2 tab cùng tài khoản sẽ đá tab cũ (`Session Expired`). Bot dùng **1 tab in-place**: harvest nhóm nguồn → chuyển sidebar sang nhóm sale → AHK dán/gửi → quay lại nhóm nguồn.

## Cài đặt Tampermonkey (Chrome mới hay báo script chưa chạy)

1. Cài [Tampermonkey](https://www.tampermonkey.net/) trên Chrome
2. **Bắt buộc trên Chrome 138+:**
   - Mở `chrome://extensions`
   - Tampermonkey → **Details**
   - Bật **Allow User Scripts** (Cho phép User Scripts)
3. Import / cập nhật `web/zalo-listing-bot.user.js` (**v4.0.1**)
4. Tampermonkey Dashboard → script **Enabled**
5. Đóng hết tab Zalo Web, mở **đúng 1 tab** `https://chat.zalo.me/#bot` rồi **F5**
6. Thành công khi:
   - Title tab bắt đầu bằng `[ZaloBot]`
   - Góc phải có nhãn xanh `ZaloBot ON`
   - Tampermonkey **không** còn dòng "Tập lệnh này chưa từng được chạy"

Nếu vẫn chưa chạy: click icon Tampermonkey trên tab Zalo → chọn script → **Reload this page**.

## Luồng 1 tab

```
[ Chrome #bot — 1 tab ]                 [ AHK v2 ]
  DomEngine + MutationObserver            WebBridge :8080
  navigate nhóm nguồn  → scan/copy ảnh    Harvester / Parser / Queue
  navigate nhóm sale   → focus_compose    Publisher: Ctrl+V + Enter
```

| Bước | Ai làm | Chi tiết |
|------|--------|----------|
| 1 | JS + AHK | Mở nhóm nguồn, quét tin, archive ảnh |
| 2 | JS | Click sidebar sang **1** nhóm `OutputGroups` |
| 3 | AHK | Dán ảnh → text → `=======` |
| 4 | AHK | Harvest nhóm nguồn tiếp theo trên cùng tab |

## API Bridge

Role duy nhất: `bot` (`POST /api/register`, `GET /api/command?role=bot`).

| Endpoint | Mô tả |
|----------|-------|
| `GET /api/health` | Health + role `bot` |
| `POST /api/register` | JS đăng ký tab |
| `GET /api/command?role=bot` | Poll lệnh |
| `POST /api/command-result` | JS trả kết quả |
| `POST /api/event` | Push tin mới (bỏ qua khi đang ở nhóm sale) |
| `GET /api/config` | `output_groups` để JS không ingest tin nhóm sale |

### Lệnh JS

`ping`, `navigate`, `scan`, `dump_dom`, `unread`, `forward_message`, `find_images`, `copy_image`, `focus_compose`, `focus_pane`, `title`, `pause_events`, `resume_events`

## Config AHK

```ini
[ZaloWeb]
WindowTitle=[ZaloBot]
ChatUrl=https://chat.zalo.me/#bot
BridgePort=8080

[Groups]
OutputGroups=Tên nhóm sale (đúng 1 nhóm)
```
