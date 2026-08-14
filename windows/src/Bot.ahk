#Requires AutoHotkey v2.0
#SingleInstance Force

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
#Include GroupActivity.ahk
#Include WebBridge.ahk
#Include ZaloUI.ahk
#Include MediaCapturer.ahk
#Include Harvester.ahk
#Include Publisher.ahk

; Admin + config path trước khi chạy (release: exe cạnh config/; dev: src/ + ../config).
DetectAppRootEarly(dir) {
    Loop 6 {
        if DirExist(dir "\config")
            return dir
        parent := RegExReplace(dir, "\\[^\\]+$")
        if parent = dir
            break
        dir := parent
    }
    return dir
}

Persistent

try {
    _startupRoot := DetectAppRootEarly(A_ScriptDir)
    _startupIni := _startupRoot "\config\config.ini"
    if !FileExist(_startupIni)
        _startupIni := _startupRoot "\config\config.example.ini"
    if FileExist(_startupIni) {
        _requireAdmin := Trim(IniRead(_startupIni, "Startup", "RequireAdmin", "0"))
        if (_requireAdmin = "1" || StrLower(_requireAdmin) = "true") && !A_IsAdmin {
            try Run('*RunAs "' A_ScriptFullPath '"')
            ExitApp()
        }
    }
} catch as err {
    LogStartupError("Admin preflight: " err.Message)
}

; ── Facade: one method per operator action ────────────────
class ListingBotService {
    __New(config) {
        this.config := config
        this.operation := ""
        this.watchRunning := false
        this.watchStopRequested := false
        this.emergencyStopped := false
        this.autoStartRetryPending := false
        this._Build()
    }

    _Build() {
        ConfigureDiagnosticLog(
            this.config.DiagnosticLogEnabled,
            this.config.DiagnosticLogFile)
        this.registry := GroupRegistry(this.config)
        this.groupsDiscovered := false
        this.blockList := BlockList(this.config)
        this.state := HarvestStateStore(this.config)
        this.queue := PublishQueueStore(this.config)
        this.media := ListingMediaStore(this.config)
        this.repo := ListingRepository(this.config, this.queue)
        this._ReconcileMediaArchives()
        this.bridge := WebBridge(this.config)
        this.bridge.Start()
        this.bridge.OnEvent(ObjBindMethod(this, "_HandleBridgeEvent"))
        this.ui := ZaloUIAdapter(this.config, this.bridge)
        this.composer := MessageComposer(this.config)
        this.harvestScheduler := HarvestScheduler(this.config)
        this.lastGroupListRaw := ""
        this.mediaCapturer := ListingMediaCapturer(
            this.config, this.ui, this.media, this.queue)
        this.harvester := MessageHarvester(
            this.config, this.ui, this.registry, this.blockList,
            this.state, this.repo, this.mediaCapturer
        )
        this.publisher := DurableListingPublisher(
            this.config, this.ui, this.registry, this.composer,
            this.queue, this.repo, this.media
        )
    }

    _ReconcileMediaArchives() {
        for entry in this.queue.AllEntries() {
            if !this.media.HasMedia(entry["id"])
                continue
            if !this.media.IsTrusted(entry["id"]) {
                record := this.repo.Get(entry["id"])
                required := record
                    && record.Has("image_count")
                    && record["image_count"] > 0
                    && this.config.MediaRequired
                this.queue.InvalidateMedia(
                    entry["id"], "Legacy/unvalidated image cache ignored.", required)
                if this.config.AutoCaptureReplaceUntrusted
                    this.media.DeleteFor(entry["id"])
                continue
            }
            files := this.media.RelativePaths(entry["id"])
            metadata := this.media.MetadataFor(entry["id"])
            if this._MediaMetadataMatches(entry, metadata)
                continue
            this.queue.AttachMedia(
                entry["id"], files, metadata)
        }
    }

    _MediaMetadataMatches(entry, metadata) {
        if (!entry.Has("media_metadata")
            || entry["media_metadata"].Length != metadata.Length)
            return false
        for index, item in metadata {
            current := entry["media_metadata"][index]
            if (!current.Has("path") || !current.Has("size")
                || current["path"] != item["path"]
                || current["size"] != item["size"])
                return false
        }
        return true
    }

