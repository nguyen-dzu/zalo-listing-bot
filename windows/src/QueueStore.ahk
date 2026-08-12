#Requires AutoHotkey v2.0
; QueueStore.ahk — durable append-only publish queue with leases and checkpoints

class PublishQueueStore {
    __New(config, nowFn := 0) {
        this.config := config
        this.nowFn := nowFn
        this.dir := config.QueueDir
        this.eventsPath := config.QueueEventsFile
        this.snapshotPath := config.QueueSnapshotFile
        this.records := Map()
        this.statusIndex := Map()
        this.leaseIndex := Map()
        this.order := []
        this.nextSeq := 1
        this.eventsSinceSnapshot := 0
        this.compactEvery := config.QueueCompactEvery
        EnsureDir(this.dir)
        this.Load()
        this.ReclaimExpiredLeases()
        this.ExpireStale()
    }

    Load() {
        this.records := Map()
        this.statusIndex := Map()
        this.leaseIndex := Map()
        this.order := []
        this.nextSeq := 1
        this.eventsSinceSnapshot := 0

        raw := ReadTextFile(this.snapshotPath)
        if Trim(raw) != "" {
            normalizedSnapshot := NormalizeNewlines(raw)
            firstBreak := InStr(normalizedSnapshot, "`n")
            firstLine := Trim(firstBreak
                ? SubStr(normalizedSnapshot, 1, firstBreak - 1)
                : normalizedSnapshot)
            if InStr(firstLine, "queue_snapshot_jsonl") {
                lines := StrSplit(normalizedSnapshot, "`n")
                header := JSON.Parse(Trim(lines[1]))
                if header.Has("next_seq")
                    this.nextSeq := header["next_seq"]
                Loop lines.Length - 1 {
                    line := Trim(lines[A_Index + 1])
                    if line = ""
                        continue
                    this._PutEntry(JSON.Parse(line))
                }
            } else {
                try {
                    snapshot := JSON.Parse(raw)
                    if snapshot is Map {
                        if snapshot.Has("next_seq")
                            this.nextSeq := snapshot["next_seq"]
                        if snapshot.Has("records") && snapshot["records"] is Array {
                            for entry in snapshot["records"]
                                this._PutEntry(entry)
                        }
                    }
                }
            }
        }

        journal := ReadTextFile(this.eventsPath)
        if Trim(journal) = ""
            return

        validLines := []
        malformedTail := false
        lines := []
        for rawLine in StrSplit(NormalizeNewlines(journal), "`n") {
            if Trim(rawLine) != ""
                lines.Push(Trim(rawLine))
        }
        hasUnterminatedTail := SubStr(NormalizeNewlines(journal), -1) != "`n"
        for lineIndex, line in lines {
            line := Trim(line)
            try {
                event := JSON.Parse(line)
                if !(event is Map) || !event.Has("type")
                    throw Error("Queue event must be a map with type.")
                this._Apply(event)
                this.eventsSinceSnapshot++
                validLines.Push(line)
            } catch as err {
                if lineIndex = lines.Length && hasUnterminatedTail {
                    malformedTail := true
                    continue
                }
                throw Error(
                    "Queue journal hỏng tại line " lineIndex ": " err.Message)
            }
        }
        if malformedTail || hasUnterminatedTail {
            repaired := validLines.Length ? StrJoin(validLines, "`n") "`n" : ""
            WriteTextFile(this.eventsPath, repaired)
        }
    }

