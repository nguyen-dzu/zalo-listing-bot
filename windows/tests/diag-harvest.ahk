#Requires AutoHotkey v2.0
; Chạy script chẩn đoán thật trong windows/src (tránh lỗi #Include).
#SingleInstance Force

target := A_ScriptDir "\..\src\diag-harvest.ahk"
if !FileExist(target) {
    MsgBox 'Không tìm thấy: ' target, "diag-harvest", "Iconx"
    ExitApp 1
}

Run Format('"{1}" /ErrorStdOut "{2}"', A_AhkPath, target)
ExitApp 0
