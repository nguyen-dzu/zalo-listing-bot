#Requires AutoHotkey v2.0
; Storage.ahk — Repository: JSON persistence for listings and phone-access audit

class ListingRepository {
    __New(config) {
        this.config := config
        this.listings := this._Load(config.ListingsFile)
        this.logs := this._Load(config.AccessLogFile)
    }

    _Load(path) {
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

    ; Persist one harvested listing. Returns the stored record.
    SaveListing(listing, sourceGroup := "", hash := "") {
        record := Map(
            "id", hash != "" ? hash : FnvHash(listing["raw_text"]),
            "source_group", sourceGroup,
            "captured_at", NowStamp(),
            "address", listing["address"],
            "room_code", listing["room_code"],
            "price", listing["price"],
            "electric_price", listing["electric_price"],
            "water_price", listing["water_price"],
            "utility_price", listing["utility_price"],
            "service_price", listing["service_price"],
            "owner_phone", listing["owner_phone"],
            "info", listing["info"],
            "extra_info", listing["extra_info"],
            "image_count", listing["image_count"],
            "raw_text", listing["raw_text"],
            "published", 0,
            "published_at", ""
        )

        existingIndex := this._IndexOf(record["id"])
        if existingIndex
            this.listings[existingIndex] := record
        else
            this.listings.Push(record)

        this.SaveAll()
        return record
    }

    _IndexOf(id) {
        for index, item in this.listings {
            if item.Has("id") && item["id"] = id
                return index
        }
        return 0
    }

    Pending() {
        result := []
        for item in this.listings {
            if !item.Has("published") || !item["published"]
                result.Push(item)
        }
        return result
    }

    MarkPublished(ids) {
        stamp := NowStamp()
        lookup := Map()
        for id in ids
            lookup[id] := true

        for item in this.listings {
            if item.Has("id") && lookup.Has(item["id"]) {
                item["published"] := 1
                item["published_at"] := stamp
            }
        }
        this.SaveAll()
    }

    ; Newest record wins when a room code was re-posted.
    GetByRoomCode(roomCode) {
        index := this.listings.Length
        while index >= 1 {
            candidate := this.listings[index]
            if candidate.Has("room_code") && StrLower(candidate["room_code"]) = StrLower(roomCode)
                return candidate
            index--
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
        WriteTextFile(this.config.ListingsFile, JSON.Stringify(this.listings))
    }
}