    Enqueue(record) {
        id := record["id"]
        if this.records.Has(id)
            return this.records[id]

        roomCode := record.Has("room_code") ? record["room_code"] : ""
        deferred := roomCode != "" ? this._SupersedeRoom(roomCode, id) : false

        needsMedia := record.Has("image_count") && record["image_count"] > 0
            && this.config.MediaRequired
        desiredStatus := needsMedia ? "media_pending" : "ready"
        entry := Map(
            "id", id,
            "room_code", roomCode,
            "queue_seq", this.nextSeq,
            "priority", record.Has("priority") ? record["priority"] : 0,
            "status", deferred ? "deferred" : desiredStatus,
            "desired_status", desiredStatus,
            "captured_at", record.Has("captured_at") ? record["captured_at"] : NowStamp(),
            "expires_at", this._ListingExpiry(record),
            "next_attempt_at", "",
            "attempt_count", 0,
            "lease_token", "",
            "lease_expires_at", "",
            "last_error", "",
            "media_files", [],
            "media_metadata", [],
            "media_status", needsMedia ? "pending" : "none",
            "deliveries", Map()
        )
        this.nextSeq++
        this._Append(Map("type", "enqueue", "entry", entry))
        return this.records[id]
    }

    Import(record, published := false) {
        entry := this.Enqueue(record)
        if published && entry["status"] != "completed"
            this.MarkCompleted([record["id"]])
        return this.records[record["id"]]
    }

    _SupersedeRoom(roomCode, newId) {
        ids := []
        hasActive := false
        for id in this.order {
            if id = newId || !this.records.Has(id)
                continue
            entry := this.records[id]
            if entry["room_code"] != roomCode
                continue
            if entry["status"] = "leased" || entry["status"] = "sending"
                || entry["status"] = "uncertain" {
                hasActive := true
                continue
            }
            if !this._Terminal(entry["status"])
                ids.Push(id)
        }
        if ids.Length
            this._Append(Map("type", "supersede", "ids", ids, "replacement_id", newId))
        return hasActive
    }

    AttachMedia(id, files, metadata := 0) {
        if !this.records.Has(id)
            throw Error("Listing is not in publish queue: " id)
        copied := []
        for file in files
            copied.Push(file)
        details := metadata is Array ? metadata : []
        this._Append(Map(
            "type", "media_attached",
            "id", id,
            "files", copied,
            "metadata", details
        ))
        return this.records[id]
    }

    InvalidateMedia(id, reason := "", required := true) {
        if !this.records.Has(id)
            return false
        this._Append(Map(
            "type", "media_invalidated",
            "id", id,
            "reason", reason,
            "required", required ? 1 : 0
        ))
        return true
    }

    LeaseNext(limit := 5) {
        this.ActivateDeferred()
        selected := []
        now := this._Now()

        ; Single pass over eligible records. The old implementation rescanned
        ; the entire ready index once per requested room, which made the
        ; 5,000-record stress path unnecessarily quadratic.
        candidates := []
        for statusName in ["ready", "retry_wait"] {
            if !this.statusIndex.Has(statusName)
                continue
            for id, unused in this.statusIndex[statusName] {
                if !this.records.Has(id)
                    continue
                entry := this.records[id]
                if !this._Eligible(entry, now)
                    continue
                inserted := false
                for index, candidateId in candidates {
                    candidate := this.records[candidateId]
                    if entry["priority"] > candidate["priority"]
                        || (entry["priority"] = candidate["priority"]
                            && entry["queue_seq"] < candidate["queue_seq"]) {
                        candidates.InsertAt(index, id)
                        inserted := true
                        break
                    }
                }
                if !inserted
                    candidates.Push(id)
                if candidates.Length > limit
                    candidates.Pop()
            }
        }
        selected := candidates

        if !selected.Length
            return Map("token", "", "ids", [])

        token := FnvHash(this._Now() ":" A_TickCount ":" StrJoin(selected, ","))
        timeoutSeconds := Ceil(this.config.LeaseTimeoutMs / 1000)
        expiresAt := DateAdd(this._Now(), timeoutSeconds, "Seconds")
        this._Append(Map(
            "type", "lease",
            "token", token,
            "ids", selected,
            "leased_at", this._Now(),
            "expires_at", expiresAt
        ))
        return Map("token", token, "ids", selected)
    }