    Reload() {
        if this._RejectIfBusy("reload")
            return false
        if this.HasProp("bridge") && this.bridge
            this.bridge.Stop()
        sourceFile := this.config.SourceGroupFilePath
        this.config.Reload()
        this.config.SourceGroupFilePath := sourceFile
        this._Build()
        this._LoadSourceGroups()
        this._Notify("Đã nạp lại cấu hình",
            this.registry.SourceGroups().Length " nhóm nguồn, "
            . this.registry.MainGroups().Length " nhóm chính, "
            . this.blockList.rules.Length " từ khoá cấm")
    }

    ; Đọc tin mới từ mọi nhóm nguồn, lưu object xuống máy.
    HarvestAll() {
        if this._RejectIfBusy("harvest")
            return false
        try {
            this._EnsureGroupsDiscovered()
            summary := this.harvester.HarvestAll()
        } catch as err {
            return this._Notify("Lỗi thu thập", err.Message, 3)
        }

        message := Format(
            "Nhóm: {1} | Mới: {2} | Cấm: {3} | Trùng: {4} | Thiếu field: {5}`nẢnh OK: {6} | Ảnh lỗi: {7}",
            summary["groups"], summary["saved"], summary["blocked"],
            summary["duplicate"], summary["invalid"],
            summary["media_captured"], summary["media_failed"])
        if summary["errors"].Length
            message .= "`nLỗi: " StrJoin(summary["errors"], "; ")

        this._Notify("Thu thập xong", message, summary["errors"].Length ? 2 : 1)
        return summary
    }

    ; Drain a bounded number of durable one-room leases.
    PublishToMain() {
        return this.publisher.RunSession()
    }

    PublishToMainNotify() {
        before := this.publisher.Status()
        if !before["remaining_batches"] && before["media_pending"]
            return this._Notify("Đang chờ archive ảnh",
                before["media_pending"] " listing ở trạng thái media_pending.", 2)
        if !before["remaining_batches"]
            return this._Notify("Queue trống",
                "Không có listing ready/retry_wait để gửi.", 2)

        try {
            summary := this.PublishToMain()
        } catch as err {
            return this._Notify("Lỗi gửi", err.Message, 3)
        }

        after := this.publisher.Status()
        message := Format(
            "Batch: {1} | Phòng: {2} | Message: {3} | Lỗi: {4}`nCòn lại: {5} batch",
            summary["batches"], summary["rooms"], summary["messages"],
            summary["failed"], after["remaining_batches"])
        this._Notify("Publish session xong", message,
            summary["failed"] ? 2 : 1)
        return summary
    }

    HarvestAndPublish() {
        if this._RejectIfBusy("harvest")
            return false
        try {
            this._EnsureGroupsDiscovered()
            harvest := this.harvester.HarvestAll()
            publish := this.publisher.RunSession()
        } catch as err {
            return this._Notify("Lỗi batch", err.Message, 3)
        }

        message := Format(
            "Nhóm: {1} | Mới: {2} | Cấm: {3} | Trùng: {4} | Ảnh OK: {5}`nPublish: {6} batch / {7} phòng",
            harvest["groups"], harvest["saved"], harvest["blocked"],
            harvest["duplicate"], harvest["media_captured"],
            publish["batches"], publish["rooms"])
        errors := []
        for err in harvest["errors"]
            errors.Push(err)
        for err in publish["errors"]
            errors.Push(err)
        if errors.Length
            message .= "`nLỗi: " StrJoin(errors, "; ")

        icon := errors.Length ? 2 : (harvest["saved"] || publish["rooms"] ? 1 : 2)
        this._Notify("Batch xong", message, icon)
        return Map("harvest", harvest, "publish", publish)
    }

    ; Ảnh phải tới nhóm chính trước phần text: chọn tin ảnh trong nhóm nguồn rồi bấm hotkey này.
    RelayImages() {
        if this._RejectIfBusy("relay ảnh")
            return false
        mainGroups := this.registry.MainGroups()
        if !mainGroups.Length
            return this._Notify("Thiếu nhóm chính", "Chưa khai báo nhóm type=main.", 3)
        if !this.ui.CopyImageFromSelection()
            return this._Notify("Lỗi copy ảnh", "Clipboard không có ảnh. Chọn ảnh trên Zalo Web trước.", 3)

        for group in mainGroups {
            try {
                this.ui.RelayClipboardImage(group["group_name"])
            } catch as err {
                return this._Notify("Lỗi chuyển ảnh", group["group_name"] ": " err.Message, 3)
            }
            Sleep this.config.BetweenGroupsMs
        }
        this._Notify("Đã chuyển ảnh", mainGroups.Length " nhóm chính", 1)
    }

