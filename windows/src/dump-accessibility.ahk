#Requires AutoHotkey v2.0
#Include Util.ahk
#Include Config.ahk
#Include Acc.ahk

cfg := AppConfig.Instance()
title := "ahk_exe " cfg.ExeName
if !WinExist(title) {
    MsgBox "Zalo PC is not running.", "Accessibility dump", "Iconx"
    ExitApp 1
}

WinActivate title
if !WinWaitActive(title,, 5) {
    MsgBox "Cannot activate Zalo PC.", "Accessibility dump", "Iconx"
    ExitApp 1
}

path := cfg.DataDir "\zalo-accessibility-dump.txt"
try {
    root := Acc.ElementFromHandle(WinExist(title))
    WriteTextFile(path, root.DumpAll(" | ", cfg.GroupAccessibilityDepth))
    MsgBox "Saved:`n" path, "Accessibility dump", "Iconi"
    ExitApp 0
} catch as err {
    WriteTextFile(path, "ERROR: " err.Message)
    MsgBox "Accessibility failed:`n" err.Message "`n`nSaved:`n" path,
        "Accessibility dump", "Iconx"
    ExitApp 1
}