    ActivateDeferred() {
        actions := []
        if !this.statusIndex.Has("deferred")
            return 0
        for id, unused in this.statusIndex["deferred"] {
            if !this.records.Has(id)
                continue
            entry := this.records[id]
            active := false
            superseded := []
            for otherId in this.order {
                if otherId = id || !this.records.Has(otherId)
                    continue
                other := this.records[otherId]
                if other["room_code"] != entry["room_code"]
                    continue
                if other["status"] = "leased" || other["status"] = "sending"
                    || other["status"] = "uncertain" {
                    active := true
                    break
                }
                if !this._Terminal(other["status"]) && other["status"] != "deferred"
                    superseded.Push(otherId)
            }
            if !active
                actions.Push(Map(
                    "id", id,
                    "status", entry["desired_status"],
                    "superseded_ids", superseded
                ))
        }
        if actions.Length
            this._Append(Map("type", "activate_deferred", "actions", actions))
        return actions.Length
    }

    MarkDeliveryIntent(ids, groupName, action, mediaIndex := 0) {
        deliveryId := FnvHash(
            this._Now() ":" A_TickCount ":" groupName ":" action ":"
            . mediaIndex ":" StrJoin(ids, ","))
        this._Append(Map(
            "type", "delivery_intent",
            "delivery_id", deliveryId,
            "ids", ids,
            "group", groupName,
            "action", action,
            "media_index", mediaIndex
        ))
        return deliveryId
    }

    CheckpointMedia(id, groupName, mediaIndex) {
        this._Append(Map(
            "type", "media_sent",
            "id", id,
            "group", groupName,
            "media_index", mediaIndex
        ))
    }

    CheckpointText(ids, groupName) {
        this._Append(Map(
            "type", "text_sent",
            "ids", ids,
            "group", groupName
        ))
    }

    CompleteLease(token) {
        ids := this._IdsForLease(token)
        this.MarkCompleted(ids, token)
        return ids.Length
    }

    MarkCompleted(ids, token := "") {
        if ids.Length
            this._Append(Map(
                "type", "complete",
                "token", token,
                "ids", ids,
                "completed_at", NowStamp()
            ))
    }

    FailLease(token, errorMessage) {
        updates := []
        now := this._Now()
        for id in this._IdsForLease(token) {
            entry := this.records[id]
            attempts := entry["attempt_count"] + 1
            status := this._HasUncertain(entry)
                ? "uncertain"
                : (attempts >= this.config.MaxPublishAttempts
                    ? "dead_letter" : "retry_wait")
            nextAt := status = "retry_wait"
                ? DateAdd(now, this.config.RetryBackoffSeconds * attempts, "Seconds")
                : ""
            updates.Push(Map(
                "id", id,
                "status", status,
                "attempt_count", attempts,
                "next_attempt_at", nextAt
            ))
        }
        if updates.Length
            this._Append(Map(
                "type", "fail",
                "token", token,
                "updates", updates,
                "error", errorMessage
            ))
    }

    ReleaseLease(token) {
        ids := this._IdsForLease(token)
        this.ReleaseIds(ids)
        return ids.Length
    }

    ReleaseIds(ids) {
        if ids.Length
            this._Append(Map("type", "reclaim", "ids", ids))
    }

    DeadLetter(ids, errorMessage) {
        updates := []
        for id in ids {
            if !this.records.Has(id)
                continue
            entry := this.records[id]
            updates.Push(Map(
                "id", id,
                "status", "dead_letter",
                "attempt_count", entry["attempt_count"] + 1,
                "next_attempt_at", ""
            ))
        }
        if updates.Length
            this._Append(Map(
                "type", "fail",
                "token", "",
                "updates", updates,
                "error", errorMessage
            ))
    }

    ReclaimExpiredLeases() {
        now := this._Now()
        ids := []
        uncertainIds := []
        for id in this.order {
            if !this.records.Has(id)
                continue
            entry := this.records[id]
            if entry["status"] != "leased" && entry["status"] != "sending"
                continue
            if entry["lease_expires_at"] = "" || entry["lease_expires_at"] > now
                continue
            if this._HasUncertain(entry)
                uncertainIds.Push(id)
            else
                ids.Push(id)
        }
        if uncertainIds.Length
            this._Append(Map("type", "mark_uncertain", "ids", uncertainIds))
        if ids.Length
            this._Append(Map("type", "reclaim", "ids", ids))
        return ids.Length + uncertainIds.Length
    }

