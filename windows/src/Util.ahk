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
