#Requires AutoHotkey v2.0
; Step-by-step startup diagnostic. Run with AutoHotkey v2 from package root or src/.
#Include Util.ahk

results := []
Add(msg) {
    global results
    results.Push(msg)
}

try {
    Add("ScriptDir: " A_ScriptDir)
    Add("Root: " DetectAppRoot())
    Add("Config: " DetectAppRoot() "\config\config.ini")
} catch as err {
    Add("DetectAppRoot FAILED: " err.Message)
}

#Include Config.ahk
try {
    cfg := AppConfig.Instance()
    Add("AppConfig OK")
    Add("DataDir: " cfg.DataDir)
    Add("BlocklistCsv: " cfg.BlocklistCsv " exists=" FileExist(cfg.BlocklistCsv))
} catch as err {
    Add("AppConfig FAILED: " err.Message)
}

#Include TableLoader.ahk
#Include BlockList.ahk
if IsSet(cfg) {
    try {
        bl := BlockList(cfg)
        Add("BlockList OK, rules=" bl.rules.Length)
    } catch as err {
        Add("BlockList FAILED: " err.Message)
    }
} else {
    Add("BlockList SKIPPED (no config)")
}

#Include JSON.ahk
#Include StateStore.ahk
#Include QueueStore.ahk
if IsSet(cfg) {
    try {
        qs := PublishQueueStore(cfg)
        Add("QueueStore OK, entries=" qs.order.Length)
    } catch as err {
        Add("QueueStore FAILED: " err.Message)
    }
} else {
    Add("QueueStore SKIPPED (no config)")
}

#Include MediaStore.ahk
#Include Storage.ahk
if IsSet(cfg) {
    try {
        repo := ListingRepository(cfg)
        Add("ListingRepository OK, listings=" repo.listings.Length)
    } catch as err {
        Add("ListingRepository FAILED: " err.Message)
    }
} else {
    Add("ListingRepository SKIPPED (no config)")
}

#Include Acc.ahk
#Include ZaloUI.ahk
if IsSet(cfg) {
    try {
        ui := ZaloUIAdapter(cfg)
        Add("ZaloUIAdapter OK, Zalo running=" ui.IsRunning())
    } catch as err {
        Add("ZaloUIAdapter FAILED: " err.Message)
    }
} else {
    Add("ZaloUIAdapter SKIPPED (no config)")
}

report := StrJoin(results, "`n")
path := A_ScriptDir "\data\diag-startup.txt"
try {
    root := DetectAppRoot()
    path := root "\data\diag-startup.txt"
    EnsureDir(root "\data")
} catch {
    EnsureDir(A_ScriptDir "\data")
}
WriteTextFile(path, report)
MsgBox report "`n`nSaved: " path, "Startup diagnostic", "Iconi"
