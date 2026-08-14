# Zalo Listing Bot

Bot Windows (AutoHotkey v2) thu thập tin **phòng cho thuê** từ nhiều nhóm Zalo Web nguồn, lọc tin cấm, lưu JSON local, rồi đăng lại sang nhóm output (main).

```
Nhóm nguồn 1 ┐
Nhóm nguồn 2 ├─► [1 tab Zalo Web] DOM scan ─► AHK ─► cùng tab, nhóm sale
Nhóm nguồn N ┘    (Tampermonkey)                    paste/send
```

**1 tab Chrome** — Zalo Web single-session: harvest rồi chuyển sidebar sang nhóm output, không mở tab thứ hai.

Khi khởi động, bot mở popup để chọn hoặc kéo-thả file **CSV/XLSX** chứa tên nhóm input. Bot giữ nguyên thứ tự dòng trong file. Bản 1-tab dùng đúng **một** `OutputGroups` (nhóm sale); từ khóa cấm đọc từ `blocklist.csv`/Excel.

---

## Cài đặt

| Thành phần | Ghi chú |
|------------|---------|
| Windows 10/11 | Bắt buộc |
| [AutoHotkey v2](https://www.autohotkey.com/) | **v2** |
| Chrome + [Tampermonkey](https://www.tampermonkey.net/) | Userscript `web/zalo-listing-bot.user.js` trên https://chat.zalo.me |
| MS Excel | Chỉ khi file nhóm input là `.xlsx`/`.xls` |

Chi tiết Zalo Web: [web/README.md](web/README.md)

```powershell
git clone <repo-url> zalo-listing-bot
cd zalo-listing-bot
```

Copy runtime config:

```text
windows/config/config.ini      ← từ config.example.ini
windows/config/blocklist.csv   ← từ blocklist.example.csv
```

Cài Tampermonkey script → mở **1 tab**:
- `https://chat.zalo.me/#bot` (title `[ZaloBot] Zalo`)

Không mở tab Zalo Web thứ hai (Zalo sẽ đá session).

Hoặc chạy `windows\setup\install-startup.ps1` để tạo shortcut Startup.

Chạy bot:

```powershell
& "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe" windows\src\Bot.ahk
```

Test (không cần Chrome):

```cmd
windows\tests\run-tests.cmd
```

---

## Kiến trúc

| Layer | File | Vai trò |
|-------|------|---------|
| **JS** | `web/zalo-listing-bot.user.js` | DomEngine, role hash, observer, copy ảnh |
| **Bridge** | `WebBridge.ahk` | HTTP `127.0.0.1:8080`, route theo role |
| **UI** | `ZaloUI.ahk` | 1 tab: navigate nguồn / sale + keystrokes |
| **Logic** | Parser, Harvester, Queue, Publisher | Parse, lưu, publish |

```
windows/
├── src/
│   ├── Bot.ahk
│   ├── WebBridge.ahk
│   ├── ZaloUI.ahk
│   ├── Parser.ahk
│   └── ...
web/
├── zalo-listing-bot.user.js
└── README.md
```

---

## Config chính

```ini
[ZaloWeb]
BrowserExe=chrome.exe
WindowTitle=[ZaloBot]
ChatUrl=https://chat.zalo.me/#bot
BridgePort=8080

[Groups]
SourceFile=config\source-groups.csv
OutputGroups=Nhóm A

[Startup]
AutoRunWatch=1
WaitForBrowserSeconds=120
LaunchBrowserIfMissing=1
```

Đầy đủ: `windows/config/config.example.ini`

---

## Hotkeys

Mặc định `EnableHotkeys=0` — bot chạy tự động. `Ctrl+Shift+K` luôn bật để dừng khẩn cấp.

---

## Tài liệu

- [web/README.md](web/README.md) — Tampermonkey + bridge API
- [Design Patterns](docs/DESIGN_PATTERNS.md)
- [Agent Skill](.cursor/skills/zalo-bot-ahk/SKILL.md)