    ExpireStale() {
        now := this._Now()
        ids := []
        for id in this.order {
            if !this.records.Has(id)
                continue
            entry := this.records[id]
            status := entry["status"]
            if this._Terminal(status) || status = "leased"
                || status = "sending" || status = "uncertain"
                continue
            if entry["expires_at"] != "" && entry["expires_at"] < now
                ids.Push(id)
        }
        if ids.Length
            this._Append(Map("type", "expire", "ids", ids))
        return ids.Length
    }

    ResolveUncertain(id, retry := true) {
        if !this.records.Has(id)
            return false
        entry := this.records[id]
        if entry["status"] != "uncertain" && !this._HasUncertain(entry)
            return false
        for group, delivery in entry["deliveries"] {
            if delivery["uncertain"] {
                deliveryId := delivery.Has("delivery_id")
                    && delivery["delivery_id"] != ""
                    ? delivery["delivery_id"] : "legacy:" id ":" group
                return this.ResolveUncertainDelivery(
                    deliveryId, retry)
            }
        }
        return false
    }

    UncertainDeliveries() {
        grouped := Map()
        for id in this.order {
            if !this.records.Has(id)
                continue
            entry := this.records[id]
            for group, delivery in entry["deliveries"] {
                if !delivery["uncertain"]
                    continue
                deliveryId := delivery.Has("delivery_id")
                    && delivery["delivery_id"] != ""
                    ? delivery["delivery_id"] : "legacy:" id ":" group
                if !grouped.Has(deliveryId) {
                    grouped[deliveryId] := Map(
                        "delivery_id", deliveryId,
                        "ids", [],
                        "group", group,
                        "action", delivery["last_action"],
                        "media_index", delivery["last_media_index"]
                    )
                }
                grouped[deliveryId]["ids"].Push(id)
            }
        }
        result := []
        for deliveryId, item in grouped
            result.Push(item)
        return result
    }

    ResolveUncertainDelivery(deliveryId, retry := true) {
        ids := []
        for item in this.UncertainDeliveries() {
            if item["delivery_id"] = deliveryId {
                ids := item["ids"]
                break
            }
        }
        if !ids.Length
            return false
        this._Append(Map(
            "type", "resolve_uncertain_delivery",
            "delivery_id", deliveryId,
            "ids", ids,
            "choice", retry ? "retry" : "skip"
        ))
        return true
    }

    Get(id) {
        return this.records.Has(id) ? this.records[id] : false
    }

    GetMany(ids) {
        result := []
        for id in ids {
            if this.records.Has(id)
                result.Push(this.records[id])
        }
        return result
    }

    PendingIds() {
        result := []
        for id in this.order {
            if !this.records.Has(id)
                continue
            status := this.records[id]["status"]
            if status = "ready" || status = "retry_wait" || status = "media_pending"
                result.Push(id)
        }
        return result
    }

    UncertainEntries() {
        result := []
        for id in this.order {
            if this.records.Has(id) && this.records[id]["status"] = "uncertain"
                result.Push(this.records[id])
        }
        return result
    }

    Stats() {
        stats := Map(
            "ready", 0, "media_pending", 0, "leased", 0, "sending", 0,
            "completed", 0, "retry_wait", 0, "dead_letter", 0,
            "uncertain", 0, "deferred", 0, "superseded", 0,
            "expired", 0, "total", 0
        )
        for id in this.order {
            if !this.records.Has(id)
                continue
            status := this.records[id]["status"]
            stats["total"]++
            if stats.Has(status)
                stats[status]++
        }
        return stats
    }

    AllEntries() {
        result := []
        for id in this.order {
            if this.records.Has(id)
                result.Push(this.records[id])
        }
        return result
    }

    MediaPendingEntries(limit := 0) {
        result := []
        for id in this.order {
            if !this.records.Has(id)
                continue
            entry := this.records[id]
            if entry["status"] != "media_pending"
                continue
            result.Push(entry)
            if limit > 0 && result.Length >= limit
                break
        }
        return result
    }

