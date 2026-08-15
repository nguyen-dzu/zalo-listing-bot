#Requires AutoHotkey v2.0
; Publisher.ahk — resumable service: lease one room at a time
; Single tab: route to one output group, then per room: images → text → separator

#Include OutputRouter.ahk

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
        this.allowForward := true
    }

    RunSession(maxBatches := 0, bypassCooldown := false, allowForward := true) {
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
        this.allowForward := allowForward
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

            leaseIndex := 0
            for lease in leases {
                leaseIndex++
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

                routed := false
                for record in records {
                    route := ListingOutputRouter.ResolveOutputGroup(record, this.config)
                    groupName := route["group"]
                    if groupName = "" {
                        this.queue.DeadLetter(
                            [record["id"]],
                            "no_output_route:" route["reason"])
                        this._Log("route_skip id=" record["id"]
                            " reason=" route["reason"])
                        successful[token] := false
                        summary["failed"]++
                        continue
                    }

                    this._Log("route id=" record["id"]
                        " group=" groupName " reason=" route["reason"])
                    try {
                        this.ui.BeginPublishSession(groupName)
                        this._SendBatch(lease, [record], groupName)
                        this.ui.EndPublishSession()
                        summary["messages"]++
                        routed := true
                        this._Log("batch_checkpoint group=" groupName
                            " lease=" token " rooms=1")
                    } catch as err {
                        this.ui.EndPublishSession()
                        this.queue.FailLease(token, err.Message)
                        successful[token] := false
                        summary["failed"]++
                        summary["errors"].Push(groupName ": " err.Message)
                        this._Log("batch_failed group=" groupName
                            " lease=" token " error=" err.Message)
                        break
                    }
                }

                if routed && leaseIndex < leases.Length && !this.stopRequested
                    this._RateDelay(
                        this.config.PublishSendDelayMinMs,
                        this.config.PublishSendDelayMaxMs)
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

        ; Always one room per cycle: images → text → separator → next room.
        for record in records
            this._SendOneRoom(record, groupName, true)
    }

    ; Per room: forward (if eligible) or archive images, then text, then separator.
    _SendOneRoom(record, groupName, sendSeparatorAfter := true) {
        id := record["id"]
        entry := this.queue.Get(id)
        delivery := this._DeliveryOrDefault(entry, groupName)

        forwardEligible := this.allowForward
            && record.Has("forward_eligible") && record["forward_eligible"]
        if forwardEligible && !delivery["forward_sent"] {
            try {
                sourceGroup := record.Has("source_group") ? record["source_group"] : ""
                messageHash := record.Has("message_hash") ? record["message_hash"] : ""
                roomCode := record.Has("room_code") ? record["room_code"] : ""
                beforeSend := ObjBindMethod(
                    this.queue, "MarkDeliveryIntent", [id], groupName, "forward")
                beforeSend.Call()
                this.ui.ForwardListingMessage(
                    sourceGroup, groupName, messageHash, roomCode)
                this.queue.CheckpointForward(id, groupName)
            } catch as err {
                this._Log("forward_fallback id=" id " error=" err.Message)
                ; Forward navigates back to the source conversation first.
                ; On any forward failure, restore the output before archive paste.
                this.ui.BeginPublishSession(groupName)
                if this.config.ImagesBeforeText
                    this._SendRecordMedia(record, groupName)
            }
            entry := this.queue.Get(id)
            delivery := this._DeliveryOrDefault(entry, groupName)
        } else if this.config.ImagesBeforeText && !delivery["text_sent"]
            && !delivery["forward_sent"]
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

        if !this.config.ImagesBeforeText && !delivery["forward_sent"]
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
        mediaStatus := entry && entry.Has("media_status") ? entry["media_status"] : ""
        imageCount := record.Has("image_count") ? record["image_count"] : 0
        if mediaStatus = "none"
            return
        if files.Length && !this.media.IsTrusted(id)
            throw Error("Phòng " record["room_code"]
                . " có image cache cũ/chưa xác thực; cần capture lại.")

        if imageCount > 0 && this.config.MediaRequired && !files.Length
            throw Error("Phòng " record["room_code"] " chưa archive ảnh.")

        delivery := this._DeliveryOrDefault(entry, groupName)
        if delivery["forward_sent"]
            return

        startIndex := delivery["media_index_sent"] + 1
        if startIndex > files.Length
            return

        paths := []
        index := startIndex
        while index <= files.Length {
            paths.Push(this.media.Resolve(files[index]))
            index++
        }
        beforeSend := ObjBindMethod(
            this.queue, "MarkDeliveryIntent",
            [id], groupName, "media", files.Length)
        this.ui.PasteMediaBatchInSession(paths, beforeSend)
        this.queue.CheckpointMedia(id, groupName, files.Length)
    }

    _DeliveryOrDefault(entry, groupName) {
        if entry && entry.Has("deliveries") && entry["deliveries"].Has(groupName)
            return entry["deliveries"][groupName]
        return Map(
            "media_index_sent", 0, "text_sent", 0, "forward_sent", 0,
            "uncertain", 0, "last_action", "", "last_media_index", 0
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
