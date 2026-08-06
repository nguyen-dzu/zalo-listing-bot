#Requires AutoHotkey v2.0
; Config.ahk — Singleton: every tunable value comes from config/config.ini

class AppConfig {
    static _instance := 0

    static Instance() {
        if !AppConfig._instance
            AppConfig._instance := AppConfig()
        return AppConfig._instance
    }

    __New() {
        this.Root := RegExReplace(A_ScriptDir, "\\[^\\]+$")
        this.IniPath := this.Root "\config\config.ini"
        examplePath := this.Root "\config\config.example.ini"

        if !FileExist(this.IniPath) {
            if !FileExist(examplePath)
                throw Error("Thiếu config\config.ini và config\config.example.ini")
            FileCopy examplePath, this.IniPath, false
        }

        this._SeedFromExample("config\groups.csv", "config\groups.example.csv")
        this._SeedFromExample("config\blocklist.csv", "config\blocklist.example.csv")

        this.Reload()
    }

    _SeedFromExample(relTarget, relSource) {
        target := this.Root "\" relTarget
        source := this.Root "\" relSource
        if !FileExist(target) && FileExist(source)
            FileCopy source, target, false
    }

    Reload() {
        ini := this.IniPath

        ; ── Zalo ──
        this.ExeName := this._Read(ini, "Zalo", "ExeName", "Zalo.exe")

        ; ── Paths ──
        this.DataDir := this._Resolve(this._Read(ini, "Paths", "DataDir", "data"))
        this.ListingsFile := this._Resolve(this._Read(ini, "Paths", "ListingsFile", "data\listings.json"))
        this.AccessLogFile := this._Resolve(this._Read(ini, "Paths", "AccessLogFile", "data\access_log.json"))
        this.HarvestStateFile := this._Resolve(this._Read(ini, "Paths", "HarvestStateFile", "data\harvest_state.json"))
        EnsureDir(this.DataDir)

        ; ── Group + blocklist tables ──
        this.GroupsXlsx := this._Resolve(this._Read(ini, "Groups", "GroupsXlsx", "config\zalo-groups.xlsx"))
        this.GroupsSheet := this._Read(ini, "Groups", "GroupsSheet", "Groups")
        this.GroupsCsv := this._Resolve(this._Read(ini, "Groups", "GroupsCsv", "config\groups.csv"))
        this.BlocklistXlsx := this._Resolve(this._Read(ini, "Groups", "BlocklistXlsx", "config\zalo-groups.xlsx"))
        this.BlocklistSheet := this._Read(ini, "Groups", "BlocklistSheet", "Blocklist")
        this.BlocklistCsv := this._Resolve(this._Read(ini, "Groups", "BlocklistCsv", "config\blocklist.csv"))

        ; ── Capture ──
        this.CaptureMethod := StrLower(this._Read(ini, "Capture", "Method", "manual"))
        this.ListingStartPattern := this._Read(ini, "Capture", "ListingStartPattern", "")
        this.ImageMarkerPattern := this._Read(ini, "Capture", "ImageMarkerPattern", "")
        this.MaxMessagesPerGroup := this._Int(ini, "Capture", "MaxMessagesPerGroup", 50)
        this.RequiredFields := this._List(this._Read(ini, "Capture", "RequiredFields", "address,price,owner_phone"))

        ; ── Output ──
        this.Separator := this._Read(ini, "Output", "Separator", "------------{group}------------")
        this.MaxMessageChars := this._Int(ini, "Output", "MaxMessageChars", 1800)
        this.MaskPhone := this._Bool(ini, "Output", "MaskPhone", true)
        this.PhoneHint := this._Read(ini, "Output", "PhoneHint", 'Nhắn bot "SĐT {room_code}" để lấy số')

        ; ── Images ──
        this.ImageStrategy := StrLower(this._Read(ini, "Images", "Strategy", "forward"))
        this.ForwardHotkey := this._Read(ini, "Images", "ForwardHotkey", "^q")

        ; ── Timing ──
        this.SearchDelayMs := this._Int(ini, "Timing", "SearchDelayMs", 400)
        this.OpenChatDelayMs := this._Int(ini, "Timing", "OpenChatDelayMs", 800)
        this.PasteDelayMs := this._Int(ini, "Timing", "PasteDelayMs", 200)
        this.SendDelayMs := this._Int(ini, "Timing", "SendDelayMs", 300)
        this.BetweenMessagesMs := this._Int(ini, "Timing", "BetweenMessagesMs", 900)
        this.BetweenGroupsMs := this._Int(ini, "Timing", "BetweenGroupsMs", 1200)
        this.ForwardDialogMs := this._Int(ini, "Timing", "ForwardDialogMs", 900)
        this.ClipWaitSeconds := this._Int(ini, "Timing", "ClipWaitSeconds", 2)

        ; ── State ──
        this.MaxSeenHashes := this._Int(ini, "State", "MaxSeenHashes", 500)

        ; ── Hotkeys ──
        this.HotkeyForward := this._Read(ini, "Hotkeys", "ForwardListing", "^+b")
        this.HotkeyRelease := this._Read(ini, "Hotkeys", "ReleasePhone", "^+p")
        this.HotkeyHarvest := this._Read(ini, "Hotkeys", "HarvestAll", "^+h")
        this.HotkeyPublish := this._Read(ini, "Hotkeys", "PublishMain", "^+g")
        this.HotkeyCycle := this._Read(ini, "Hotkeys", "HarvestAndPublish", "^+j")
        this.HotkeyRelayImages := this._Read(ini, "Hotkeys", "RelayImages", "^+i")
        this.HotkeyReload := this._Read(ini, "Hotkeys", "ReloadConfig", "^+r")
        return this
    }

    _Read(ini, section, key, default) {
        value := IniRead(ini, section, key, default)
        return Trim(value)
    }

    _Int(ini, section, key, default) {
        value := this._Read(ini, section, key, default)
        return IsInteger(value) ? Integer(value) : default
    }

    _Bool(ini, section, key, default) {
        value := StrLower(this._Read(ini, section, key, default ? "1" : "0"))
        return value = "1" || value = "true" || value = "yes"
    }

    _List(value) {
        items := []
        for part in StrSplit(value, ",") {
            part := Trim(part)
            if part != ""
                items.Push(part)
        }
        return items
    }

    _Resolve(path) {
        if RegExMatch(path, "^[A-Za-z]:\\") || SubStr(path, 1, 2) = "\\"
            return path
        return this.Root "\" path
    }
}