    ; Luồng thủ công cũ: bôi đen 1 tin admin rồi chuyển ngay sang nhóm chính.
    ForwardListingFromClipboard() {
        if this._RejectIfBusy("forward listing")
            return false
        text := this._CopySelection()
        if text = ""
            return this._Notify("Lỗi", "Không copy được tin. Hãy bôi đen tin trước.", 3)

        keyword := this.blockList.Match(text)
        if keyword != ""
            return this._Notify("Tin bị chặn", "Chứa từ khoá cấm: " keyword, 2)

        listing := ListingParser.Parse(text, this.config.ImageMarkerPattern)
        errors := ListingParser.Validate(listing, this.config.RequiredFields)
        if errors.Length
            return this._Notify("Thiếu dữ liệu", StrJoin(errors, "`n"), 3)

        record := this.repo.SaveListing(listing, "manual", FnvHash(text))
        chunk := this.composer.ComposeOne(record)

        for group in this.registry.MainGroups() {
            try {
                this.ui.SendTextChunks(group["group_name"], [chunk])
            } catch as err {
                return this._Notify("Lỗi Zalo", err.Message, 3)
            }
        }

        this.repo.MarkPublished([record["id"]])
        this._Notify("Đã chuyển tin", listing["room_code"] != "" ? listing["room_code"] : listing["address"], 1)
    }

    ReleasePhoneFromClipboard() {
        if this._RejectIfBusy("cấp số điện thoại")
            return false
        text := this._CopySelection()
        if text = ""
            return

        roomCode := ListingParser.ParsePhoneRequest(text)
        if roomCode = ""
            return this._Notify("Không nhận diện", 'Dùng: SĐT P001 hoặc "P001"', 3)

        listing := this.repo.GetByRoomCode(roomCode)
        if !listing
            return this._Notify("Không tìm thấy", "Mã phòng: " roomCode, 3)

        this.repo.LogPhoneAccess(roomCode, text)
        try {
            this.ui.PasteToActiveChat("📞 Số chủ [" roomCode "]: " listing["owner_phone"])
        } catch as err {
            return this._Notify("Lỗi Zalo", err.Message, 3)
        }
        this._Notify("Đã cấp SĐT", roomCode, 1)
    }

    ArchiveMedia() {
        if this._RejectIfBusy("archive ảnh")
            return false
        prompt := InputBox(
            "Nhập mã phòng đã harvest (ví dụ P102).`n"
            . "Sau khi bấm OK, chọn toàn bộ ảnh của phòng trong Zalo.",
            "Archive ảnh phòng", "w420 h150")
        if prompt.Result != "OK" || Trim(prompt.Value) = ""
            return false

        roomCode := ListingParser.ParsePhoneRequest(Trim(prompt.Value))
        if roomCode = ""
            return this._Notify("Mã phòng sai", prompt.Value, 3)
        record := this.repo.GetByRoomCode(roomCode)
        if !record
            return this._Notify("Không tìm thấy", "Mã phòng: " roomCode, 3)

        existing := this.media.FilesFor(record["id"])
        appendArchive := false
        if existing.Length {
            mode := MsgBox(
                "Phòng " roomCode " đã có " existing.Length " archive.`n"
                . "Yes = thay toàn bộ bằng selection mới`n"
                . "No = thêm selection thành archive tiếp theo`n"
                . "Cancel = hủy",
                "Archive ảnh phòng", "YesNoCancel Icon?")
            if mode = "Cancel"
                return false
            if mode = "No"
                appendArchive := true
        }

        this._Notify("Chọn ảnh",
            "Chọn/multi-select ảnh phòng " roomCode
            . " trong " Round(this.config.MediaCapturePauseMs / 1000) " giây.", 1)
        Sleep this.config.MediaCapturePauseMs

        try {
            files := this.mediaCapturer.ArchiveFromSelection(record, appendArchive)
        } catch as err {
            return this._Notify("Archive ảnh lỗi", err.Message, 3)
        }

        this._Notify("Đã archive ảnh",
            roomCode " — " files " bundle, sẵn sàng vào queue.", 1)
        return true
    }

