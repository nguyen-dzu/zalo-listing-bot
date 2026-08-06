# Testing — Zalo Listing Bot (Windows)

Toàn bộ test chạy trên Windows bằng AutoHotkey v2. Hai tầng: test logic (không cần Zalo) và test end-to-end (cần Zalo PC).

## Tầng 1 — Test logic, không cần Zalo

```cmd
windows\tests\run-tests.cmd
```

Hoặc chạy riêng:

```cmd
"C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" windows\tests\RunTests.ahk
type windows\tests\RunTests.log
```

AutoHotkey là app GUI-subsystem nên output ra console có thể không hiện. Vì vậy cả hai script
ghi kết quả ra `RunTests.log` / `Simulate.log` cạnh script; `run-tests.cmd` tự `type` các file này.

### RunTests.ahk

Kiểm tra: parse 9 trường, ưu tiên `Giá điện` trước `Giá`, gộp `Điện nước`, dò SĐT trong text tự do, che SĐT ở output, tách tin và gán ảnh đúng tin, marker ảnh không lọt vào text, blocklist, group registry, separator, cắt chunk, hash dedupe, nhận mã phòng `Q3-15`, JSON round-trip.

Exit code `1` nếu có test fail.

### Simulate.ahk

Chạy thử chu trình harvest → publish bằng file mẫu, in ra **chính xác** message bot sẽ gửi. Không đụng Zalo, không lưu gì.

Mỗi tin được đánh dấu `[LƯU]`, `[CẤM]`, `[TRÙNG]` hoặc `[THIẾU]`.

### Tạo dữ liệu test từ Zalo thật

1. Mở nhóm nguồn trên Zalo, bôi đen các tin gần nhất, copy
2. Tạo file `windows\tests\samples\<Tên nhóm đúng như trong groups.csv>.txt`, dán vào
3. Chạy lại `Simulate.ahk`

Script đọc `windows\config\groups.csv` để biết nhóm nào `source`, nhóm nào `main`, và `blocklist.csv` để biết từ khoá cấm. Chưa có file runtime thì nó dùng bản `.example.`.

---

## Tầng 2 — End-to-end với Zalo PC

### Chuẩn bị

1. Cài [AutoHotkey v2](https://www.autohotkey.com/)
2. Cài Zalo PC, đăng nhập **tài khoản bot**
3. Thêm tài khoản bot vào tất cả nhóm nguồn + nhóm chính
4. Chạy `windows\src\Bot.ahk` một lần — bot tự tạo `config.ini`, `groups.csv`, `blocklist.csv`
5. Sửa `windows\config\groups.csv`: tên nhóm phải **khớp chính xác** tên hiển thị trên Zalo
6. Bấm `Ctrl+Shift+R` để nạp lại

### Test case

| # | Bước | Kỳ vọng |
|---|------|---------|
| 1 | Chạy `Bot.ahk` | TrayTip hiện đúng số nhóm nguồn / nhóm chính |
| 2 | Sửa `groups.csv` → `Ctrl+Shift+R` | TrayTip báo số nhóm mới, không cần restart |
| 3 | Mở nhóm nguồn, bôi đen vài tin → `Ctrl+Shift+H` | TrayTip: `Mới: n \| Cấm: n \| Trùng: n` |
| 4 | Xem `windows\data\listings.json` | Object đủ trường, `published: 0` |
| 5 | Bấm `Ctrl+Shift+H` lần nữa cùng tin đó | Tất cả vào `Trùng`, không lưu thêm |
| 6 | Chọn tin có ảnh → `Ctrl+Shift+I` | Ảnh xuất hiện ở nhóm chính |
| 7 | `Ctrl+Shift+G` | Nhóm chính nhận message có separator `------------Tên Nhóm------------` |
| 8 | Xem lại `listings.json` | `published: 1`, có `published_at` |
| 9 | Gõ `SĐT P001`, bôi đen → `Ctrl+Shift+P` | Bot dán SĐT, ghi `access_log.json` |

### Test case lỗi

| Tình huống | Kỳ vọng |
|------------|---------|
| Tin chứa `Đã chốt` | Đếm vào `Cấm`, không vào nhóm chính |
| Tin thiếu `Địa chỉ:` | Không tách thành tin, bỏ qua |
| Tin thiếu SĐT | Đếm vào `Thiếu field` |
| `groups.csv` không có dòng `type=main` | TrayTip "Thiếu nhóm chính" |
| Zalo chưa mở | TrayTip lỗi, bot không treo |
| Không có tin mới → `Ctrl+Shift+G` | TrayTip "Không có tin mới" |

### Hiệu chỉnh khi Zalo chạy chậm

Tăng dần trong `windows\config\config.ini`:

```ini
[Timing]
SearchDelayMs=600
OpenChatDelayMs=1200
BetweenMessagesMs=1500
```

---

## Workflow dev

```
1. Sửa code trong windows\src\
2. windows\tests\run-tests.cmd          → unit test phải xanh
3. Xem output của Simulate.ahk          → đúng format mong muốn chưa
4. Chạy Bot.ahk, test case tầng 2
5. Chỉnh [Timing] nếu Zalo phản hồi chậm
```

Thêm trường mới hoặc đổi format output thì **phải bổ sung test tương ứng** trong `RunTests.ahk`.

---

## Compile .exe

```cmd
mkdir windows\dist
Ahk2Exe /in windows\src\Bot.ahk /out windows\dist\ZaloListingBot.exe
```