    Compact() {
        ; JSONL snapshot v2 keeps each record independently parseable. Parsing
        ; one giant pretty-printed JSON array became the dominant cost at
        ; 5,000 rooms; legacy v1 snapshots remain readable in Load().
        lines := [this._JsonLine(Map(
            "format", "queue_snapshot_jsonl",
            "version", 2,
            "created_at", NowStamp(),
            "next_seq", this.nextSeq
        ))]
        for id in this.order {
            if this.records.Has(id)
                lines.Push(this._JsonLine(this.records[id]))
        }
        WriteTextFile(this.snapshotPath, StrJoin(lines, "`n") "`n")
        WriteTextFile(this.eventsPath, "")
        this.eventsSinceSnapshot := 0
    }

    _Append(event) {
        event["at"] := this._Now()
        EnsureDir(this.dir)
        FileAppend this._JsonLine(event) "`n", this.eventsPath, "UTF-8-RAW"
        this._Apply(event)
        this.eventsSinceSnapshot++
        if this.compactEvery > 0 && this.eventsSinceSnapshot >= this.compactEvery
            this.Compact()
    }

    _Apply(event) {
        if !event.Has("type")
            return
        eventType := event["type"]

        switch eventType {
            case "enqueue":
                this._PutEntry(event["entry"])
                this.nextSeq := Max(this.nextSeq, event["entry"]["queue_seq"] + 1)

            case "supersede":
                for id in event["ids"] {
                    if this.records.Has(id) {
                        entry := this.records[id]
                        this._SetStatus(entry, "superseded")
                        entry["lease_token"] := ""
                    }
                }

            case "activate_deferred":
                for action in event["actions"] {
                    for oldId in action["superseded_ids"] {
                        if this.records.Has(oldId)
                            this._SetStatus(this.records[oldId], "superseded")
                    }
                    if this.records.Has(action["id"])
                        this._SetStatus(
                            this.records[action["id"]], action["status"])
                }

            case "media_attached":
                if this.records.Has(event["id"]) {
                    entry := this.records[event["id"]]
                    entry["media_files"] := event["files"]
                    entry["media_metadata"] := event.Has("metadata")
                        ? event["metadata"] : []
                    entry["media_status"] := "ready"
                    entry["desired_status"] := "ready"
                    if entry["status"] = "media_pending"
                        this._SetStatus(entry, "ready")
                }

            case "media_invalidated":
                if this.records.Has(event["id"]) {
                    entry := this.records[event["id"]]
                    entry["media_files"] := []
                    entry["media_metadata"] := []
                    required := !event.Has("required") || event["required"]
                    entry["media_status"] := required ? "pending" : "none"
                    entry["desired_status"] := required ? "media_pending" : "ready"
                    entry["last_error"] := event.Has("reason")
                        ? event["reason"] : ""
                    if entry["status"] = "ready"
                        || entry["status"] = "retry_wait"
                        || entry["status"] = "media_pending"
                        this._SetStatus(entry,
                            required ? "media_pending" : "ready")
                }

            case "lease":
                leasedIds := []
                for id in event["ids"] {
                    if this.records.Has(id) {
                        entry := this.records[id]
                        this._SetStatus(entry, "leased")
                        entry["lease_token"] := event["token"]
                        entry["lease_expires_at"] := event["expires_at"]
                        entry["last_error"] := ""
                        leasedIds.Push(id)
                    }
                }
                this.leaseIndex[event["token"]] := leasedIds

            case "delivery_intent":
                legacyDeliveryId := FnvHash(
                    "legacy:" event["group"] ":" event["action"] ":"
                    . event["media_index"] ":" StrJoin(event["ids"], ","))
                for id in event["ids"] {
                    if !this.records.Has(id)
                        continue
                    entry := this.records[id]
                    delivery := this._Delivery(entry, event["group"])
                    delivery["uncertain"] := 1
                    delivery["delivery_id"] := event.Has("delivery_id")
                        ? event["delivery_id"] : legacyDeliveryId
                    delivery["last_action"] := event["action"]
                    delivery["last_media_index"] := event["media_index"]
                    this._SetStatus(entry, "sending")
                }

            case "media_sent":
                if this.records.Has(event["id"]) {
                    delivery := this._Delivery(this.records[event["id"]], event["group"])
                    delivery["media_index_sent"] := Max(
                        delivery["media_index_sent"], event["media_index"])
                    delivery["uncertain"] := 0
                    delivery["delivery_id"] := ""
                    delivery["last_action"] := ""
                }

            case "text_sent":
                for id in event["ids"] {
                    if !this.records.Has(id)
                        continue
                    delivery := this._Delivery(this.records[id], event["group"])
                    delivery["text_sent"] := 1
                    delivery["uncertain"] := 0
                    delivery["delivery_id"] := ""
                    delivery["last_action"] := ""
                }

            case "complete":
                for id in event["ids"] {
                    if this.records.Has(id) {
                        entry := this.records[id]
                        this._SetStatus(entry, "completed")
                        entry["lease_token"] := ""
                        entry["lease_expires_at"] := ""
                        entry["completed_at"] := event.Has("completed_at")
                            ? event["completed_at"] : NowStamp()
                    }
                }
                if event.Has("token") && this.leaseIndex.Has(event["token"])
                    this.leaseIndex.Delete(event["token"])

            case "fail":
                for update in event["updates"] {
                    if !this.records.Has(update["id"])
                        continue
                    entry := this.records[update["id"]]
                    this._SetStatus(entry, update["status"])
                    entry["attempt_count"] := update["attempt_count"]
                    entry["next_attempt_at"] := update["next_attempt_at"]
                    entry["last_error"] := event["error"]
                    entry["lease_token"] := ""
                    entry["lease_expires_at"] := ""
                }
                if event.Has("token") && this.leaseIndex.Has(event["token"])
                    this.leaseIndex.Delete(event["token"])

            case "reclaim":
                for id in event["ids"] {
                    if this.records.Has(id) {
                        entry := this.records[id]
                        this._SetStatus(entry, "ready")
                        entry["lease_token"] := ""
                        entry["lease_expires_at"] := ""
                    }
                }

            case "mark_uncertain":
                for id in event["ids"] {
                    if this.records.Has(id)
                        this._SetStatus(this.records[id], "uncertain")
                }

            case "expire":
                for id in event["ids"] {
                    if this.records.Has(id)
                        this._SetStatus(this.records[id], "expired")
                }

            case "resolve_uncertain":
                if this.records.Has(event["id"]) {
                    entry := this.records[event["id"]]
                    for group, delivery in entry["deliveries"] {
                        if !delivery["uncertain"]
                            continue
                        if event["choice"] = "skip" {
                            if delivery["last_action"] = "text"
                                delivery["text_sent"] := 1
                            else if delivery["last_action"] = "media"
                                delivery["media_index_sent"] := Max(
                                    delivery["media_index_sent"],
                                    delivery["last_media_index"])
                        }
                        delivery["uncertain"] := 0
                        delivery["delivery_id"] := ""
                        delivery["last_action"] := ""
                    }
                    this._SetStatus(entry, "ready")
                    entry["lease_token"] := ""
                    entry["lease_expires_at"] := ""
                }

            case "resolve_uncertain_delivery":
                for id in event["ids"] {
                    if !this.records.Has(id)
                        continue
                    entry := this.records[id]
                    for group, delivery in entry["deliveries"] {
                        currentDeliveryId := delivery.Has("delivery_id")
                            && delivery["delivery_id"] != ""
                            ? delivery["delivery_id"] : "legacy:" id ":" group
                        if !delivery["uncertain"]
                            || currentDeliveryId != event["delivery_id"]
                            continue
                        if event["choice"] = "skip" {
                            if delivery["last_action"] = "text"
                                delivery["text_sent"] := 1
                            else if delivery["last_action"] = "media"
                                delivery["media_index_sent"] := Max(
                                    delivery["media_index_sent"],
                                    delivery["last_media_index"])
                        }
                        delivery["uncertain"] := 0
                        delivery["delivery_id"] := ""
                        delivery["last_action"] := ""
                    }
                    this._SetStatus(entry, "ready")
                    entry["lease_token"] := ""
                    entry["lease_expires_at"] := ""
                }
        }
    }

