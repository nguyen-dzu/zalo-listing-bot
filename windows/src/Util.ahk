#Requires AutoHotkey v2.0
; Util.ahk — shared helpers (AHK v2 arrays have no native Join)

StrJoin(items, sep := "`n") {
    out := ""
    for i, value in items
        out .= (i > 1 ? sep : "") value
    return out
}

; FNV-1a over whitespace-normalised text — used to dedupe harvested messages
FnvHash(text) {
    normalized := RegExReplace(text, "\s+", "")
    h := 2166136261
    Loop Parse normalized {
        h := (h ^ Ord(A_LoopField)) & 0xFFFFFFFF
        h := (h * 16777619) & 0xFFFFFFFF
    }
    return Format("{:08x}", h)
}

NowStamp() {
    return FormatTime(, "yyyy-MM-dd HH:mm:ss")
}

CompactStamp() {
    return FormatTime(, "yyyyMMddHHmmss")
}

EnsureDir(path) {
    if !DirExist(path)
        DirCreate path
    return path
}

ReadTextFile(path) {
    if !FileExist(path)
        return ""
    text := FileRead(path, "UTF-8")
    ; strip BOM if present
    if SubStr(text, 1, 1) = Chr(0xFEFF)
        text := SubStr(text, 2)
    return text
}

WriteTextFile(path, content) {
    dir := RegExReplace(path, "\\[^\\]+$")
    if dir != path
        EnsureDir(dir)
    temp := path ".tmp." ProcessExist() "." A_TickCount
    FileAppend content, temp, "UTF-8-RAW"
    FileMove temp, path, 1
}

NormalizeNewlines(text) {
    return StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")
}

TrimLines(text) {
    lines := []
    for line in StrSplit(NormalizeNewlines(text), "`n")
        lines.Push(Trim(line))
    return lines
}

EnablePerMonitorDpiAwareness() {
    static done := false
    if done
        return
    done := true
    ; PER_MONITOR_AWARE_V2 (-4) aligns WinGetPos with MSAA accLocation.
    if _TryDpiAwarenessCall("SetProcessDpiAwarenessContext")
        return
    if _TryDpiAwarenessCall("SetThreadDpiAwarenessContext")
        return
    try {
        DllCall("user32\SetProcessDPIAware")
    } catch {
        return
    }
}

_TryDpiAwarenessCall(functionName) {
    try {
        DllCall(functionName, "Ptr", -4, "Ptr")
        return true
    } catch {
        return false
    }
}

; App root: dev layout (src/Bot.ahk + ../config) or release (ZaloListingBot.exe + config/).
DetectAppRoot(scriptDir := "", throwIfMissing := true) {
    dir := scriptDir != "" ? scriptDir : A_ScriptDir
    Loop 6 {
        if DirExist(dir "\config")
            return dir
        parent := RegExReplace(dir, "\\[^\\]+$")
        if parent = dir
            break
        dir := parent
    }
    if throwIfMissing
        throw Error("Khong tim thay thu muc config/.`n"
            . "Hay giai nen dung folder co Install.cmd + config\ + ZaloListingBot.exe.`n"
            . "Thu muc hien tai: " A_ScriptDir)
    return ""
}

LogStartupError(message) {
    root := DetectAppRoot(A_ScriptDir, false)
    if root = ""
        root := A_ScriptDir
    logPath := root "\data\startup-error.log"
    try EnsureDir(root "\data")
    stamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    try FileAppend stamp " " message "`n", logPath, "UTF-8"
    return logPath
}

WithinConfiguredHours(start, finish, current := "") {
    if start = "" || finish = ""
        return true
    if current = ""
        current := FormatTime(, "HH:mm")
    if StrCompare(start, finish) <= 0
        return StrCompare(current, start) >= 0
            && StrCompare(current, finish) <= 0
    return StrCompare(current, start) >= 0
        || StrCompare(current, finish) <= 0
}

