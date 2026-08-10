#Requires AutoHotkey v2.0
; Publisher.ahk — resumable service: lease five rooms, send media, then one text

class DurableListingPublisher {
    __New(config, ui, registry, composer, queueStore, repository, mediaStore) {
        this.config := config
        this.ui := ui
        this.registry := registry
        this.composer := composer
        this.queue := queueStore
        this.repo := repository
        this.media := mediaStore
        this.paused := false
        this.stopRequested := false
        this.running := false
        this.nextSessionAt := ""
    }

    RunSession(maxBatches := 0, bypassCooldown := false) {
        if this.running
            throw Error("Publish session đang chạy.")
        if (!bypassCooldown
            && this.nextSessionAt != "" && this.nextSessionAt > CompactStamp())
            throw Error("Publish đang cooldown đến " this.nextSessionAt ".")
        if !this._WithinActiveHours()
            throw Error("Ngoài khung giờ publish đã cấu hình.")
        if this.queue.UncertainEntries().Length
            throw Error("Queue có delivery uncertain. Dùng hotkey ResolveUncertain trước.")

        limit := maxBatches > 0 ? maxBatches : this.config.MaxBatchesPerSession
        mainGroups := this.registry.MainGroups()
        if !mainGroups.Length
            throw Error("Chưa khai báo nhóm type=main.")

        this.running := true
        this.stopRequested := false
        this.queue.ReclaimExpiredLeases()
        this.queue.ExpireStale()

        leases := []
        summary := Map(
            "batches", 0, "rooms", 0, "messages", 0,
            "failed", 0, "stopped", 0, "errors", []
        )

        try {
            Loop limit {
                lease := this.queue.LeaseNext(this.config.LeaseSize)
                if lease["token"] = ""
                    break
                leases.Push(lease)
            }

            if !leases.Length
                return summary

            this._Log("session_start leases=" leases.Length
                " rooms=" this._LeaseRoomCount(leases))
            successful := Map()
            for lease in leases
                successful[lease["token"]] := true

            for groupIndex, group in mainGroups {
                if this.stopRequested
                    break
                groupName := group["group_name"]
                this.ui.BeginPublishSession(groupName)

                for leaseIndex, lease in leases {
                    this._WaitWhilePaused()
                    if this.stopRequested
                        break
                    token := lease["token"]
                    if !successful[token]
                        continue

                    records := this.repo.GetMany(lease["ids"])
                    if records.Length != lease["ids"].Length {
                        missingIds := []
                        validIds := []
                        for id in lease["ids"] {
                            if this.repo.Get(id)
                                validIds.Push(id)
                            else
                                missingIds.Push(id)
                        }
                        message := "Thiếu listing payload: " StrJoin(missingIds, ",")
                        this.queue.DeadLetter(missingIds, message)
                        this.queue.ReleaseIds(validIds)
                        successful[token] := false
                        summary["failed"]++
                        summary["errors"].Push(message)
                        continue
                    }

                    try {
                        this._SendBatch(lease, records, groupName)
                        summary["messages"]++
                        this._Log("batch_checkpoint group=" groupName
                            " lease=" token " rooms=" records.Length)
                        if leaseIndex < leases.Length
                            this._RateDelay(
                                this.config.PublishSendDelayMinMs,
                                this.config.PublishSendDelayMaxMs)
                    } catch as err {
                        this.queue.FailLease(token, err.Message)
                        successful[token] := false
                        summary["failed"]++
                        summary["errors"].Push(groupName ": " err.Message)
                        this._Log("batch_failed group=" groupName
                            " lease=" token " error=" err.Message)
                    }
                }
                this.ui.EndPublishSession()
                if groupIndex < mainGroups.Length && !this.stopRequested
                    this._RateDelay(
                        this.config.PublishGroupDelayMinMs,
                        this.config.PublishGroupDelayMaxMs)
            }

            for lease in leases {
                token := lease["token"]
                if this.stopRequested && successful[token] {
                    this.queue.ReleaseLease(token)
                    continue
                }
                if successful[token] {
                    completed := this.queue.CompleteLease(token)
                    this.repo.MarkPublishedLocal(lease["ids"])
                    summary["batches"]++
                    summary["rooms"] += completed
                }
            }
            summary["stopped"] := this.stopRequested ? 1 : 0
            return summary
        } finally {
            for lease in leases {
                if this.queue.GetMany(lease["ids"]).Length
                    this._ReleaseIfStillLeased(lease["token"])
            }
            this.ui.EndPublishSession()
            this.running := false
            this.paused := false
            if !bypassCooldown && leases.Length && this.config.SessionCooldownMs > 0 {
                seconds := Ceil(this.config.SessionCooldownMs / 1000)
                this.nextSessionAt := DateAdd(CompactStamp(), seconds, "Seconds")
            }
            if leases.Length {
                stats := this.queue.Stats()
                this._Log("session_end completed=" summary["rooms"]
                    " failed=" summary["failed"]
                    " ready=" stats["ready"]
                    " retry_wait=" stats["retry_wait"]
                    " uncertain=" stats["uncertain"]
                    " dead_letter=" stats["dead_letter"])
            }
        }
    }

