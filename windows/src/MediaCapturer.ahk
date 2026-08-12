#Requires AutoHotkey v2.0
; MediaCapturer.ahk — archive listing images via Zalo Web DOM bridge

class ListingMediaCapturer {
    __New(config, ui, mediaStore, queueStore) {
        this.config := config
        this.ui := ui
        this.media := mediaStore
        this.queue := queueStore
    }

    static BuildSearchAnchor(record, config) {
        mode := config.HasProp("AutoCaptureAnchor")
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
        if imageCount <= 0 && !this.config.AutoCaptureProbeImages
            return true
        if this.media.IsTrusted(record["id"]) {
            this.queue.AttachMedia(
                record["id"],
                this.media.RelativePaths(record["id"]),
                this.media.MetadataFor(record["id"]))
            return true
        }

        anchor := ListingMediaCapturer.BuildSearchAnchor(record, this.config)
        if anchor = "" {
            this._LogFail(record, "", "Không có anchor tìm ảnh")
            return false
        }

        maxRetries := this.config.AutoCaptureMaxRetries
        Loop maxRetries + 1 {
            try {
                limit := imageCount > 0
                    ? imageCount : this.config.AutoCaptureProbeMaxImages
                allowHeuristic := imageCount > 0
                    || this.config.AutoCaptureProbeImages
                locations := this.ui.FindImageBubblesNearMessage(
                    anchor, limit, allowHeuristic)
                if !locations.Length {
                    if imageCount > 0
                        throw Error("Không tìm thấy ảnh gần listing.")
                    return true
                }
                captured := this._ArchiveLocations(
                    groupName, record, anchor, locations)
                if captured > 0 && imageCount <= 0
                    record["image_count"] := captured
                this._Log("auto_capture_ok group=" groupName
                    " id=" record["id"]
                    " room=" (record.Has("room_code") ? record["room_code"] : "")
                    " images=" (record.Has("image_count") ? record["image_count"] : 0))
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

    RepairPending(repository, limit := 0) {
        result := Map("attempted", 0, "captured", 0, "failed", 0)
        if limit <= 0 || !this.config.AutoCapture
            return result
        for entry in this.queue.MediaPendingEntries(limit) {
            record := repository.Get(entry["id"])
            if !record || !record.Has("source_group")
                continue
            result["attempted"]++
            if this.CaptureForRecord(record["source_group"], record)
                result["captured"]++
            else
                result["failed"]++
        }
        return result
    }

    _ArchiveLocations(groupName, record, anchor, locations) {
        id := record["id"]
        if this.media.HasMedia(id) && !this.media.IsTrusted(id) {
            this.queue.InvalidateMedia(
                id, "Replacing unvalidated image cache.", false)
            this.media.DeleteFor(id)
        }

        captured := 0
        for location in locations {
            prepared := this.media.PrepareArchive(id, captured > 0)
            try {
                if !this.ui.CopyImageAt(location)
                    throw Error("Không copy ảnh vào clipboard.")
                this.ui.SaveClipboardArchive(prepared["temp_path"])
                this.media.CommitGeneration(prepared)
                captured++
            } catch as err {
                this.media.AbortGeneration(prepared)
                if !captured
                    throw err
                this._Log("auto_capture_partial id=" id
                    " captured=" captured " error=" err.Message)
                break
            }
        }
        if !captured
            throw Error("Không capture được ảnh nào.")

        this.media.WriteManifest(id, Map(
            "capture_version", 2,
            "validated_bitmap", 1,
            "capture_mode", "web_dom",
            "source_group", groupName,
            "anchor", anchor,
            "image_count", captured,
            "captured_at", NowStamp()
        ))
        if !this.media.IsTrusted(id)
            throw Error("Archive vừa capture không đạt manifest v2/trusted.")
        files := this.media.RelativePaths(id)
        if !files.Length
            throw Error("Manifest hợp lệ nhưng không có archive media.")
        this.queue.AttachMedia(id, files, this.media.MetadataFor(id))
        return captured
    }

    ArchiveFromSelection(record, append := false) {
        prepared := this.media.PrepareArchive(record["id"], append)
        try {
            if !this.ui.CopyImageFromSelection()
                throw Error("Không copy được ảnh đã chọn.")
            this.ui.SaveClipboardArchive(prepared["temp_path"])
            this.media.CommitGeneration(prepared)
            this.media.WriteManifest(record["id"], Map(
                "capture_version", 2,
                "validated_bitmap", 1,
                "capture_mode", "manual_selection",
                "image_count", 1,
                "captured_at", NowStamp()
            ))
            if !this.media.IsTrusted(record["id"])
                throw Error("Archive thủ công không đạt manifest v2/trusted.")
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