    ToggleWatch() {
        if this.watchRunning {
            this.watchStopRequested := true
            this._Notify("Đang dừng watch",
                "Vòng watch hiện tại sẽ kết thúc sau bước an toàn.", 2)
            return false
        }
        return this.RunExclusive("watch", ObjBindMethod(this, "RunWatchLoop"))
    }

    ; Tự khởi động sau khi script load (Startup folder hoặc mở Bot.ahk thủ công).
    AutoStart() {
        this.autoStartRetryPending := false
        if !this.config.StartupAutoRunWatch
            return false
        if this.emergencyStopped
            return false
        if this.watchRunning || this.operation != ""
            return false
        try {
            this._WaitForZaloReady()
            if this.config.StartupDelayMs > 0
                Sleep this.config.StartupDelayMs
            this._Notify("Auto-start",
                "Zalo Web (1 tab) sẵn sàng — bật watch loop tự động.", 1)
            ; #region agent log
            AgentDebugLog("Bot.ahk:AutoStart", "auto_start_ok", Map(
                "sources", this.registry.SourceGroups().Length), "H1")
            ; #endregion
            return this.RunExclusive("watch", ObjBindMethod(this, "RunWatchLoop"))
        } catch as err {
            ; #region agent log
            AgentDebugLog("Bot.ahk:AutoStart", "auto_start_fail", Map(
                "error", err.Message), "H1")
            ; #endregion
            transient := InStr(err.Message, "Chưa kết nối")
                || InStr(err.Message, "Tampermonkey")
                || InStr(err.Message, "Chrome/Zalo Web không mở")
            if transient && !this.emergencyStopped {
                this._Notify("Đang chờ Zalo Web",
                    err.Message "`nBot sẽ tự thử lại sau 3 giây.", 2)
                if !this.autoStartRetryPending {
                    this.autoStartRetryPending := true
                    SetTimer(ObjBindMethod(this, "AutoStart"), -3000)
                }
                return false
            }
            this._Notify("Auto-start lỗi", err.Message, 3)
            return false
        }
    }

    _HandleBridgeEvent(payload) {
        if !IsObject(payload) || !payload.Has("type") || payload["type"] != "message"
            return
        group := payload.Has("group") ? payload["group"] : ""
        text := payload.Has("text") ? payload["text"] : ""
        if group = "" || Trim(text) = ""
            return
        if this._IsOutputGroupName(group)
            return
        ; Image capture needs a follow-up bridge command and must not run inside
        ; the HTTP event handler. Leave image posts unseen so the scheduled scan
        ; processes and archives them through the normal Harvester path.
        hasImages := (payload.Has("hasImage") && payload["hasImage"])
            || (payload.Has("images") && payload["images"].Length > 0)
        if hasImages
            return
        hash := payload.Has("hash") ? payload["hash"] : FnvHash(text)
        if this.state.IsSeen(group, hash)
            return

        keyword := this.blockList.Match(text)
        if keyword != "" {
            this.state.MarkSeen(group, hash)
            return
        }

        listing := ListingParser.Parse(text, this.config.ImageMarkerPattern)
        if ListingParser.Validate(listing, this.config.RequiredFields).Length {
            this.state.MarkSeen(group, hash)
            return
        }

        this.repo.SaveListing(listing, group, hash)
        this.state.MarkSeen(group, hash)
        this.state.Save()
    }

    _IsOutputGroupName(name) {
        actual := StrLower(Trim(name))
        if actual = ""
            return false
        for group in this.registry.MainGroups() {
            expected := StrLower(Trim(group["group_name"]))
            if expected != "" && (InStr(actual, expected) || InStr(expected, actual))
                return true
        }
        return false
    }

    _WaitForZaloReady() {
        exe := this.config.BrowserExeName
        timeout := this.config.StartupWaitForBrowserSeconds
        if !this.bridge
            throw Error("WebBridge chưa khởi tạo.")
        if !this.bridge.running
            this.bridge.Start()
        if this.config.StartupLaunchBrowserIfMissing
            this._EnsureBrowserWindows()
        if !WinWait("ahk_exe " exe,, timeout)
            throw Error("Chrome/Zalo Web không mở sau " timeout " giây.")
        ; Bring Zalo to the foreground before waiting for userscript timers.
        ; Chrome throttles background-tab intervals, which can make registration
        ; and command polling appear disconnected during startup.
        this.ui.Activate()
        this._PrepareBrowserWindow()
        this._PingWebBridge(timeout)
        return true
    }