    _PutEntry(entry) {
        if !(entry is Map) || !entry.Has("id")
            return
        id := entry["id"]
        if !entry.Has("deliveries") || !(entry["deliveries"] is Map)
            entry["deliveries"] := Map()
        if !entry.Has("media_files") || !(entry["media_files"] is Array)
            entry["media_files"] := []
        if !entry.Has("media_metadata") || !(entry["media_metadata"] is Array)
            entry["media_metadata"] := []
        if !entry.Has("desired_status")
            entry["desired_status"] := entry["media_status"] = "pending"
                ? "media_pending" : "ready"
        if this.records.Has(id)
            this._IndexRemove(this.records[id]["status"], id)
        else
            this.order.Push(id)
        this.records[id] := entry
        this._IndexAdd(entry["status"], id)
        if entry.Has("lease_token") && entry["lease_token"] != "" {
            token := entry["lease_token"]
            if !this.leaseIndex.Has(token)
                this.leaseIndex[token] := []
            this.leaseIndex[token].Push(id)
        }
    }

    _SetStatus(entry, status) {
        oldStatus := entry["status"]
        if oldStatus = status
            return
        this._IndexRemove(oldStatus, entry["id"])
        entry["status"] := status
        this._IndexAdd(status, entry["id"])
    }

    _IndexAdd(status, id) {
        if !this.statusIndex.Has(status)
            this.statusIndex[status] := Map()
        this.statusIndex[status][id] := true
    }

