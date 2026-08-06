#Requires AutoHotkey v2.0
; Composer.ahk — Builder: group harvested listings into separator-delimited chunks

class MessageComposer {
    __New(config) {
        this.config := config
    }

    Separator(groupName) {
        return StrReplace(this.config.Separator, "{group}", groupName)
    }

    ; records: array of stored listing Maps.
    ; Returns array of message strings, each under MaxMessageChars.
    Compose(records) {
        if !records.Length
            return []

        chunks := []
        current := ""
        lastGroup := ""

        for record in records {
            group := record.Has("source_group") ? record["source_group"] : ""
            block := this.RenderBlock(record)

            pieces := []
            if group != lastGroup
                pieces.Push(this.Separator(group))
            pieces.Push(block)
            addition := StrJoin(pieces, "`n")

            candidate := current = "" ? addition : current "`n`n" addition
            if StrLen(candidate) > this.config.MaxMessageChars && current != "" {
                chunks.Push(current)
                ; new chunk always re-prints the separator for context
                current := StrJoin([this.Separator(group), block], "`n")
            } else {
                current := candidate
            }
            lastGroup := group
        }

        if current != ""
            chunks.Push(current)
        return chunks
    }

    RenderBlock(record) {
        listing := Map()
        for key in ["address", "room_code", "price", "electric_price", "water_price", "utility_price", "service_price", "owner_phone", "info", "extra_info"]
            listing[key] := record.Has(key) ? record[key] : ""

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
}