    _EnsureBrowserWindows() {
        exe := this.config.BrowserExeName
        path := this._ResolveChromePath()
        title := this.config.WebWindowTitle
        if WinExist(title " ahk_exe " exe)
            return
        ; The Zalo tab can exist before Tampermonkey adds [ZaloBot].
        if WinExist("Zalo ahk_exe " exe)
            return
        if path = ""
            throw Error(
                "Không tìm thấy chrome.exe.`n"
                . "Điền [ZaloWeb] ChromePath trong config.ini.`n"
                . "Không mở Zalo bằng trình duyệt mặc định (Cốc Cốc).")
        ; Always launch through the configured Chrome executable. Existing
        ; unrelated Chrome windows must not prevent opening the required URL.
        Run Format('"{1}" --new-window "{2}"', path, this.config.WebChatUrl)
        Sleep 800
    }

    _PingWebBridge(timeoutSeconds := 30) {
        this.bridge.WaitForRoles(timeoutSeconds)
        pingTimeoutMs := Min(timeoutSeconds * 1000, 8000)
        try {
            ping := this.bridge.RunCommand("ping", Map(), pingTimeoutMs, "bot")
            if (ping is Map) && ping.Has("role") && ping["role"] = "bot"
                return true
        } catch {
        }
        throw Error(
            "Tampermonkey userscript chưa kết nối tab Zalo Web.`n"
            . "Mở đúng 1 tab https://chat.zalo.me/#bot và bật script v4.")
    }

    _ResolveChromePath() {
        if this.config.WebChromePath != "" && FileExist(this.config.WebChromePath)
            return this.config.WebChromePath
        candidates := [
            EnvGet("ProgramFiles") "\Google\Chrome\Application\chrome.exe",
            EnvGet("ProgramFiles(x86)") "\Google\Chrome\Application\chrome.exe",
            EnvGet("LocalAppData") "\Google\Chrome\Application\chrome.exe"
        ]
        for path in candidates {
            if path != "" && FileExist(path)
                return path
        }
        return ""
    }

    _EnsureGroupsDiscovered() {
        if !this.groupsDiscovered
            return this._LoadSourceGroups()
        return true
    }

    _LoadSourceGroups() {
        path := this.config.SourceGroupFilePath
        if path = ""
            throw Error("Chua chon file CSV/Excel nhom input.")
        names := SourceGroupFile.LoadNames(
            path, this.config.SourceGroupSheet,
            this.config.SourceGroupColumn)
        count := this.registry.SetSourceNames(names, path)
        sources := this.registry.SourceGroups().Length
        if !count {
            throw Error("File input khong co nhom nao: " path)
        }
        if !sources {
            throw Error(
                "Doc duoc " count " dong nhung 0 nhom nguon (tat ca trung output?).`n"
                . "Kiem tra [Groups] OutputGroups trong config.ini.`n"
                . "File: " path)
        }
        this.groupsDiscovered := true
        this._Notify("Da nap file nhom input",
            count " tong | " sources " input | "
            . this.registry.MainGroups().Length " output", 1)
        return true
    }

    _PrepareBrowserWindow() {
        try DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
        this.ui.EnsureWindowState()
        Sleep 500
    }