    _IndexRemove(status, id) {
        if this.statusIndex.Has(status) && this.statusIndex[status].Has(id)
            this.statusIndex[status].Delete(id)
    }

    _Delivery(entry, groupName) {
        if !entry["deliveries"].Has(groupName) {
            entry["deliveries"][groupName] := Map(
                "media_index_sent", 0,
                "text_sent", 0,
                "uncertain", 0,
                "delivery_id", "",
                "last_action", "",
                "last_media_index", 0
            )
        }
        return entry["deliveries"][groupName]
    }

    _Eligible(entry, now) {
        status := entry["status"]
        if status != "ready" && status != "retry_wait"
            return false
        if entry["next_attempt_at"] != "" && entry["next_attempt_at"] > now
            return false
        if entry["expires_at"] != "" && entry["expires_at"] < now
            return false
        return true
    }

    _ListingExpiry(record) {
        if this.config.ListingTtlDays <= 0
            return ""
        base := this._Now()
        if record.Has("captured_at") {
            captured := RegExReplace(record["captured_at"], "\D", "")
            if StrLen(captured) >= 14
                base := SubStr(captured, 1, 14)
        }
        return DateAdd(base, this.config.ListingTtlDays, "Days")
    }

    _IdsForLease(token) {
        if this.leaseIndex.Has(token) {
            indexed := []
            for id in this.leaseIndex[token] {
                if this.records.Has(id)
                    && this.records[id]["lease_token"] = token
                    indexed.Push(id)
            }
            return indexed
        }
        ids := []
        for id in this.order {
            if this.records.Has(id) && this.records[id]["lease_token"] = token
                ids.Push(id)
        }
        return ids
    }

    _HasUncertain(entry) {
        for group, delivery in entry["deliveries"] {
            if delivery["uncertain"]
                return true
        }
        return false
    }

    _Terminal(status) {
        return status = "completed" || status = "superseded"
            || status = "expired" || status = "dead_letter"
    }

    _Now() {
        return this.nowFn ? this.nowFn.Call() : CompactStamp()
    }

    _JsonLine(value) {
        line := JSON.Stringify(value, "")
        return StrReplace(StrReplace(line, "`r", ""), "`n", "")
    }
}
