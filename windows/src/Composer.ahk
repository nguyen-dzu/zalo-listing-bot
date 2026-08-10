#Requires AutoHotkey v2.0
; Composer.ahk — Builder: batch listings into outbound Zalo messages

class MessageComposer {
    __New(config) {
        this.config := config
    }

    Separator(groupName) {
        return StrReplace(this.config.Separator, "{group}", groupName)
    }

    ListingSeparator() {
        if this.config.HasProp("ListingSeparator") && this.config.ListingSeparator != ""
            return this.config.ListingSeparator
        return "======================="
    }

    ListingsPerMessage() {
        if this.config.HasProp("OneMessagePerListing") && this.config.OneMessagePerListing
            return 1
        if this.config.HasProp("LeaseSize")
            return Max(1, this.config.LeaseSize)
        if this.config.HasProp("ListingsPerMessage")
            return Max(1, this.config.ListingsPerMessage)
        return 5
    }

    ; records → array of message strings (default: ListingsPerMessage rooms each).
    Compose(records) {
        if !records.Length
            return []

        batchSize := this.ListingsPerMessage()
        messages := []
        batch := []

        for record in records {
            batch.Push(record)
            if batch.Length >= batchSize {
                messages.Push(this.ComposeBatch(batch))
                batch := []
            }
        }
        if batch.Length
            messages.Push(this.ComposeBatch(batch))
        return messages
    }

    ; One Zalo message: room1 + separator + room2 + … (up to batch size).
    ComposeBatch(records) {
        if !records.Length
            return ""

        blocks := []
        for record in records
            blocks.Push(this.RenderBlock(record))

        body := StrJoin(blocks, "`n" this.ListingSeparator() "`n")

        if this.config.HasProp("IncludeGroupHeader") && this.config.IncludeGroupHeader {
            group := records[1].Has("source_group") ? records[1]["source_group"] : ""
            if group != ""
                return StrJoin([this.Separator(group), body], "`n")
        }
        return body
    }

    ComposeOne(record) {
        return this.ComposeBatch([record])
    }

    RenderBlock(record) {
        listing := Map()
        for key in ["address", "room_code", "price", "electric_price", "water_price", "utility_price", "service_price", "owner_phone", "info", "extra_info"]
            listing[key] := record.Has(key) ? record[key] : ""

        hash := record.Has("id") ? record["id"] : ""
        listing["room_code"] := ListingParser.NormalizeRoomCode(listing, hash)

        return ListingParser.FormatBlock(listing, this.config.MaskPhone, this.config.PhoneHint)
    }

    CollectIds(records) {
        ids := []
        for record in records {
            if record.Has("id")
                ids.Push(record["id"])
        }
        return ids
    }

    ; Split records into publish batches (same size as Compose()).
    BatchRecords(records) {
        batchSize := this.ListingsPerMessage()
        batches := []
        batch := []
        for record in records {
            batch.Push(record)
            if batch.Length >= batchSize {
                batches.Push(batch)
                batch := []
            }
        }
        if batch.Length
            batches.Push(batch)
        return batches
    }
}