    RunWatchLoop() {
        if this.emergencyStopped
            return false
        this.watchRunning := true
        this.watchStopRequested := false
        cycles := 0
        this._Notify("Watch 24/7 bật",
            "Hết danh sách nhóm nguồn thì quay lại từ đầu. Nghỉ "
            . Round(this.config.WatchIntervalMs / 60000) " phút giữa mỗi vòng."
            . (this.config.StartupEnableHotkeys
                ? " " this.config.HotkeyToggleWatch " tắt."
                : " " this.config.HotkeyStopPublish " dừng khẩn cấp."), 1)

        try {
            Loop {
                if this.watchStopRequested
                    break
                if !this._WithinWatchHours() {
                    this._WatchSleep(60000)
                    continue
                }

                cycles++
                try {
                    if (this.config.SourceGroupReloadEachCycle
                        || !this.groupsDiscovered)
                        this._LoadSourceGroups()
                    sources := this.registry.SourceGroups()
                    ; #region agent log
                    AgentDebugLog("Bot.ahk:RunWatchLoop", "watch_cycle_start", Map(
                        "cycle", cycles, "sourceCount", sources.Length), "H1")
                    ; #endregion
                    unreadNames := []
                    try unreadNames := this.ui.FindUnreadSidebarGroups(sources)
                    catch {
                    }
                    plan := this.harvestScheduler.BuildContinuousPlan(
                        sources, unreadNames)
                    this._Notify("Watch vòng " cycles " bắt đầu",
                        plan["groups"].Length " nhóm nguồn"
                        . (plan["unread"] ? " | unread: " plan["unread"] : "")
                        . "`nHết vòng sẽ lặp lại từ đầu.", 1)
                    this.watchPublishBatchesRemaining :=
                        this.config.PublishBatchesPerWatchCycle
                    harvest := this.harvester.HarvestGroups(
                        plan["groups"], ObjBindMethod(this, "_AfterWatchGroup"))
                    mediaRepair := this.mediaCapturer.RepairPending(
                        this.repo, this.config.AutoCaptureRepairPerCycle)
                } catch as err {
                    this._Notify("Watch harvest lỗi", err.Message, 3)
                    if this.watchStopRequested
                        break
                    this._WatchSleep(this.config.WatchIntervalMs)
                    continue
                }

                if this.watchStopRequested
                    break

                if this.config.WatchDrainQueueEachCycle
                    this._WatchPublishAvailable(
                        this.watchPublishBatchesRemaining)

                if this.watchStopRequested
                    break

                this._Notify("Watch vòng " cycles " xong — lặp lại",
                    Format("{1}: {2} nhóm | unread: {3}`nMới: {4} | Ảnh OK: {5} | sửa cache: {6} | lỗi: {7}`nNghỉ {8} phút rồi quét lại từ đầu.",
                        plan["mode"], plan["groups"].Length, plan["unread"],
                        harvest["saved"], harvest["media_captured"],
                        mediaRepair["captured"],
                        harvest["media_failed"] + mediaRepair["failed"],
                        Round(this.config.WatchIntervalMs / 60000)), 1)
                this._WatchSleep(this.config.WatchIntervalMs)
            }
        } finally {
            this.watchRunning := false
            this.watchStopRequested := false
            this._Notify("Watch đã dừng",
                cycles " vòng đã chạy.", cycles ? 1 : 2)
        }
        return true
    }

    _WatchSleep(milliseconds) {
        remaining := Max(0, milliseconds)
        while remaining > 0 && !this.watchStopRequested {
            slice := Min(250, remaining)
            Sleep slice
            remaining -= slice
        }
        return !this.watchStopRequested
    }

    _AfterWatchGroup(index, group, result, summary) {
        if this.watchStopRequested
            return false
        if !this.config.WatchDrainQueueEachCycle
            return true
        if !result || result["saved"] <= 0
            return true
        if Mod(index, this.config.HarvestPublishAfterGroups) != 0
            return true
        ; Publish newly harvested listings to every main group before next source.
        batchesNeeded := Max(1, Ceil(result["saved"] / this.config.LeaseSize))
        Loop batchesNeeded {
            if this.watchStopRequested
                break
            status := this.publisher.Status()
            if !status["remaining_batches"]
                break
            if !this._WatchPublishAvailable(1)
                break
        }
        return !this.watchStopRequested
    }

    _WatchPublishAvailable(maxBatches := 0) {
        if !this.HasProp("watchPublishBatchesRemaining")
            this.watchPublishBatchesRemaining :=
                this.config.PublishBatchesPerWatchCycle
        requested := maxBatches > 0
            ? Min(maxBatches, this.watchPublishBatchesRemaining)
            : this.watchPublishBatchesRemaining
        if requested <= 0
            return 0

        bypass := this.config.WatchBypassSessionCooldown
        completed := 0
        Loop requested {
            if this.watchStopRequested
                break
            if (this.config.WatchStopOnUncertain
                && this.queue.UncertainEntries().Length) {
                this._Notify("Watch bỏ qua publish",
                    "Queue có delivery uncertain. Harvest 24/7 vẫn chạy. Dùng ResolveUncertain.", 2)
                break
            }
            status := this.publisher.Status()
            if !status["remaining_batches"]
                break
            try {
                summary := this.publisher.RunSession(1, bypass)
                this.watchPublishBatchesRemaining--
                completed += summary["batches"]
                if !summary["batches"] && !summary["failed"]
                    break
            } catch as err {
                this._Notify("Watch publish lỗi", err.Message, 3)
                break
            }
        }
        return completed
    }

