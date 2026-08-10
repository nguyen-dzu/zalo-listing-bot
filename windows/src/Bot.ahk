#Requires AutoHotkey v2.0
#SingleInstance Force

; Admin + config path trước khi load module (release: exe cạnh config/; dev: src/ + ../config).
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

Persistent

#Include Util.ahk
#Include JSON.ahk
#Include Config.ahk
#Include TableLoader.ahk
#Include GroupRegistry.ahk
#Include BlockList.ahk
#Include Parser.ahk
#Include Storage.ahk
#Include StateStore.ahk
#Include QueueStore.ahk
#Include MediaStore.ahk
#Include Composer.ahk
#Include ZaloUI.ahk
#Include GroupActivity.ahk
#Include MediaCapturer.ahk
#Include Harvester.ahk
#Include Publisher.ahk

; ── Facade: one method per operator action ────────────────
class ListingBotService {
    __New(config) {
        this.config := config
        this.operation := ""
        this.watchRunning := false
        this.watchStopRequested := false
        this._Build()
    }

    _Build() {
        this.registry := GroupRegistry(this.config)
        this.groupsDiscovered := false
        this.blockList := BlockList(this.config)
        this.state := HarvestStateStore(this.config)
        this.queue := PublishQueueStore(this.config)
        this.media := ListingMediaStore(this.config)
        this.repo := ListingRepository(this.config, this.queue)
        this._ReconcileMediaArchives()
        this.ui := ZaloUIAdapter(this.config)
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
        if !entry.Has("media_metadata")
            || entry["media_metadata"].Length != metadata.Length
            return false
        for index, item in metadata {
            current := entry["media_metadata"][index]
            if !current.Has("path") || !current.Has("size")
                || current["path"] != item["path"]
                || current["size"] != item["size"]
                return false
        }
        return true
    }

