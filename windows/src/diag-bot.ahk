#Requires AutoHotkey v2.0
; Load the same module chain as Bot.ahk, then try ListingBotService startup.
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
        bot := ListingBotService(cfg)
        Add("ListingBotService OK")
    } catch as err {
        detail := err.Message
        if err.HasProp("File") && err.File != ""
            detail .= "`n" err.File ":" err.Line
        Add("ListingBotService FAILED: " detail)
    }

    if IsSet(bot) {
        try {
            if cfg.SourceGroupFilePath = "" || !FileExist(cfg.SourceGroupFilePath)
                throw Error("Thieu file nhom input: " cfg.SourceGroupFilePath
                    . "`nChay: copy config\source-groups.example.csv config\source-groups.csv")
            bot._LoadSourceGroups()
            Add("Source groups: " bot.registry.SourceGroups().Length)
            Add("Main groups: " bot.registry.MainGroups().Length)
        } catch as err {
            Add("Load source groups FAILED: " err.Message)
        }
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
