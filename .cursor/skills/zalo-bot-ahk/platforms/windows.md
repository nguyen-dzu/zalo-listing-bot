# Windows — Zalo Web daily ops

## Requirements

- Windows 10/11
- AutoHotkey v2
- Chrome + Tampermonkey + `web/zalo-listing-bot.user.js`
- Bot account logged into https://chat.zalo.me in all source + output groups

## First run

1. Import userscript into Tampermonkey
2. Open Chrome → https://chat.zalo.me
3. Copy `config.example.ini` → `config.ini`
4. Run `windows\src\Bot.ahk` or `Launch-Bot-Dev.cmd`

## Startup folder

```cmd
windows\setup\install-startup.cmd
```

Creates shortcuts for **Zalo Web (Chrome)** and **Zalo Listing Bot**.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bot exits on start | Run `load-check.ahk`; ensure Tampermonkey script is enabled |
| Harvest empty | Update `SELECTORS` in userscript; verify group names match |
| Paste fails | Focus Chrome manually; check `WindowTitle` in config |
| Bridge timeout | Allow localhost:8080; restart bot |

## Architecture

1. **JS** reads DOM, navigates groups, copies images
2. **WebBridge** HTTP server on `127.0.0.1:8080`
3. **ZaloUI** activates Chrome, bridge navigate, paste Ctrl+V + Enter

## UI calibration (Aug 2026)

- **Window:** `MaximizeBrowser=0`, tune `NormalizedWidth` / `NormalizedHeight` (~1100×850)
- **Open group:** bridge `navigate` command (not sidebar mouse on PC Zalo)
- **Compose focus:** bridge `focus_compose`; fallback client click ~42% × 88%
- **Message pane:** harvest read focus ~55% × 45% (avoid image bubbles)
- **Debug:** `[Diagnostics] Enabled=1` → `data/ui-diagnostic.jsonl`; agent log via `AgentDebugLog`
- **E2E:** verify publish paste lands in compose, images before icon text, then `=======`
