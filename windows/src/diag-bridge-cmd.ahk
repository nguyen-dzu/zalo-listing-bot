#Requires AutoHotkey v2.0
; One-shot bridge command while Bot.ahk is NOT running (uses same port).
#Include Util.ahk
#Include JSON.ahk
#Include Config.ahk
#Include WebBridge.ahk

cfg := AppConfig.Instance()
bridge := WebBridge(cfg)
bridge.Start()
if !bridge.WaitForRoles(15)
    throw Error("Tampermonkey chua ket noi tab Zalo Web.")

action := A_Args.Length ? A_Args[1] : "dump_dom"
params := Map()
if action = "navigate" && A_Args.Length >= 2
    params["group"] := A_Args[2]

try {
    result := bridge.RunCommand(action, params, 45000, "bot")
    out := JSON.stringify(result)
} catch as err {
    out := "ERROR: " err.Message
}

root := DetectAppRoot()
path := root "\data\diag-bridge-cmd.txt"
WriteTextFile(path, "action=" action "`n`n" out)
FileAppend out "`n", "*"
ExitApp 0
