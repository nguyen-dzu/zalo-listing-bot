# Zalo Listing Bot

Bot gom tin phòng từ **nhiều nhóm nguồn** trên Zalo PC (Windows + AutoHotkey v2), lọc bỏ tin đã chốt, lưu từng tin thành object dưới máy, rồi gửi **ảnh trước, cụm message sau** vào nhóm chính.

```
Nhóm nguồn 1 ┐
Nhóm nguồn 2 ├─► lọc từ khoá cấm ─► lưu object local ─► Nhóm chính
Nhóm nguồn N ┘                                          [ảnh] + [message]
```

Tên nhóm và từ khoá cấm đọc từ file **Excel/CSV**; mỗi nhóm trong message ngăn nhau bằng
`------------Tên Nhóm------------`.

## Quick start (Windows)

```cmd
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" windows\src\Bot.ahk
```

Lần đầu chạy bot tự tạo `config.ini`, `groups.csv`, `blocklist.csv`. Sửa `groups.csv` cho khớp
tên nhóm thật rồi bấm `Ctrl+Shift+R`.

| Hotkey | Chức năng |
|--------|-----------|
| `Ctrl+Shift+H` | Thu thập tin mới từ mọi nhóm nguồn |
| `Ctrl+Shift+I` | Chuyển ảnh đang chọn sang nhóm chính (gửi trước text) |
| `Ctrl+Shift+G` | Gửi cụm message vào nhóm chính |
| `Ctrl+Shift+J` | Thu thập + gửi |
| `Ctrl+Shift+B` | Chuyển thủ công 1 tin đang bôi đen |
| `Ctrl+Shift+P` | Cấp SĐT theo mã phòng |
| `Ctrl+Shift+R` | Nạp lại config + Excel |

## Cấu hình

`windows/config/groups.csv`

| group_name | type | enabled | note |
|------------|------|---------|------|
| Nhóm Cho Thuê Quận 1 | source | 1 | Nhóm nguồn |
| Nhóm Sale Nội Bộ | main | 1 | Nhóm chính |

`windows/config/blocklist.csv`

| keyword | match_type | enabled |
|---------|------------|---------|
| LOCK | contains | 1 |
| Đã chốt | contains | 1 |

Có thể thay bằng `zalo-groups.xlsx` với 2 sheet `Groups` / `Blocklist`.

## Test (không cần Zalo)

```cmd
windows\tests\run-tests.cmd
```

`RunTests.ahk` chạy unit test cho Parser / BlockList / Composer / JSON.
`Simulate.ahk` in ra **chính xác** message bot sẽ gửi, dựa trên file mẫu trong
`windows\tests\samples\`.

Chi tiết: [docs/TESTING.md](docs/TESTING.md)

## Yêu cầu

- Windows 10/11
- [AutoHotkey v2](https://www.autohotkey.com/) — cài bản **v2**, không phải v1
- Zalo PC, đăng nhập tài khoản bot đã ở trong mọi nhóm nguồn và nhóm chính
- MS Excel (tuỳ chọn — không có thì dùng CSV)

### Cấu hình Cursor / VS Code (Windows)

Sau khi cài AutoHotkey v2, mở **Settings** (`Ctrl+,`) → tìm `AutoHotkey2: Interpreter Path` và đặt:

```
C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe
```

Project đã có sẵn trong `.vscode/settings.json`. Nếu AHK cài chỗ khác, sửa đường dẫn cho khớp.

Kiểm tra nhanh trong PowerShell:

```powershell
Test-Path "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
```

Trả về `True` là đúng. Nếu `False`, tìm file thật:

```powershell
Get-ChildItem "C:\Program Files\AutoHotkey" -Recurse -Filter "AutoHotkey*.exe"
```

**Lưu ý:** AutoHotkey **không chạy trên macOS**. Mở project trên Mac vẫn sửa code được, nhưng Run/Debug `.ahk` phải làm trên máy Windows.

## Docs

- [System Design](docs/SYSTEM_DESIGN.md)
- [Design Patterns](docs/DESIGN_PATTERNS.md)
- [Testing](docs/TESTING.md)
- [Cursor Skill](.cursor/skills/zalo-bot-ahk/SKILL.md)