    _SendBatch(lease, records, groupName) {
        ids := lease["ids"]
        for id in ids {
            entry := this.queue.Get(id)
            if !entry || entry["lease_token"] != lease["token"]
                throw Error("Lease ownership đã thay đổi cho listing " id)
        }

        ; One room = images → text → separator message → next room.
        if this.config.OneMessagePerListing || this.config.LeaseSize = 1 {
            for record in records
                this._SendOneRoom(record, groupName, true)
            return
        }

        if this.config.ImagesBeforeText {
            for record in records
                this._SendRecordMedia(record, groupName)
        }

        sentCount := 0
        for id in ids {
            entry := this.queue.Get(id)
            delivery := this._DeliveryOrDefault(entry, groupName)
            if delivery["text_sent"]
                sentCount++
        }
        if sentCount != ids.Length {
            if sentCount > 0
                throw Error("Checkpoint text không đồng nhất trong batch " lease["token"])

            message := this.composer.ComposeBatch(records)
            if StrLen(message) > this.config.MaxMessageChars
                throw Error("Batch text vượt MaxMessageChars ("
                    . StrLen(message) "/" this.config.MaxMessageChars ")")
            beforeSend := ObjBindMethod(
                this.queue, "MarkDeliveryIntent", ids, groupName, "text")
            this.ui.SendTextInSession(message, beforeSend)
            this.queue.CheckpointText(ids, groupName)
        }

        if !this.config.ImagesBeforeText {
            for record in records
                this._SendRecordMedia(record, groupName)
        }
    }

    ; Per room: archive images first, then formatted text, then separator bubble.
    _SendOneRoom(record, groupName, sendSeparatorAfter := true) {
        id := record["id"]
        entry := this.queue.Get(id)
        delivery := this._DeliveryOrDefault(entry, groupName)

        if this.config.ImagesBeforeText && !delivery["text_sent"]
            this._SendRecordMedia(record, groupName)

        if !delivery["text_sent"] {
            message := this.composer.ComposeOne(record)
            if StrLen(message) > this.config.MaxMessageChars
                throw Error("Room text vượt MaxMessageChars ("
                    . StrLen(message) "/" this.config.MaxMessageChars ")")
            beforeSend := ObjBindMethod(
                this.queue, "MarkDeliveryIntent", [id], groupName, "text")
            this.ui.SendTextInSession(message, beforeSend)
            this.queue.CheckpointText([id], groupName)
        }

        if !this.config.ImagesBeforeText
            this._SendRecordMedia(record, groupName)

        if sendSeparatorAfter
            && this.config.HasProp("SendSeparatorAsMessage")
            && this.config.SendSeparatorAsMessage {
            sep := this.composer.ListingSeparator()
            if Trim(sep) != ""
                this.ui.SendTextInSession(sep)
        }
    }

    _SendRecordMedia(record, groupName) {
        id := record["id"]
        entry := this.queue.Get(id)
        files := entry && entry.Has("media_files") ? entry["media_files"] : []
        imageCount := record.Has("image_count") ? record["image_count"] : 0
        if files.Length && !this.media.IsTrusted(id)
            throw Error("Phòng " record["room_code"]
                . " có image cache cũ/chưa xác thực; cần capture lại.")

        if imageCount > 0 && this.config.MediaRequired && !files.Length
            throw Error("Phòng " record["room_code"] " chưa archive ảnh.")

        delivery := this._DeliveryOrDefault(entry, groupName)
        index := delivery["media_index_sent"] + 1
        while index <= files.Length {
            path := this.media.Resolve(files[index])
            this.ui.RestoreClipboardArchive(path)
            beforeSend := ObjBindMethod(
                this.queue, "MarkDeliveryIntent",
                [id], groupName, "media", index)
            this.ui.PasteClipboardInSession(beforeSend)
            this.queue.CheckpointMedia(id, groupName, index)
            index++
        }
    }

    _DeliveryOrDefault(entry, groupName) {
        if entry && entry.Has("deliveries") && entry["deliveries"].Has(groupName)
            return entry["deliveries"][groupName]
        return Map(
            "media_index_sent", 0, "text_sent", 0, "uncertain", 0,
            "last_action", "", "last_media_index", 0
        )
    }

    _WaitWhilePaused() {
        while this.paused && !this.stopRequested
            Sleep 250
    }

    _LeaseRoomCount(leases) {
        count := 0
        for lease in leases
            count += lease["ids"].Length
        return count
    }

    _WithinActiveHours() {
        return WithinConfiguredHours(
            this.config.PublishActiveHoursStart,
            this.config.PublishActiveHoursEnd)
    }

    _RateDelay(minMs, maxMs) {
        if maxMs <= 0
            return
        Sleep Random(minMs, maxMs)
    }

    _Log(message) {
        try FileAppend "[" NowStamp() "] " message "`n",
            this.config.QueueLogFile, "UTF-8-RAW"
    }

    _ReleaseIfStillLeased(token) {
        for entry in this.queue.AllEntries() {
            if entry["lease_token"] = token
                && (entry["status"] = "leased" || entry["status"] = "sending")
                return this.queue.ReleaseLease(token)
        }
        return 0
    }

    TogglePause() {
        if !this.running
            return false
        this.paused := !this.paused
        return this.paused
    }

    Stop() {
        this.stopRequested := true
        this.paused := false
        return true
    }

    Status() {
        stats := this.queue.Stats()
        waiting := stats["ready"] + stats["retry_wait"]
        stats["remaining_batches"] := Ceil(waiting / this.config.LeaseSize)
        stats["running"] := this.running ? 1 : 0
        stats["paused"] := this.paused ? 1 : 0
        return stats
    }
}