    _WithinWatchHours() {
        return WithinConfiguredHours(
            this.config.WatchActiveHoursStart,
            this.config.WatchActiveHoursEnd)
    }

    TogglePublishPause() {
        paused := this.publisher.TogglePause()
        if !this.publisher.running
            return this._Notify("Publish chưa chạy", "Không có session để pause.", 2)
        this._Notify(paused ? "Đã pause publish" : "Tiếp tục publish",
            paused ? "Queue giữ nguyên lease hiện tại." : "Đang xử lý tiếp.", 1)
        return paused
    }

    StopPublish() {
        if this.watchRunning {
            this.watchStopRequested := true
            this._Notify("Đang dừng watch",
                "Vòng watch hiện tại sẽ kết thúc sau bước an toàn.", 2)
            return true
        }
        if !this.publisher.running
            return this._Notify("Publish chưa chạy", "Không có session để dừng.", 2)
        this.publisher.Stop()
        this._Notify("Đang dừng publish",
            "Bot sẽ checkpoint và trả lease chưa xử lý về queue.", 2)
        return true
    }

    EmergencyStop() {
        this.emergencyStopped := true
        this.watchStopRequested := true
        if this.publisher.running
            this.publisher.Stop()
        this._Notify("Lenh dung bot",
            "Dang ket thuc thao tac hien tai va luu trang thai an toan.", 2)
        return true
    }

    ResolveUncertain() {
        if this._RejectIfBusy("resolve uncertain")
            return false
        deliveries := this.queue.UncertainDeliveries()
        if !deliveries.Length
            return this._Notify("Không có uncertain", "Queue không cần xử lý thủ công.", 1)

        delivery := deliveries[1]
        labels := []
        for id in delivery["ids"] {
            entry := this.queue.Get(id)
            labels.Push(entry && entry["room_code"] != ""
                ? entry["room_code"] : id)
        }
        choice := MsgBox(
            "Listings: " StrJoin(labels, ", ") "`n"
            . "Nhóm: " delivery["group"]
            . " | Bước: " delivery["action"] "`n`n"
            . "Yes = retry (có thể gửi trùng)`n"
            . "No = skip (coi như đã gửi)`n"
            . "Cancel = giữ nguyên",
            "Resolve uncertain delivery", "YesNoCancel Icon!")
        if choice = "Cancel"
            return false
        this.queue.ResolveUncertainDelivery(
            delivery["delivery_id"], choice = "Yes")
        this._Notify("Đã resolve uncertain",
            StrJoin(labels, ", ") ": "
            . (choice = "Yes" ? "retry" : "skip"), 1)
        return true
    }

    QueueStatus() {
        stats := this.publisher.Status()
        return Format(
            "Ready: {1} | Media: {2} | Deferred: {3} | Retry: {4} | Uncertain: {5}`n"
            . "Done: {6}/{7} | Còn ~{8} batch",
            stats["ready"], stats["media_pending"], stats["deferred"],
            stats["retry_wait"], stats["uncertain"], stats["completed"],
            stats["total"], stats["remaining_batches"])
    }

    _RejectIfPublishing(action) {
        return this._RejectIfBusy(action)
    }

    _RejectIfBusy(action) {
        if this.publisher.running {
            this._Notify("Publish đang chạy",
                "Không thể " action ". Hãy stop session trước.", 2)
            return true
        }
        if this.watchRunning {
            this._Notify("Watch đang chạy",
                "Không thể " action ". Dùng "
                . this.config.HotkeyStopPublish " để dừng.", 2)
            return true
        }
        return false
    }

    RunExclusive(operationName, callback) {
        if this.operation != "" {
            this._Notify("Bot đang bận",
                "Đang chạy " this.operation
                . "; không thể bắt đầu " operationName ".", 2)
            return false
        }
        this.operation := operationName
        try {
            return callback.Call()
        } finally {
            this.operation := ""
        }
    }

    _CopySelection() {
        old := ClipboardAll()
        A_Clipboard := ""
        Send "^c"
        if !ClipWait(this.config.ClipWaitSeconds) {
            A_Clipboard := old
            return ""
        }
        text := A_Clipboard
        A_Clipboard := old
        return text
    }

    _Notify(title, message, icon := 1) {
        TrayTip title, message, icon
        return false
    }
}

