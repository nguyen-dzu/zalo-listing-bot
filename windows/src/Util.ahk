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

; App root: dev layout (src/Bot.ahk + ../config) or release (ZaloListingBot.exe + config/).
DetectAppRoot(scriptDir := "") {
    dir := scriptDir != "" ? scriptDir : A_ScriptDir
    if DirExist(dir "\config")
        return dir
    parent := RegExReplace(dir, "\\[^\\]+$")
    if DirExist(parent "\config")
        return parent
    throw Error("Không tìm thấy thư mục config/. "
        . "Đặt ZaloListingBot.exe cạnh thư mục config/.")
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