    Reload() {
        if this._RejectIfBusy("reload")
            return false
        this.config.Reload()
        this._Build()
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

    ; Drain a bounded number of durable five-room leases.
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
        if this.config.ImageStrategy = "off"
            return this._Notify("Ảnh đang tắt", "Đặt [Images] Strategy=forward hoặc clipboard.", 2)

        if this.config.ImageStrategy = "clipboard" {
            try {
                if !this.ui.CopyImageFromSelection()
                    throw Error("Không copy được bubble ảnh đang chọn.")
            } catch as err {
                return this._Notify("Lỗi copy ảnh", err.Message, 3)
            }
        }

        for group in mainGroups {
            try {
                if this.config.ImageStrategy = "clipboard"
                    this.ui.RelayClipboardImage(group["group_name"])
                else
                    this.ui.ForwardSelection(group["group_name"])
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
        if !this.config.StartupAutoRunWatch
            return false
        if this.watchRunning || this.operation != ""
            return false
        try {
            this._WaitForZaloReady()
            if this.config.StartupDelayMs > 0
                Sleep this.config.StartupDelayMs
            this._Notify("Auto-start",
                "Zalo sẵn sàng — bật watch loop tự động.", 1)
            return this.RunExclusive("watch", ObjBindMethod(this, "RunWatchLoop"))
        } catch as err {
            this._Notify("Auto-start lỗi", err.Message, 3)
            return false
        }
    }

    _WaitForZaloReady() {
        exe := this.config.ExeName
        timeout := this.config.StartupWaitForZaloSeconds
        if WinExist("ahk_exe " exe) {
            this._PrepareZaloWindow()
            return true
        }
        if this.config.StartupLaunchZaloIfMissing {
            path := this._ResolveZaloExePath()
            if path = ""
                throw Error(
                    "Không tìm thấy Zalo.exe. Cấu hình [Zalo] ExePath trong config.ini.")
            Run path
        }
        if !WinWait("ahk_exe " exe,, timeout)
            throw Error("Zalo không mở sau " timeout " giây.")
        this._PrepareZaloWindow()
        return true
    }

    _EnsureGroupsDiscovered() {
        if this.groupsDiscovered
            return true
        if !this.ui.IsRunning()
            this._WaitForZaloReady()
        return this._RefreshGroupsFromZalo()
    }

    _RefreshGroupsFromZalo() {
        manualUsed := this.config.GroupDiscoveryMode = "manual"
        raw := manualUsed ? "" : this.ui.CaptureAllGroupListText()
        if Trim(raw) = "" {
            manualNames := GroupRegistry.LoadManualNames(
                this.config.GroupListManualFile)
            if manualNames.Length {
                raw := StrJoin(manualNames, "`n")
                manualUsed := true
            }
        }
        this.lastGroupListRaw := raw
        WriteTextFile(this.config.GroupListCaptureFile, raw)
        names := GroupRegistry.ParseCapturedNames(
            raw, this.config.GroupListIgnoredLabels)
        count := this.registry.SetDiscovered(names)
        sources := this.registry.SourceGroups().Length
        if !count {
            throw Error(
                "Khong doc duoc danh sach nhom/cong dong tu Zalo (clipboard rong).`n"
                . "1) Mo Zalo tab Alt+3, thu chinh [Groups] ListPaneClickX/Y trong config.ini`n"
                . "2) Hoac tao file " this.config.GroupListManualFile
                . " (1 ten/dong)`n"
                . "Raw da luu: " this.config.GroupListCaptureFile)
        }
        if !sources {
            throw Error(
                "Doc duoc " count " muc nhung 0 nhom nguon (tat ca trung output?).`n"
                . "Kiem tra [Groups] OutputGroups trong config.ini.`n"
                . "Raw: " this.config.GroupListCaptureFile)
        }
        this.groupsDiscovered := true
        suffix := manualUsed ? " (manual list)" : ""
        this._Notify("Da doc nhom tu Zalo",
            count " tong | " sources " input | "
            . this.registry.MainGroups().Length " output" suffix, 1)
        return true
    }

    _PrepareZaloWindow() {
        exe := "ahk_exe " this.config.ExeName
        WinActivate exe
        if !WinWaitActive(exe,, 5)
            throw Error("Không kích hoạt được cửa sổ Zalo.")
        if this.config.StartupMaximizeZalo
            WinMaximize exe
        Sleep 500
    }

    _ResolveZaloExePath() {
        if this.config.ZaloExePath != "" && FileExist(this.config.ZaloExePath)
            return this.config.ZaloExePath
        candidates := [
            EnvGet("LocalAppData") "\Programs\Zalo\Zalo.exe",
            A_AppData "\Zalo\Zalo.exe",
            EnvGet("ProgramFiles") "\Zalo\Zalo.exe",
            EnvGet("ProgramFiles(x86)") "\Zalo\Zalo.exe"
        ]
        for path in candidates {
            if path != "" && FileExist(path)
                return path
        }
        return ""
    }

    RunWatchLoop() {
        this.watchRunning := true
        this.watchStopRequested := false
        cycles := 0
        this._Notify("Watch bật",
            "Harvest → publish → nghỉ "
            . Round(this.config.WatchIntervalMs / 60000) " phút."
            . (this.config.StartupEnableHotkeys
                ? " " this.config.HotkeyToggleWatch " tắt."
                : " " this.config.HotkeyStopPublish " dừng khẩn cấp."), 1)

        try {
            Loop {
                if this.watchStopRequested
                    break
                if !this._WithinWatchHours() {
                    Sleep 60000
                    continue
                }

                cycles++
                try {
                    ; Cycle 1 establishes a full baseline. Later cycles select
                    ; textual unread groups plus a small oldest-first audit shard.
                    if cycles = 1
                        || Mod(cycles - 1,
                            this.config.GroupRefreshEveryCycles) = 0
                        || !this.groupsDiscovered
                        this._RefreshGroupsFromZalo()
                    sources := this.registry.SourceGroups()
                    unreadRaw := cycles > 1
                        ? this.ui.CaptureUnreadConversationText() : ""
                    unread := cycles > 1
                        ? GroupActivityDetector.DetectUnread(
                            unreadRaw, sources,
                            this.config.GroupUnreadMarkerPattern)
                        : []
                    plan := this.harvestScheduler.BuildPlan(
                        sources, this.state, unread)
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
                    Sleep this.config.WatchIntervalMs
                    continue
                }

                if this.watchStopRequested
                    break

                if this.config.WatchDrainQueueEachCycle
                    this._WatchPublishAvailable(
                        this.watchPublishBatchesRemaining)

                if this.watchStopRequested
                    break

                this._Notify("Watch vòng " cycles " xong",
                    Format("{1}: {2} nhóm | unread: {3}`nMới: {4} | Ảnh OK: {5} | sửa cache: {6} | lỗi: {7}`nNghỉ {8} phút…",
                        plan["mode"], plan["groups"].Length, plan["unread"],
                        harvest["saved"], harvest["media_captured"],
                        mediaRepair["captured"],
                        harvest["media_failed"] + mediaRepair["failed"],
                        Round(this.config.WatchIntervalMs / 60000)), 1)
                Sleep this.config.WatchIntervalMs
            }
        } finally {
            this.watchRunning := false
            this.watchStopRequested := false
            this._Notify("Watch đã dừng",
                cycles " vòng đã chạy.", cycles ? 1 : 2)
        }
        return true
    }

    _AfterWatchGroup(index, group, result, summary) {
        if !this.config.WatchDrainQueueEachCycle
            return
        if Mod(index, this.config.HarvestPublishAfterGroups) != 0
            return
        this._WatchPublishAvailable(1)
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
            if this.config.WatchStopOnUncertain
                && this.queue.UncertainEntries().Length {
                this.watchStopRequested := true
                this._Notify("Watch dừng",
                    "Queue có delivery uncertain. Dùng ResolveUncertain.", 3)
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
                if InStr(err.Message, "uncertain")
                    this.watchStopRequested := true
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
    bot := ListingBotService(cfg)

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
        Hotkey cfg.HotkeyStopPublish, (*) => bot.StopPublish()
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
        Hotkey cfg.HotkeyStopPublish, (*) => bot.StopPublish()
    }

    _autoMode := cfg.StartupAutoRunWatch ? "tu dong" : "thu cong (hotkey)"
    TrayTip Format(
        "San sang — {1} nhom nguon, {2} nhom chinh`n{3}`nChe do: {4}",
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
