#Requires AutoHotkey v2.0
#SingleInstance Force
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
#Include Composer.ahk
#Include ZaloUI.ahk
#Include Harvester.ahk

; ── Facade: one method per operator action ────────────────
class ListingBotService {
    __New(config) {
        this.config := config
        this._Build()
    }

    _Build() {
        this.registry := GroupRegistry(this.config)
        this.blockList := BlockList(this.config)
        this.repo := ListingRepository(this.config)
        this.state := HarvestStateStore(this.config)
        this.ui := ZaloUIAdapter(this.config)
        this.composer := MessageComposer(this.config)
        this.harvester := MessageHarvester(
            this.config, this.ui, this.registry, this.blockList, this.state, this.repo
        )
    }

    Reload() {
        this.config.Reload()
        this._Build()
        this._Notify("Đã nạp lại cấu hình",
            this.registry.SourceGroups().Length " nhóm nguồn, "
            . this.registry.MainGroups().Length " nhóm chính, "
            . this.blockList.rules.Length " từ khoá cấm")
    }

    ; Đọc tin mới từ mọi nhóm nguồn, lưu object xuống máy.
    HarvestAll() {
        try {
            summary := this.harvester.HarvestAll()
        } catch as err {
            return this._Notify("Lỗi thu thập", err.Message, 3)
        }

        message := Format("Nhóm: {1} | Mới: {2} | Cấm: {3} | Trùng: {4} | Thiếu field: {5}",
            summary["groups"], summary["saved"], summary["blocked"],
            summary["duplicate"], summary["invalid"])
        if summary["errors"].Length
            message .= "`nLỗi: " StrJoin(summary["errors"], "; ")

        this._Notify("Thu thập xong", message, summary["errors"].Length ? 2 : 1)
        return summary
    }

    ; Gộp các tin chưa gửi thành cụm message và bắn vào mọi nhóm chính.
    PublishToMain() {
        pending := this.repo.Pending()
        if !pending.Length
            return this._Notify("Không có tin mới", "Chưa có listing nào chờ gửi.", 2)

        chunks := this.composer.Compose(pending)
        mainGroups := this.registry.MainGroups()
        if !mainGroups.Length
            return this._Notify("Thiếu nhóm chính", "Chưa khai báo nhóm type=main trong file Excel/CSV.", 3)

        sent := 0
        for group in mainGroups {
            try {
                sent += this.ui.SendTextChunks(group["group_name"], chunks)
            } catch as err {
                return this._Notify("Lỗi gửi", group["group_name"] ": " err.Message, 3)
            }
        }

        this.repo.MarkPublished(this.composer.CollectIds(pending))
        this._Notify("Đã gửi", Format("{1} tin → {2} nhóm chính ({3} message)",
            pending.Length, mainGroups.Length, sent), 1)
    }

    HarvestAndPublish() {
        summary := this.HarvestAll()
        if summary && summary["saved"]
            this.PublishToMain()
    }

    ; Ảnh phải tới nhóm chính trước phần text: chọn tin ảnh trong nhóm nguồn rồi bấm hotkey này.
    RelayImages() {
        mainGroups := this.registry.MainGroups()
        if !mainGroups.Length
            return this._Notify("Thiếu nhóm chính", "Chưa khai báo nhóm type=main.", 3)
        if this.config.ImageStrategy = "off"
            return this._Notify("Ảnh đang tắt", "Đặt [Images] Strategy=forward hoặc clipboard.", 2)

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
        chunks := this.composer.Compose([record])

        for group in this.registry.MainGroups() {
            try {
                this.ui.SendTextChunks(group["group_name"], chunks)
            } catch as err {
                return this._Notify("Lỗi Zalo", err.Message, 3)
            }
        }

        this.repo.MarkPublished([record["id"]])
        this._Notify("Đã chuyển tin", listing["room_code"] != "" ? listing["room_code"] : listing["address"], 1)
    }

    ReleasePhoneFromClipboard() {
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
cfg := AppConfig.Instance()
bot := ListingBotService(cfg)

Hotkey cfg.HotkeyHarvest, (*) => bot.HarvestAll()
Hotkey cfg.HotkeyPublish, (*) => bot.PublishToMain()
Hotkey cfg.HotkeyCycle, (*) => bot.HarvestAndPublish()
Hotkey cfg.HotkeyRelayImages, (*) => bot.RelayImages()
Hotkey cfg.HotkeyForward, (*) => bot.ForwardListingFromClipboard()
Hotkey cfg.HotkeyRelease, (*) => bot.ReleasePhoneFromClipboard()
Hotkey cfg.HotkeyReload, (*) => bot.Reload()

TrayTip "Zalo Listing Bot",
    Format("Sẵn sàng — {1} nhóm nguồn, {2} nhóm chính`n{3} thu thập | {4} gửi nhóm chính | {5} chuyển ảnh",
        bot.registry.SourceGroups().Length,
        bot.registry.MainGroups().Length,
        cfg.HotkeyHarvest, cfg.HotkeyPublish, cfg.HotkeyRelayImages),
    1
