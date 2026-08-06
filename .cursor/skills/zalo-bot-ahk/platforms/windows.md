# Windows Platform

## Requirements

- Windows 10/11
- AutoHotkey v2 (64-bit)
- Zalo PC
- Tài khoản Zalo riêng cho bot, đã tham gia **mọi nhóm nguồn và nhóm chính**
- MS Excel (tuỳ chọn — không có thì dùng CSV)

## First run

```cmd
cd zalo-listing-bot
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" windows\src\Bot.ahk
```

Lần chạy đầu bot tự tạo từ file example:

- `windows\config\config.ini`
- `windows\config\groups.csv`
- `windows\config\blocklist.csv`

Sửa `groups.csv` cho khớp tên nhóm thật rồi bấm `Ctrl+Shift+R` để nạp lại.

## Daily operation

```
1. Mở Zalo PC, mở nhóm nguồn
2. Bôi đen các tin mới          (Capture Method=manual)
3. Ctrl+Shift+H                 thu thập + lưu object
4. Chọn tin có ảnh → Ctrl+Shift+I   chuyển ảnh sang nhóm chính
5. Ctrl+Shift+G                 gửi cụm message text
```

Muốn ít thao tác hơn: đặt `[Capture] Method=selectall` rồi dùng `Ctrl+Shift+J` (thu thập + gửi trong một lần).

## Compile to EXE

```cmd
mkdir windows\dist
Ahk2Exe /in windows\src\Bot.ahk /out windows\dist\ZaloListingBot.exe
```

`Bot.ahk` dùng `#Include` tương đối nên Ahk2Exe gói toàn bộ module vào một file.

## Auto-start

1. Win+R → `shell:startup`
2. Tạo shortcut tới `ZaloListingBot.exe`
3. Đảm bảo Zalo PC cũng khởi động cùng Windows

## UI automation notes

`ZaloUIAdapter` chỉ dùng:

1. `WinActivate` theo `ahk_exe Zalo.exe`
2. `Ctrl+F` → gõ tên nhóm → `Enter`
3. `Ctrl+C` để copy hội thoại, `Ctrl+V` + `Enter` để gửi
4. `[Images] ForwardHotkey` (mặc định `^q`) để mở hộp thoại Chuyển tiếp

Khi Zalo cập nhật giao diện: chỉnh `[Timing]` trước, sau đó mới sửa `ZaloUI.ahk`. Riêng `ForwardHotkey` phải khớp phím tắt Chuyển tiếp của phiên bản Zalo đang dùng.
