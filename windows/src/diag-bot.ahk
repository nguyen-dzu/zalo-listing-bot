#Requires AutoHotkey v2.0
; Load Bot dependencies and validate configured source groups.
#Include Util.ahk
#Include JSON.ahk
#Include Config.ahk
#Include TableLoader.ahk
#Include GroupRegistry.ahk
#Include SourceGroupFile.ahk
#Include BotControlWindow.ahk
#Include BlockList.ahk
#Include Parser.ahk
#Include Storage.ahk
#Include StateStore.ahk
#Include QueueStore.ahk
#Include MediaStore.ahk
#Include Composer.ahk
#Include Acc.ahk
#Include ZaloUI.ahk
#Include GroupActivity.ahk
#Include MediaCapturer.ahk
#Include Harvester.ahk
#Include Publisher.ahk

results := []
Add(msg) {
    global results
    results.Push(msg)
}

Add("ScriptDir: " A_ScriptDir)
Add("Root: " DetectAppRoot())

try {
    cfg := AppConfig.Instance()
    Add("AppConfig OK")
    Add("SourceFile: " cfg.SourceGroupFilePath)
    Add("Source exists: " FileExist(cfg.SourceGroupFilePath))
} catch as err {
    Add("AppConfig FAILED: " err.Message)
}

if IsSet(cfg) {
    try {
        if cfg.SourceGroupFilePath = "" || !FileExist(cfg.SourceGroupFilePath)
            throw Error("Thieu file nhom input: " cfg.SourceGroupFilePath
                . "`nChay: Copy-Item -Force config\source-groups.example.csv config\source-groups.csv")
        names := SourceGroupFile.LoadNames(
            cfg.SourceGroupFilePath,
            cfg.SourceGroupSheet,
            cfg.SourceGroupColumn)
        registry := GroupRegistry(cfg)
        registry.SetSourceNames(names, cfg.SourceGroupFilePath)
        Add("Source groups: " registry.SourceGroups().Length)
        Add("Main groups: " registry.MainGroups().Length)
    } catch as err {
        Add("Load source groups FAILED: " err.Message)
    }
}

report := StrJoin(results, "`n")
root := DetectAppRoot(A_ScriptDir, false)
if root = ""
    root := A_ScriptDir
path := root "\data\diag-bot.txt"
EnsureDir(root "\data")
WriteTextFile(path, report)
MsgBox report "`n`nSaved: " path, "Bot diagnostic", "Iconi"
