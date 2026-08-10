#Requires AutoHotkey v2.0
; MediaCapturer.ahk — Service: auto-select image bubbles and archive during harvest

class ListingMediaCapturer {
    __New(config, ui, mediaStore, queueStore) {
        this.config := config
        this.ui := ui
        this.media := mediaStore
        this.queue := queueStore
    }

    ; Pure helper for tests — pick a Zalo find-in-chat query from a saved record.
    static BuildSearchAnchor(record, config) {
        mode := config.Has("AutoCaptureAnchor")
            ? config.AutoCaptureAnchor : "room_code"

        if mode = "room_code" || mode = "" {
            code := record.Has("room_code") ? Trim(record["room_code"]) : ""
            if code != ""
                return code
        }

        if mode = "address" || mode = "room_code" {
            addr := record.Has("address") ? Trim(record["address"]) : ""
            if addr != ""
                return SubStr(addr, 1, 60)
        }

        raw := record.Has("raw_text") ? record["raw_text"] : ""
        for line in StrSplit(raw, "`n", "`r") {
            trimmed := Trim(line)
            if RegExMatch(trimmed, "i)^(?:📍\s*)?Địa chỉ:\s*(.+)", &found)
                return SubStr(Trim(found[1]), 1, 60)
        }

        return SubStr(Trim(raw), 1, 40)
    }

    CaptureForRecord(groupName, record) {
        if !this.config.AutoCapture
            return true

        imageCount := record.Has("image_count") ? record["image_count"] : 0
        if imageCount <= 0
            return true
        if this.media.HasMedia(record["id"])
            return true

        anchor := ListingMediaCapturer.BuildSearchAnchor(record, this.config)
        if anchor = "" {
            this._LogFail(record, "", "Không có anchor tìm bubble")
            return false
        }

        maxRetries := this.config.AutoCaptureMaxRetries
        Loop maxRetries + 1 {
            try {
                this.ui.FindMessageInConversation(anchor)
                this.ui.SelectImageBubblesAbove(imageCount)
                this.ArchiveFromSelection(record, false)
                this._Log("auto_capture_ok group=" groupName
                    " id=" record["id"]
                    " room=" (record.Has("room_code") ? record["room_code"] : "")
                    " images=" imageCount)
                return true
            } catch as err {
                if A_Index > maxRetries {
                    this._LogFail(record, anchor, err.Message)
                    return false
                }
                Sleep 500
            }
        }
        return false
    }

    ArchiveFromSelection(record, append := false) {
        prepared := this.media.PrepareArchive(record["id"], append)
        try {
            if !this.ui.CopyImageFromSelection()
                throw Error("Không copy được ảnh đã chọn.")
            this.ui.SaveClipboardArchive(prepared["temp_path"])
            this.media.CommitGeneration(prepared)
            files := this.media.RelativePaths(record["id"])
            this.queue.AttachMedia(
                record["id"], files, this.media.MetadataFor(record["id"]))
            return files.Length
        } catch as err {
            this.media.AbortGeneration(prepared)
            throw err
        }
    }

    _Log(message) {
        try FileAppend "[" NowStamp() "] " message "`n",
            this.config.QueueLogFile, "UTF-8-RAW"
    }

    _LogFail(record, anchor, message) {
        room := record.Has("room_code") ? record["room_code"] : record["id"]
        this._Log("auto_capture_fail room=" room
            " anchor=" anchor " error=" message)
    }
}