; Put a local file path on the clipboard as CF_HDROP so Zalo can Ctrl+V it as
; an attachment (Gemini/Zalo workaround when bitmap paste is unreliable).
SetClipboardFile(filePath) {
    if !FileExist(filePath)
        return false
    path := filePath
    Loop Files filePath, "F" {
        path := A_LoopFileFullPath
        break
    }
    ; DROPFILES + double-null-terminated UTF-16 path list.
    pathBytes := (StrLen(path) + 1) * 2
    total := 20 + pathBytes + 2
    hGlobal := DllCall("GlobalAlloc", "UInt", 0x0002 | 0x0040, "UPtr", total, "Ptr") ; GMEM_MOVEABLE|ZEROINIT
    if !hGlobal
        return false
    pGlobal := DllCall("GlobalLock", "Ptr", hGlobal, "Ptr")
    if !pGlobal {
        DllCall("GlobalFree", "Ptr", hGlobal)
        return false
    }
    NumPut("UInt", 20, pGlobal, 0)      ; pFiles
    NumPut("Int", 0, pGlobal, 4)        ; pt.x
    NumPut("Int", 0, pGlobal, 8)        ; pt.y
    NumPut("UInt", 0, pGlobal, 12)      ; fNC
    NumPut("UInt", 1, pGlobal, 16)      ; fWide
    StrPut(path, pGlobal + 20, "UTF-16")
    DllCall("GlobalUnlock", "Ptr", hGlobal)
    if !DllCall("OpenClipboard", "Ptr", A_ScriptHwnd) {
        DllCall("GlobalFree", "Ptr", hGlobal)
        return false
    }
    DllCall("EmptyClipboard")
    if !DllCall("SetClipboardData", "UInt", 15, "Ptr", hGlobal) { ; CF_HDROP
        DllCall("CloseClipboard")
        DllCall("GlobalFree", "Ptr", hGlobal)
        return false
    }
    DllCall("CloseClipboard")
    return true
}

FileToBase64(filePath) {
    handle := FileOpen(filePath, "r")
    if !handle
        return ""
    size := handle.Length
    if size <= 0 {
        handle.Close()
        return ""
    }
    buf := Buffer(size)
    if handle.Read(buf) != size {
        handle.Close()
        return ""
    }
    handle.Close()
    outSize := 0
    if !DllCall("Crypt32\CryptBinaryToStringW",
        "Ptr", buf, "UInt", size, "UInt", 1,
        "Ptr", 0, "UInt*", &outSize, "UInt", 0, "UInt", 0)
        return ""
    outBuf := Buffer(outSize * 2, 0)
    if !DllCall("Crypt32\CryptBinaryToStringW",
        "Ptr", buf, "UInt", size, "UInt", 1,
        "Ptr", outBuf.Ptr, "UInt*", &outSize, "UInt", 0, "UInt", 0)
        return ""
    return StrReplace(StrGet(outBuf, outSize, "UTF-16"), "`r`n", "")
}

WriteBase64File(encoded, filePath) {
    value := RegExReplace(String(encoded), "\s")
    if value = ""
        throw Error("Dữ liệu ảnh base64 rỗng.")
    size := 0
    if !DllCall("Crypt32\CryptStringToBinaryW",
        "Str", value, "UInt", 0, "UInt", 1,
        "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        throw Error("Không đọc được kích thước ảnh base64.")
    data := Buffer(size)
    if !DllCall("Crypt32\CryptStringToBinaryW",
        "Str", value, "UInt", 0, "UInt", 1,
        "Ptr", data.Ptr, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        throw Error("Không decode được ảnh base64.")
    dir := RegExReplace(filePath, "\\[^\\]+$")
    if dir != filePath
        EnsureDir(dir)
    handle := FileOpen(filePath, "w")
    if !handle
        throw Error("Không mở được file ảnh: " filePath)
    handle.RawWrite(data, size)
    handle.Close()
    if !FileExist(filePath) || FileGetSize(filePath) <= 0
        throw Error("File ảnh decode bị rỗng: " filePath)
    return filePath
}
