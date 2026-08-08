#Requires AutoHotkey v2.0
; Harvester.ahk — Service: read source groups, drop blocked/duplicate posts, persist new listings

class MessageHarvester {
    __New(config, ui, registry, blockList, stateStore, repository) {
        this.config := config
        this.ui := ui
        this.registry := registry
        this.blockList := blockList
        this.state := stateStore
        this.repo := repository
    }

    _EmptySummary() {
        return Map(
            "groups", 0, "batches", 0, "saved", 0, "blocked", 0,
            "duplicate", 0, "invalid", 0, "published", 0,
            "revisit", 0, "errors", []
        )
    }

    _MergeSummary(total, part) {
        for key in ["groups", "batches", "saved", "blocked", "duplicate", "invalid", "published", "revisit"]
            total[key] += part[key]
        for err in part["errors"]
            total["errors"].Push(err)
        return total
    }

    ; Harvest every enabled source group. Returns a summary Map.
    HarvestAll() {
        summary := this._EmptySummary()
        for group in this.registry.SourceGroups() {
            summary["groups"]++
            try {
                result := this.HarvestGroup(group["group_name"])
                summary["saved"] += result["saved"]
                summary["blocked"] += result["blocked"]
                summary["duplicate"] += result["duplicate"]
                summary["invalid"] += result["invalid"]
            } catch as err {
                summary["errors"].Push(group["group_name"] ": " err.Message)
            }
            Sleep this.config.BetweenGroupsMs
        }
        this.state.Save()
        return summary
    }

    ; Harvest source groups in batches of BatchSize, publish after each batch,
    ; then recheck conversation snapshot for new messages (revisit queue).
    HarvestAllBatched(publishFn) {
        summary := this._EmptySummary()
        sources := this.registry.SourceGroups()
        batchSize := this.config.BatchSize

        revisitNames := this.state.ListRevisitGroups()
        if revisitNames.Length {
            batch := this._NamesToGroups(revisitNames, sources)
            if batch.Length
                this._MergeSummary(summary, this._RunBatch(batch, publishFn, true))
        }

        index := 1
        while index <= sources.Length {
            batch := []
            while batch.Length < batchSize && index <= sources.Length {
                group := sources[index]
                if !this._GroupInBatch(group, batch)
                    batch.Push(group)
                index++
            }
            if batch.Length
                this._MergeSummary(summary, this._RunBatch(batch, publishFn, false))
            if index <= sources.Length
                Sleep this.config.BetweenBatchesMs
        }

        this.state.Save()
        return summary
    }

    _GroupInBatch(group, batch) {
        for item in batch {
            if item["group_name"] = group["group_name"]
                return true
        }
        return false
    }

    _NamesToGroups(names, sources) {
        lookup := Map()
        for group in sources
            lookup[group["group_name"]] := group
        batch := []
        for name in names {
            if lookup.Has(name)
                batch.Push(lookup[name])
        }
        return batch
    }

    _RunBatch(groups, publishFn, isRevisit) {
        part := this._EmptySummary()
        part["batches"] := 1
        savedRecords := []

        for group in groups {
            part["groups"]++
            try {
                result := this.HarvestGroup(group["group_name"])
                part["saved"] += result["saved"]
                part["blocked"] += result["blocked"]
                part["duplicate"] += result["duplicate"]
                part["invalid"] += result["invalid"]
                for record in result["saved_records"]
                    savedRecords.Push(record)
            } catch as err {
                part["errors"].Push(group["group_name"] ": " err.Message)
            }
            Sleep this.config.BetweenGroupsMs
        }

        this.state.Save()

        if savedRecords.Length && publishFn {
            try {
                publishFn(savedRecords)
                part["published"] += savedRecords.Length
            } catch as err {
                part["errors"].Push("publish: " err.Message)
            }
            if this.config.RecheckAfterPublish
                Sleep this.config.AfterPublishRecheckMs
        }

        if this.config.RecheckAfterPublish {
            for group in groups {
                try {
                    if this._RecheckForNewMessages(group["group_name"])
                        part["revisit"]++
                } catch as err {
                    part["errors"].Push("recheck " group["group_name"] ": " err.Message)
                }
            }
        }

        if isRevisit {
            for group in groups
                this.state.MarkNeedsRevisit(group["group_name"], false)
        }

        this.state.Save()
        return part
    }

    ; Lightweight re-read after publish: if conversation hash changed, queue for next pass.
    _RecheckForNewMessages(groupName) {
        this.ui.OpenGroup(groupName, "read")
        settle := this.config.HasProp("CaptureSettleMs") ? this.config.CaptureSettleMs : 600
        Sleep settle
        text := this.ui.CaptureConversationText()
        hash := FnvHash(NormalizeNewlines(text))
        if this.state.HasCaptureChanged(groupName, hash) {
            this.state.MarkNeedsRevisit(groupName, true)
            return true
        }
        return false
    }

    HarvestGroup(groupName) {
        result := Map(
            "saved", 0, "blocked", 0, "duplicate", 0, "invalid", 0, "saved_records", []
        )

        this.ui.OpenGroup(groupName, "read")
        settle := this.config.HasProp("CaptureSettleMs") ? this.config.CaptureSettleMs : 600
        Sleep settle
        text := this.ui.CaptureConversationText()
        normalized := NormalizeNewlines(text)
        if Trim(normalized) = ""
            return result

        captureHash := FnvHash(normalized)
        this.state.SetCaptureHash(groupName, captureHash)
        this.state.MarkNeedsRevisit(groupName, false)

        blocks := ListingParser.SplitBlocks(
            normalized, this.config.ListingStartPattern, this.config.ImageMarkerPattern
        )
        count := 0

        for block in blocks {
            if count >= this.config.MaxMessagesPerGroup
                break
            count++

            hash := FnvHash(block)
            if this.state.IsSeen(groupName, hash) {
                result["duplicate"]++
                continue
            }

            keyword := this.blockList.Match(block)
            if keyword != "" {
                this.state.MarkSeen(groupName, hash)
                result["blocked"]++
                continue
            }

            listing := ListingParser.Parse(block, this.config.ImageMarkerPattern)
            if ListingParser.Validate(listing, this.config.RequiredFields).Length {
                this.state.MarkSeen(groupName, hash)
                result["invalid"]++
                continue
            }

            record := this.repo.SaveListing(listing, groupName, hash)
            this.state.MarkSeen(groupName, hash)
            result["saved"]++
            result["saved_records"].Push(record)
        }

        this.state.TouchHarvest(groupName)
        return result
    }
}
