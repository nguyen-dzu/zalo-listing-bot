#Requires AutoHotkey v2.0
#Include Parser.ahk
; Storage.ahk — Repository: per-listing JSON persistence and phone-access audit

class ListingRepository {
    __New(config, queueStore := 0) {
        this.config := config
        this.queue := queueStore
        this.listingsDir := config.ListingsDir
        this.listings := []
        this.byId := Map()
        this.logs := this._LoadArray(config.AccessLogFile)
        EnsureDir(this.listingsDir)
        this._LoadListings()
        this._MigrateLegacy()
        this._SortListings()
        this._SyncQueue()
    }

    _LoadArray(path) {
        raw := ReadTextFile(path)
        if Trim(raw) = ""
            return []
        try {
            parsed := JSON.Parse(raw)
        } catch {
            return []
        }
        return parsed is Array ? parsed : []
    }

    _LoadListings() {
        Loop Files this.listingsDir "\*.json", "F" {
            raw := ReadTextFile(A_LoopFileFullPath)
            if Trim(raw) = ""
                continue
            try {
                record := JSON.Parse(raw)
                if record is Map && record.Has("id")
                    this._StoreInMemory(record)
            }
        }
    }

    _MigrateLegacy() {
        legacy := this._LoadArray(this.config.ListingsFile)
        migrated := 0
        for record in legacy {
            if !(record is Map) || !record.Has("id") || this.byId.Has(record["id"])
                continue
            this._WriteRecord(record)
            this._StoreInMemory(record)
            migrated++
        }
        if migrated
            WriteTextFile(this.listingsDir "\migration.done",
                NowStamp() " — migrated " migrated " records from listings.json")
    }

    _SyncQueue() {
        if !this.queue
            return
        for record in this.listings {
            published := record.Has("published") && record["published"]
            this.queue.Import(record, published)
        }
        this.queue.ExpireStale()
    }

    _SortListings() {
        sorted := []
        for record in this.listings {
            inserted := false
            key := this._SortKey(record)
            for index, current in sorted {
                if StrCompare(key, this._SortKey(current)) < 0 {
                    sorted.InsertAt(index, record)
                    inserted := true
                    break
                }
            }
            if !inserted
                sorted.Push(record)
        }
        this.listings := sorted
        this.byId := Map()
        for record in this.listings
            this.byId[record["id"]] := record
    }

    _SortKey(record) {
        captured := record.Has("captured_at")
            ? RegExReplace(record["captured_at"], "\D", "") : ""
        return Format("{:014}", captured = "" ? 0 : Integer(captured))
            . ":" record["id"]
    }

    ; Persist one harvested listing. Returns the stored record.
    SaveListing(listing, sourceGroup := "", hash := "") {
        contentHash := hash != "" ? hash : FnvHash(listing["raw_text"])
        id := ListingRepository.BuildListingId(sourceGroup, contentHash)
        roomCode := ListingParser.NormalizeRoomCode(listing, id)
        record := Map(
            "id", id,
            "content_hash", contentHash,
            "source_group", sourceGroup,
            "captured_at", NowStamp(),
            "address", listing["address"],
            "room_code", roomCode,
            "price", listing["price"],
            "electric_price", listing["electric_price"],
            "water_price", listing["water_price"],
            "utility_price", listing["utility_price"],
            "service_price", listing["service_price"],
            "owner_phone", listing["owner_phone"],
            "info", listing["info"],
            "extra_info", listing["extra_info"],
            "image_count", listing["image_count"],
            "raw_text", listing["raw_text"]
        )

        existingIndex := this._IndexOf(record["id"])
        if existingIndex {
            this.listings[existingIndex] := record
            this.byId[record["id"]] := record
        } else {
            this.listings.Push(record)
            this.byId[record["id"]] := record
        }
        this._WriteRecord(record)
        if this.queue
            this.queue.Enqueue(record)
        return record
    }

    static BuildListingId(sourceGroup, contentHash) {
        sourceKey := StrLower(Trim(sourceGroup))
        sourceKey := StrReplace(sourceKey, Chr(0xFE0F), "")
        sourceKey := RegExReplace(sourceKey, "\s+", " ")
        return FnvHash(sourceKey "|" contentHash)
    }

    _IndexOf(id) {
        for index, item in this.listings {
            if item.Has("id") && item["id"] = id
                return index
        }
        return 0
    }

    Pending() {
        if this.queue {
            result := []
            for id in this.queue.PendingIds() {
                if this.byId.Has(id)
                    result.Push(this.byId[id])
            }
            return result
        }
        result := []
        for item in this.listings {
            if !item.Has("published") || !item["published"]
                result.Push(item)
        }
        return result
    }

    MarkPublished(ids) {
        if this.queue {
            this.queue.MarkCompleted(ids)
            this.MarkPublishedLocal(ids)
            return
        }
        this.MarkPublishedLocal(ids)
    }

    MarkPublishedLocal(ids) {
        stamp := NowStamp()
        lookup := Map()
        for id in ids
            lookup[id] := true

        for item in this.listings {
            if item.Has("id") && lookup.Has(item["id"]) {
                item["published"] := 1
                item["published_at"] := stamp
                this._WriteRecord(item)
            }
        }
    }

    Get(id) {
        return this.byId.Has(id) ? this.byId[id] : false
    }

    GetMany(ids) {
        result := []
        for id in ids {
            if this.byId.Has(id)
                result.Push(this.byId[id])
        }
        return result
    }

    ; Newest record wins when a room code was re-posted.
    GetByRoomCode(roomCode) {
        target := ListingParser.NormalizeRoomCode(Map("room_code", roomCode), roomCode)
        if target = ""
            return false

        index := this.listings.Length
        while index >= 1 {
            candidate := this.listings[index]
            index--
            if !candidate.Has("room_code")
                continue
            candidateCode := ListingParser.NormalizeRoomCode(
                candidate, candidate.Has("id") ? candidate["id"] : "")
            if StrLower(candidateCode) = StrLower(target)
                return candidate
        }
        return false
    }

    LogPhoneAccess(roomCode, requestText := "") {
        this.logs.Push(Map(
            "room_code", roomCode,
            "requested_at", NowStamp(),
            "request_text", requestText
        ))
        WriteTextFile(this.config.AccessLogFile, JSON.Stringify(this.logs))
    }

    SaveAll() {
        for record in this.listings
            this._WriteRecord(record)
    }

    _WriteRecord(record) {
        WriteTextFile(this._RecordPath(record["id"]), JSON.Stringify(record))
    }

    _RecordPath(id) {
        safe := RegExReplace(id, "[^A-Za-z0-9_.-]", "_")
        return this.listingsDir "\" safe ".json"
    }

    _StoreInMemory(record) {
        id := record["id"]
        if this.byId.Has(id) {
            index := this._IndexOf(id)
            if index
                this.listings[index] := record
        } else {
            this.listings.Push(record)
        }
        this.byId[id] := record
    }
}
