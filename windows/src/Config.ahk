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
        this.Root := DetectAppRoot()
        this.IniPath := this.Root "\config\config.ini"
        examplePath := this.Root "\config\config.example.ini"

        if !FileExist(this.IniPath) {
            if !FileExist(examplePath)
                throw Error("Thiếu config\config.ini và config\config.example.ini")
            FileCopy examplePath, this.IniPath, false
        }

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
        ; Windows' IniRead API treats UTF-8-without-BOM as an ANSI file on
        ; some systems, corrupting Vietnamese and emoji output-group names.
        ; Keep one explicit UTF-8 decode and read values from it first.
        this._IniUtf8Text := ReadTextFile(ini)

        ; ── Zalo ──
        this.ExeName := this._Read(ini, "Zalo", "ExeName", "Zalo.exe")
        this.ZaloExePath := this._Read(ini, "Zalo", "ExePath", "")

        ; ── Paths ──
        this.DataDir := this._Resolve(this._Read(ini, "Paths", "DataDir", "data"))
        this.ListingsFile := this._Resolve(this._Read(ini, "Paths", "ListingsFile", "data\listings.json"))
        this.ListingsDir := this._Resolve(this._Read(ini, "Paths", "ListingsDir", "data\listings"))
        this.MediaDir := this._Resolve(this._Read(ini, "Paths", "MediaDir", "data\media"))
        this.QueueDir := this._Resolve(this._Read(ini, "Paths", "QueueDir", "data\queue"))
        this.QueueEventsFile := this._Resolve(this._Read(
            ini, "Paths", "QueueEventsFile", "data\queue\events.jsonl"))
        this.QueueSnapshotFile := this._Resolve(this._Read(
            ini, "Paths", "QueueSnapshotFile", "data\queue\snapshot.json"))
        this.QueueLogFile := this._Resolve(this._Read(
            ini, "Paths", "QueueLogFile", "data\queue\publish.log"))
        this.AccessLogFile := this._Resolve(this._Read(ini, "Paths", "AccessLogFile", "data\access_log.json"))
        this.HarvestStateFile := this._Resolve(this._Read(ini, "Paths", "HarvestStateFile", "data\harvest_state.json"))
        this.HarvestStateDir := this._Resolve(this._Read(
            ini, "Paths", "HarvestStateDir", "data\harvest_state"))
        EnsureDir(this.DataDir)
        EnsureDir(this.ListingsDir)
        EnsureDir(this.MediaDir)
        EnsureDir(this.QueueDir)
        EnsureDir(this.HarvestStateDir)

        ; ── Source groups from operator-selected CSV/XLSX + output groups ──
        this.OutputGroupNames := this._PipeList(this._Read(
            ini, "Groups", "OutputGroups",
            'Giỏ hàng cao thiên ⏏️ 6tr Phú Nhuận Bình Thạnh'
            . '|Giỏ hàng cao thiên ⬇️ 5tr9 Phú Nhuận Bình Thạnh'
            . '|Giỏ Hàng "Quận Ngoại Thành" Cao Thiên'
            . '|Giỏ hàng Quận số Cao Thiên'
            . '|Giỏ hàng NNC Cao Thiên.'))
        this.SourceGroupFilePath := this._ResolveOptional(this._Read(
            ini, "Groups", "SourceFile", ""))
        this.SourceGroupPromptOnStart := this._Bool(
            ini, "Groups", "PromptSourceFileOnStart", true)
        this.SourceGroupSheet := this._Read(
            ini, "Groups", "SourceSheet", "")
        this.SourceGroupColumn := this._Read(
            ini, "Groups", "SourceColumn", "group_name")
        this.SourceGroupReloadEachCycle := this._Bool(
            ini, "Groups", "ReloadSourceFileEachCycle", true)
        this.GroupListTabHotkey := this._Read(
            ini, "Groups", "ListTabHotkey", "!3")
        this.GroupDiscoveryMode := StrLower(this._Read(
            ini, "Groups", "DiscoveryMode", "hybrid"))
        this.GroupListSettleMs := Max(500,
            this._Int(ini, "Groups", "ListSettleMs", 1500))
        this.GroupListScanPages := Max(1,
            this._Int(ini, "Groups", "ListScanPages", 30))
        this.GroupRefreshEveryCycles := Max(1,
            this._Int(ini, "Groups", "RefreshEveryCycles", 12))
        this.GroupListPaneClickXRatio := this._Float(
            ini, "Groups", "ListPaneClickX", 0.20)
        this.GroupListPaneClickYRatio := this._Float(
            ini, "Groups", "ListPaneClickY", 0.42)
        this.GroupCommunityTabClickXRatio := this._Float(
            ini, "Groups", "CommunityTabClickX", 0.28)
        this.GroupCommunityTabClickYRatio := this._Float(
            ini, "Groups", "CommunityTabClickY", 0.14)
        this.CaptureCommunities := this._Bool(
            ini, "Groups", "CaptureCommunities", true)
        this.GroupListScrollMode := StrLower(this._Read(
            ini, "Groups", "ListScrollMode", "wheel"))
        this.GroupListWheelSteps := Max(1,
            this._Int(ini, "Groups", "ListWheelSteps", 8))
        this.GroupListUsePaneClick := this._Bool(
            ini, "Groups", "ListUsePaneClick", false)
        this.UiUseRatioClicks := this._Bool(
            ini, "Groups", "UiUseRatioClicks", false)
        this.GroupAccessibilityDepth := Max(3,
            this._Int(ini, "Groups", "AccessibilityDepth", 18))
        this.GroupAccessibilityLeftRatio := this._Float(
            ini, "Groups", "AccessibilityLeftRatio", 0.52)
        this.PreferAccessibleConversationClick := this._Bool(
            ini, "Groups", "PreferAccessibleConversationClick", false)
        this.VerifyActiveConversation := this._Bool(
            ini, "Groups", "VerifyActiveConversation", true)
        this.GroupListManualFile := this._Resolve(this._Read(
            ini, "Groups", "ManualListFile", "config\groups-manual.txt"))
        this.GroupListIgnoredLabels := this._PipeList(this._Read(
            ini, "Groups", "IgnoredLabels", ""))
        this.GroupUnreadMarkerPattern := this._Read(
            ini, "Groups", "UnreadMarkerPattern",
            "i)(?:tin nhắn mới|tin chưa đọc|chưa đọc|unread|new messages?)")
        this.GroupListCaptureFile := this._Resolve(this._Read(
            ini, "Paths", "GroupListCaptureFile",
            "data\zalo-groups-capture.txt"))

        ; ── Blocklist table ──
        this.BlocklistXlsx := this._Resolve(this._Read(ini, "Groups", "BlocklistXlsx", "config\zalo-groups.xlsx"))
        this.BlocklistSheet := this._Read(ini, "Groups", "BlocklistSheet", "Blocklist")
        this.BlocklistCsv := this._Resolve(this._Read(ini, "Groups", "BlocklistCsv", "config\blocklist.csv"))

        ; ── Capture ──
        this.CaptureMethod := StrLower(this._Read(
            ini, "Capture", "Method", "selectall"))
        this.CaptureAccessibilityFallback := StrLower(this._Read(
            ini, "Capture", "AccessibilityFallback", "selectall"))
        this.ListingStartPattern := this._Read(ini, "Capture", "ListingStartPattern", "")
        this.ImageMarkerPattern := this._Read(ini, "Capture", "ImageMarkerPattern", "")
        this.MaxMessagesPerGroup := this._Int(ini, "Capture", "MaxMessagesPerGroup", 50)
        this.RequiredFields := this._List(this._Read(ini, "Capture", "RequiredFields", "address,price,owner_phone"))

        ; ── Output ──
        this.Separator := this._Read(ini, "Output", "Separator", "------------{group}------------")
        this.MaxMessageChars := this._Int(ini, "Output", "MaxMessageChars", 1800)
        this.MaskPhone := this._Bool(ini, "Output", "MaskPhone", true)
        this.PhoneHint := this._Read(ini, "Output", "PhoneHint", 'Nhắn bot "SĐT {room_code}" để lấy số')
        this.OneMessagePerListing := this._Bool(ini, "Output", "OneMessagePerListing", false)
        this.ListingsPerMessage := Max(1, this._Int(ini, "Output", "ListingsPerMessage", 5))
        this.ListingSeparator := this._Read(ini, "Output", "ListingSeparator", "=======================")
        this.IncludeGroupHeader := this._Bool(ini, "Output", "IncludeGroupHeader", false)

        ; ── Images ──
        this.ImageStrategy := StrLower(this._Read(ini, "Images", "Strategy", "clipboard"))
        this.ForwardHotkey := this._Read(ini, "Images", "ForwardHotkey", "^q")
        this.ImagesBeforeText := this._Bool(ini, "Images", "ImagesBeforeText", true)
        this.RelayImagesPerListing := this._Bool(ini, "Images", "RelayPerListing", true)
        this.RelayImagesPauseMs := this._Int(ini, "Images", "RelayPauseMs", 5000)
        this.ImageCopyHotkey := this._Read(ini, "Images", "ImageCopyHotkey", "^c")
        this.MediaRequired := this._Bool(ini, "Images", "MediaRequired", true)
        this.MediaCapturePauseMs := this._Int(ini, "Images", "MediaCapturePauseMs", 5000)
        this.AutoCapture := this._Bool(ini, "Images", "AutoCapture", true)
        this.AutoCaptureAnchor := StrLower(
            this._Read(ini, "Images", "AutoCaptureAnchor", "room_code"))
        this.AutoCaptureMaxRetries := Max(0,
            this._Int(ini, "Images", "AutoCaptureMaxRetries", 2))
        this.AutoCaptureMode := StrLower(
            this._Read(ini, "Images", "AutoCaptureMode", "accessibility"))
        this.AutoCaptureProbeImages := this._Bool(
            ini, "Images", "AutoCaptureProbeImages", true)
        this.AutoCaptureProbeMaxImages := Max(1,
            this._Int(ini, "Images", "AutoCaptureProbeMaxImages", 6))
        this.AutoCaptureReplaceUntrusted := this._Bool(
            ini, "Images", "AutoCaptureReplaceUntrusted", true)
        this.AutoCaptureRepairPerCycle := Max(0,
            this._Int(ini, "Images", "AutoCaptureRepairPerCycle", 3))
        this.ImageCandidateMaxDistancePx := Max(100,
            this._Int(ini, "Images", "ImageCandidateMaxDistancePx", 900))
        this.ImageCandidateDirection := StrLower(this._Read(
            ini, "Images", "ImageCandidateDirection", "above"))
        this.ImageCandidateMinWidthPx := Max(16,
            this._Int(ini, "Images", "ImageCandidateMinWidthPx", 60))
        this.ImageCandidateMinHeightPx := Max(16,
            this._Int(ini, "Images", "ImageCandidateMinHeightPx", 60))
        this.ImageViewerSettleMs := Max(200,
            this._Int(ini, "Images", "ImageViewerSettleMs", 700))
        this.ImageContextCopyKey := this._Read(
            ini, "Images", "ImageContextCopyKey", "c")
        this.ImageSelectMode := StrLower(
            this._Read(ini, "Images", "ImageSelectMode", "shift_up"))
        this.ImageSelectStepPx := Max(40,
            this._Int(ini, "Images", "ImageSelectStepPx", 80))
        this.FindInChatHotkey := this._Read(ini, "Images", "FindInChatHotkey", "^f")

        ; ── Relay mode ──
        ; Text-only is the safe/default workflow. It deliberately overrides old
        ; runtime config.ini files that still have AutoCapture/MediaRequired=1,
        ; so copied listing text can never be used as an in-chat search query.
        this.TextOnlyRelay := this._Bool(
            ini, "Relay", "TextOnly", true)
        if this.TextOnlyRelay {
            this.MediaRequired := false
            this.AutoCapture := false
            this.AutoCaptureRepairPerCycle := 0
        }

        ; ── Watch loop ──
        this.WatchIntervalMs := Max(60000,
            this._Int(ini, "Watch", "IntervalMs", 300000))
        this.WatchDrainQueueEachCycle := this._Bool(ini, "Watch", "DrainQueueEachCycle", true)
        this.WatchOnlyUnreadAfterFirstCycle := this._Bool(
            ini, "Watch", "OnlyUnreadAfterFirstCycle", true)
        this.WatchBypassSessionCooldown := this._Bool(
            ini, "Watch", "BypassSessionCooldown", true)
        this.WatchStopOnUncertain := this._Bool(ini, "Watch", "StopOnUncertain", true)
        this.WatchActiveHoursStart := this._Read(ini, "Watch", "ActiveHoursStart", "")
        this.WatchActiveHoursEnd := this._Read(ini, "Watch", "ActiveHoursEnd", "")

        ; ── Startup / auto-run ──
        this.StartupAutoRunWatch := this._Bool(ini, "Startup", "AutoRunWatch", true)
        this.StartupWaitForZaloSeconds := Max(5,
            this._Int(ini, "Startup", "WaitForZaloSeconds", 120))
        this.StartupLaunchZaloIfMissing := this._Bool(
            ini, "Startup", "LaunchZaloIfMissing", true)
        this.StartupMaximizeZalo := this._Bool(ini, "Startup", "MaximizeZalo", false)
        this.StartupDelayMs := Max(0,
            this._Int(ini, "Startup", "StartupDelayMs", 3000))
        this.StartupRequireAdmin := this._Bool(ini, "Startup", "RequireAdmin", false)
        this.StartupEnableHotkeys := this._Bool(ini, "Startup", "EnableHotkeys", false)
        this.StartupShowStopButton := this._Bool(
            ini, "Startup", "ShowStopButton", true)

        ; ── Timing ──
        this.SearchDelayMs := this._Int(ini, "Timing", "SearchDelayMs", 400)
        this.OpenChatDelayMs := this._Int(ini, "Timing", "OpenChatDelayMs", 800)
        this.PasteDelayMs := this._Int(ini, "Timing", "PasteDelayMs", 200)
        this.SendDelayMs := this._Int(ini, "Timing", "SendDelayMs", 300)
        this.BetweenMessagesMs := this._Int(ini, "Timing", "BetweenMessagesMs", 900)
        this.BetweenGroupsMs := this._Int(ini, "Timing", "BetweenGroupsMs", 1200)
        this.ForwardDialogMs := this._Int(ini, "Timing", "ForwardDialogMs", 900)
        this.ClipWaitSeconds := this._Int(ini, "Timing", "ClipWaitSeconds", 2)
        this.CaptureSettleMs := this._Int(ini, "Timing", "CaptureSettleMs", 600)
        this.AfterPublishRecheckMs := this._Int(ini, "Timing", "AfterPublishRecheckMs", 800)

        ; ── Batch harvest/publish ──
        this.BatchSize := Max(1, this._Int(ini, "Batch", "Size", 5))
        this.RecheckAfterPublish := this._Bool(ini, "Batch", "RecheckAfterPublish", true)
        this.BetweenBatchesMs := this._Int(ini, "Batch", "BetweenBatchesMs", 2000)

        ; ── Incremental harvest scheduler ──
        this.HarvestInitialFullScan := this._Bool(
            ini, "Harvest", "InitialFullScan", true)
        this.HarvestMaxGroupsPerCycle := Max(1,
            this._Int(ini, "Harvest", "MaxGroupsPerCycle", 50))
        this.HarvestAuditGroupsPerCycle := Max(0,
            this._Int(ini, "Harvest", "AuditGroupsPerCycle", 10))
        this.HarvestPublishAfterGroups := Max(1,
            this._Int(ini, "Harvest", "PublishAfterGroups", 1))
        this.HarvestSaveStateEachGroup := this._Bool(
            ini, "Harvest", "SaveStateEachGroup", true)

        ; ── Durable publish queue ──
        this.LeaseSize := this.OneMessagePerListing
            ? 1
            : Max(1, this._Int(ini, "PublishQueue", "LeaseSize", 5))
        this.LeaseTimeoutMs := Max(60000,
            this._Int(ini, "PublishQueue", "LeaseTimeoutMs", 7200000))
        this.MaxPublishAttempts := Max(1,
            this._Int(ini, "PublishQueue", "MaxAttempts", 3))
        this.RetryBackoffSeconds := Max(1,
            this._Int(ini, "PublishQueue", "RetryBackoffSeconds", 300))
        this.QueueCompactEvery := Max(0,
            this._Int(ini, "PublishQueue", "CompactEveryEvents", 250))
        this.MaxBatchesPerSession := Max(1,
            this._Int(ini, "PublishQueue", "MaxBatchesPerSession", 20))
        this.SessionCooldownMs := Max(0,
            this._Int(ini, "PublishQueue", "SessionCooldownMs", 300000))
        this.ListingTtlDays := Max(0,
            this._Int(ini, "PublishQueue", "ListingTtlDays", 30))
        this.PublishActiveHoursStart := this._Read(
            ini, "PublishQueue", "ActiveHoursStart", "")
        this.PublishActiveHoursEnd := this._Read(
            ini, "PublishQueue", "ActiveHoursEnd", "")

        ; ── Rate limit / cycle budget ──
        this.PublishBatchesPerWatchCycle := Max(1,
            this._Int(ini, "RateLimit", "MaxBatchesPerWatchCycle", 10))
        this.PublishSendDelayMinMs := Max(0,
            this._Int(ini, "RateLimit", "SendDelayMinMs", 3000))
        this.PublishSendDelayMaxMs := Max(
            this.PublishSendDelayMinMs,
            this._Int(ini, "RateLimit", "SendDelayMaxMs", 7000))
        this.PublishGroupDelayMinMs := Max(0,
            this._Int(ini, "RateLimit", "OutputGroupDelayMinMs", 5000))
        this.PublishGroupDelayMaxMs := Max(
            this.PublishGroupDelayMinMs,
            this._Int(ini, "RateLimit", "OutputGroupDelayMaxMs", 10000))
        this.HarvestGroupDelayMinMs := Max(0,
            this._Int(ini, "RateLimit", "HarvestGroupDelayMinMs", 800))
        this.HarvestGroupDelayMaxMs := Max(
            this.HarvestGroupDelayMinMs,
            this._Int(ini, "RateLimit", "HarvestGroupDelayMaxMs", 1600))

        ; ── State ──
        this.MaxSeenHashes := Max(100,
            this._Int(ini, "State", "MaxSeenHashes", 2000))

        ; ── Hotkeys ──
        this.HotkeyForward := this._Read(ini, "Hotkeys", "ForwardListing", "^+b")
        this.HotkeyRelease := this._Read(ini, "Hotkeys", "ReleasePhone", "^+p")
        this.HotkeyHarvest := this._Read(ini, "Hotkeys", "HarvestAll", "^+h")
        this.HotkeyPublish := this._Read(ini, "Hotkeys", "PublishMain", "^+g")
        this.HotkeyCycle := this._Read(ini, "Hotkeys", "HarvestAndPublish", "^+j")
        this.HotkeyRelayImages := this._Read(ini, "Hotkeys", "RelayImages", "^+i")
        this.HotkeyArchiveMedia := this._Read(ini, "Hotkeys", "ArchiveMedia", "^+m")
        this.HotkeyPausePublish := this._Read(ini, "Hotkeys", "PausePublish", "^+o")
        this.HotkeyStopPublish := this._Read(ini, "Hotkeys", "StopPublish", "^+k")
        this.HotkeyResolveUncertain := this._Read(
            ini, "Hotkeys", "ResolveUncertain", "^+u")
        this.HotkeyReload := this._Read(ini, "Hotkeys", "ReloadConfig", "^+r")
        this.HotkeyToggleWatch := this._Read(ini, "Hotkeys", "ToggleWatch", "^+w")
        return this
    }

    _Read(ini, section, key, default) {
        missing := Chr(0xE000) "__MISSING_INI_VALUE__"
        if this.HasProp("_IniUtf8Text") {
            decoded := AppConfig.ReadIniValue(
                this._IniUtf8Text, section, key, missing)
            if decoded != missing
                return decoded
        }
        value := IniRead(ini, section, key, default)
        return Trim(value)
    }

    static ReadIniValue(text, section, key, default := "") {
        activeSection := ""
        for rawLine in StrSplit(NormalizeNewlines(text), "`n") {
            line := Trim(rawLine)
            if line = "" || SubStr(line, 1, 1) = ";"
                || SubStr(line, 1, 1) = "#"
                continue
            if RegExMatch(line, "^\[([^\]]+)\]$", &header) {
                activeSection := Trim(header[1])
                continue
            }
            if StrLower(activeSection) != StrLower(section)
                continue
            separator := InStr(line, "=")
            if !separator
                continue
            lineKey := Trim(SubStr(line, 1, separator - 1))
            if StrLower(lineKey) != StrLower(key)
                continue
            return Trim(SubStr(line, separator + 1))
        }
        return default
    }

    _Int(ini, section, key, default) {
        value := this._Read(ini, section, key, default)
        return IsInteger(value) ? Integer(value) : default
    }

    _Float(ini, section, key, default) {
        value := this._Read(ini, section, key, default)
        if IsNumber(value)
            return value + 0
        return default
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

    _PipeList(value) {
        items := []
        for part in StrSplit(value, "|") {
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

    _ResolveOptional(path) {
        return Trim(path) = "" ? "" : this._Resolve(path)
    }
}
