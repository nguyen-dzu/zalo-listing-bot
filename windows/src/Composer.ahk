#Requires AutoHotkey v2.0
#Include Parser.ahk
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
        return "======="
    }

    ListingsPerMessage() {
        return 1
    }

    ; records → one Zalo text message per room.
    Compose(records) {
        if !records.Length
            return []

        messages := []
        for record in records
            messages.Push(this.ComposeOne(record))
        return messages
    }

    ; One Zalo text message for the given rooms (publish path uses one room).
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
        for key in ["address", "room_code", "price", "electric_price", "water_price",
            "utility_price", "service_price", "owner_phone", "phone_carrier",
            "info", "extra_info", "raw_text", "source_group", "id"]
            listing[key] := record.Has(key) ? record[key] : ""

        listing["room_code"] := ListingParser.NormalizeRoomCode(listing, "")
        if listing["owner_phone"] != "" && listing["phone_carrier"] = ""
            listing["phone_carrier"] := ListingParser.ClassifyCarrier(
                listing["owner_phone"])

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

    ; Split records into publish batches (one room each).
    BatchRecords(records) {
        batches := []
        for record in records
            batches.Push([record])
        return batches
    }
}