; ── Bootstrap ─────────────────────────────────────────────
Startup_OnError(Err, Mode) {
    if (Mode = "Return" || Mode = "Throw")
        return false
    detail := Err.Message
    if Err.HasProp("File") && Err.File != ""
        detail .= "`n" Err.File ":" Err.Line
    logPath := LogStartupError(detail)
    MsgBox "Bot khong khoi dong duoc:`n`n" detail "`n`nLog: " logPath,
        "Zalo Listing Bot", "Iconx"
    return true
}

OnError(Startup_OnError)

try {
    cfg := AppConfig.Instance()
    if cfg.SourceGroupPromptOnStart {
        selectedSourceFile := SourceGroupFilePicker.Select(cfg)
        if selectedSourceFile = ""
            ExitApp 0
        cfg.SourceGroupFilePath := selectedSourceFile
    } else if cfg.SourceGroupFilePath = "" {
        throw Error(
            "Chua cau hinh [Groups] SourceFile va popup chon file dang tat.")
    } else if !FileExist(cfg.SourceGroupFilePath) {
        throw Error(
            "Khong tim thay file nhom input:`n" cfg.SourceGroupFilePath
            . "`n`nChay:`n  copy config\source-groups.example.csv config\source-groups.csv")
    }
    bot := ListingBotService(cfg)
    bot._LoadSourceGroups()
    botControl := BotControlWindow(bot, cfg)
    botControl.Show()

    if cfg.StartupEnableHotkeys {
        Hotkey cfg.HotkeyHarvest,
            (*) => bot.RunExclusive("harvest", ObjBindMethod(bot, "HarvestAll"))
        Hotkey cfg.HotkeyPublish,
            (*) => bot.RunExclusive("publish", ObjBindMethod(bot, "PublishToMainNotify"))
        Hotkey cfg.HotkeyCycle,
            (*) => bot.RunExclusive("harvest + publish", ObjBindMethod(bot, "HarvestAndPublish"))
        Hotkey cfg.HotkeyRelayImages,
            (*) => bot.RunExclusive("relay ảnh", ObjBindMethod(bot, "RelayImages"))
        Hotkey cfg.HotkeyArchiveMedia,
            (*) => bot.RunExclusive("archive ảnh", ObjBindMethod(bot, "ArchiveMedia"))
        Hotkey cfg.HotkeyPausePublish, (*) => bot.TogglePublishPause()
        Hotkey cfg.HotkeyStopPublish, (*) => bot.EmergencyStop()
        Hotkey cfg.HotkeyResolveUncertain,
            (*) => bot.RunExclusive("resolve uncertain", ObjBindMethod(bot, "ResolveUncertain"))
        Hotkey cfg.HotkeyForward,
            (*) => bot.RunExclusive("forward listing", ObjBindMethod(bot, "ForwardListingFromClipboard"))
        Hotkey cfg.HotkeyRelease,
            (*) => bot.RunExclusive("cấp số điện thoại", ObjBindMethod(bot, "ReleasePhoneFromClipboard"))
        Hotkey cfg.HotkeyReload,
            (*) => bot.RunExclusive("reload", ObjBindMethod(bot, "Reload"))
        Hotkey cfg.HotkeyToggleWatch,
            (*) => bot.ToggleWatch()
    } else if cfg.StartupAutoRunWatch {
        Hotkey cfg.HotkeyStopPublish, (*) => bot.EmergencyStop()
    }

    _autoMode := cfg.StartupAutoRunWatch ? "tu dong" : "thu cong (hotkey)"
    TrayTip Format(
        "San sang — {1} nhom nguon, {2} nhom chinh`n{3}`nZalo Web 1 tab`nChe do: {4}",
        bot.registry.SourceGroups().Length,
        bot.registry.MainGroups().Length,
        bot.QueueStatus(), _autoMode),
        "Zalo Listing Bot", "Iconi"

    ; Auto-execute: chờ Zalo rồi bật watch loop (không chặn đăng ký hotkey phía trên).
    if cfg.StartupAutoRunWatch
        SetTimer(ObjBindMethod(bot, "AutoStart"), -500)
} catch as err {
    detail := err.Message
    if err.HasProp("File") && err.File != ""
        detail .= "`n" err.File ":" err.Line
    logPath := LogStartupError(detail)
    MsgBox "Bot khong khoi dong duoc:`n`n" detail "`n`nLog: " logPath,
        "Zalo Listing Bot", "Iconx"
    ExitApp 1
}
