---
name: zalo-bot-ahk
description: >-
  Build and maintain the Zalo Listing Bot (Windows, AutoHotkey v2 + Zalo Web):
  harvest rental listings from Zalo Web source groups via Tampermonkey, block banned
  keywords, save JSON locally, publish to main groups. Read BACKLOG.md for known bugs.
---

# Zalo Listing Bot — Agent Skill

## Platform

- **Windows** — AutoHotkey v2 + **Zalo Web** (Chrome + Tampermonkey)
- Entry: `windows/src/Bot.ahk`
- Userscript: `web/zalo-listing-bot.user.js`
- Config: `windows/config/config.ini`

## Layers

| Layer | File | Allowed |
|-------|------|---------|
| UI | `ZaloUI.ahk`, `WebBridge.ahk` | Chrome focus, bridge, Send/Clipboard |
| Parse | `Parser.ahk` | Regex, heuristic |
| Harvest | `Harvester.ahk` | Loop nhóm, gọi UI + Parser |
| Publish | `Publisher.ahk`, `Composer.ahk` | Queue, gửi tin |

**Cấm:** regex trong `ZaloUI.ahk`; `Send`/`Click` ngoài `ZaloUI.ahk`.

## Setup checklist

```
[ ] AutoHotkey v2 (64-bit)
[ ] Chrome + Tampermonkey + web/zalo-listing-bot.user.js
[ ] config.example.ini → config.ini
[ ] Đăng nhập https://chat.zalo.me vào đủ nhóm
[ ] run-tests.cmd → all pass
[ ] Chạy Bot.ahk
```

## Test

```cmd
windows\tests\run-tests.cmd
```

Sửa `Parser.ahk` → thêm case vào `RunTests.ahk`.

## Output format

Per room, per main group: paste ảnh → text → separator `=======`.
