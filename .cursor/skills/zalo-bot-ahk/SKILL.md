---
name: zalo-bot-ahk
description: >-
  Build and maintain the Zalo Listing Bot (Windows, AutoHotkey v2 + Zalo Web):
  harvest rental listings from Zalo Web source groups via Tampermonkey, block banned
  keywords, save JSON locally, publish to main groups. Read BACKLOG.md for known bugs.
---

# Zalo Listing Bot — Agent Skill

## Context nhanh (Aug 2026)

Per room, per main group: paste archive ảnh lưới (một tin) → video (nếu có) → text icon → `=======`. Tên nhóm nguồn chỉ trong `🏷️ tên nhóm`, không header riêng.

**ZaloUI đã calibrate (Zalo Web, 1 tab Chrome):**

- Cửa sổ normalized (`MaximizeBrowser=0`, `NormalizedWidth/Height` ~1100×850)
- Mở nhóm qua bridge `navigate` (không click search sidebar PC)
- Compose: bridge `focus_compose`, fallback click ~42%×88% client area
- Message pane focus: bridge `focus_pane` (header, không click ảnh). Fallback click ~52%×10% + Esc
- Publish session: `BeginPublishSession` → paste ảnh/text → `EndPublishSession`
- Diagnostics: `[Diagnostics] Enabled=1` → `data/ui-diagnostic.jsonl`

**Config UI quan trọng** (`config.example.ini`):

| Key | Mục đích |
|-----|----------|
| `NormalizedWidth` / `NormalizedHeight` | Cỡ cửa sổ Chrome cố định |
| `MaximizeBrowser` | `0` = normalized (khuyến nghị) |
| `PasteDelayMs`, `SendDelayMs`, `BetweenMessagesMs` | Timing paste/send |
| `CaptureSettleMs` | Chờ sau focus message pane |
| `MaxScanMessages` | Số tin mới nhất DOM scan mỗi nhóm (mặc định 20) |
| `[Diagnostics] LogFile` | JSONL click/publish debug |

**Backlog tóm tắt:** UI calibration **Done (needs E2E)**, output icon format **Done**.

## Platform

- **Windows** — AutoHotkey v2 + **Zalo Web** (Chrome + Tampermonkey, **1 tab**)
- Entry: `windows/src/Bot.ahk`
- Userscript: `web/zalo-listing-bot.user.js` (v4 single-tab)
- Config: `windows/config/config.ini`

## Layers

| Layer | File | Allowed |
|-------|------|---------|
| UI | `ZaloUI.ahk`, `WebBridge.ahk` | Chrome focus, bridge, Send/Clipboard |
| Parse | `Parser.ahk` | Regex, heuristic, `FormatBlock` (icon template) |
| Harvest | `Harvester.ahk` | Loop nhóm, gọi UI + Parser |
| Publish | `Publisher.ahk`, `Composer.ahk` | Queue, gửi tin |

**Cấm:** regex trong `ZaloUI.ahk`; `Send`/`Click` ngoài `ZaloUI.ahk`.

## Setup checklist

```
[ ] AutoHotkey v2 (64-bit)
[ ] Chrome + Tampermonkey + web/zalo-listing-bot.user.js
[ ] config.example.ini → config.ini
[ ] Đăng nhập https://chat.zalo.me/#bot (đúng 1 tab)
[ ] run-tests.cmd → all pass
[ ] Chạy Bot.ahk
```

## Test

```cmd
windows\tests\run-tests.cmd
```

Sửa `Parser.ahk` → thêm case vào `RunTests.ahk`.

## Output format

Per room, per main group: forward bubble gốc (nếu `forward_eligible`) hoặc paste archive ảnh → text icon → separator `=======`.

```text
🏷️ tên nhóm: Nhóm nguồn A
🏠 phòng: -
🔑 mã phòng: P001
📍 thông tin phòng: 123 Nguyễn Văn A
💰 giá: 5tr
🧾 giá dịch vụ: -
⚡ giá điện nước: -
📞 số điện thoại của chủ trọ: 090…
```
