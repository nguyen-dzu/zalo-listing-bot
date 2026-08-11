#Requires AutoHotkey v2.0
; Harvester.ahk — Service: read source groups, drop blocked/duplicate posts, persist new listings

class MessageHarvester {
    __New(config, ui, registry, blockList, stateStore, repository, mediaCapturer := 0) {
        this.config := config
        this.ui := ui
        this.registry := registry
        this.blockList := blockList
        this.state := stateStore
        this.repo := repository
        this.mediaCapturer := mediaCapturer
    }

    _EmptySummary() {
        return Map(
            "groups", 0, "saved", 0, "blocked", 0,
            "duplicate", 0, "invalid", 0, "published", 0,
            "revisit", 0, "media_captured", 0, "media_failed", 0, "errors", []
        )
    }

    ; Harvest every enabled source group. Returns a summary Map.
    HarvestAll() {
        return this.HarvestGroups(this.registry.SourceGroups())
    }

    ; Sequential bounded harvest. State may be flushed after every group so a
    ; restart resumes from the oldest untouched group instead of losing a cycle.
    HarvestGroups(groups, afterGroupFn := 0) {
        summary := this._EmptySummary()
        for index, group in groups {
            summary["groups"]++
            result := 0
            try {
                result := this.HarvestGroup(group["group_name"])
                summary["saved"] += result["saved"]
                summary["blocked"] += result["blocked"]
                summary["duplicate"] += result["duplicate"]
                summary["invalid"] += result["invalid"]
                summary["media_captured"] += result["media_captured"]
                summary["media_failed"] += result["media_failed"]
            } catch as err {
                ; OpenGroup miss / wrong chat → skip this group, try the next.
                summary["errors"].Push(
                    "skip " group["group_name"] ": " err.Message)
            }
            if this.config.HarvestSaveStateEachGroup
                this.state.Save()
            if afterGroupFn {
                shouldContinue := true
                try shouldContinue := afterGroupFn.Call(
                    index, group, result, summary)
                catch as err {
                    summary["errors"].Push(
                        "after-group " group["group_name"] ": " err.Message)
                }
                if shouldContinue = false
                    break
            }
            this._SequentialGroupDelay()
        }
        this.state.Save()
        return summary
    }

    _SequentialGroupDelay() {
        Sleep Random(
            this.config.HarvestGroupDelayMinMs,
            this.config.HarvestGroupDelayMaxMs)
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

    ; Harvest revisit groups, then mark groups whose conversation changed after publish.
    ProcessRevisitQueue() {
        summary := Map(
            "revisit", 0, "groups", 0, "saved", 0,
            "media_captured", 0, "media_failed", 0, "errors", []
        )
        revisitNames := this.state.ListRevisitGroups()
        sources := this.registry.SourceGroups()
        if revisitNames.Length {
            batch := this._NamesToGroups(revisitNames, sources)
            for group in batch {
                summary["groups"]++
                try {
                    result := this.HarvestGroup(group["group_name"])
                    summary["saved"] += result["saved"]
                    summary["media_captured"] += result["media_captured"]
                    summary["media_failed"] += result["media_failed"]
                    this.state.MarkNeedsRevisit(group["group_name"], false)
                } catch as err {
                    summary["errors"].Push(group["group_name"] ": " err.Message)
                }
                Sleep this.config.BetweenGroupsMs
            }
        }

        if this.config.RecheckAfterPublish {
            Sleep this.config.AfterPublishRecheckMs
            for group in sources {
                try {
                    if this._RecheckForNewMessages(group["group_name"])
                        summary["revisit"]++
                } catch as err {
                    summary["errors"].Push("recheck " group["group_name"] ": " err.Message)
                }
            }
        }

        this.state.Save()
        return summary
    }

    HarvestGroup(groupName) {
        result := Map(
            "saved", 0, "blocked", 0, "duplicate", 0, "invalid", 0,
            "media_captured", 0, "media_failed", 0, "saved_records", []
        )

        this.ui.OpenGroup(groupName, "read")
        settle := this.config.HasProp("CaptureSettleMs") ? this.config.CaptureSettleMs : 600
        Sleep settle
        text := this.ui.CaptureConversationText()
        normalized := NormalizeNewlines(text)
        if Trim(normalized) = ""
            return result

        blocks := ListingParser.SplitBlocks(
            normalized, this.config.ListingStartPattern, this.config.ImageMarkerPattern
        )
        ; Accessibility can return only Zalo chrome/header labels on some
        ; versions. Retry from the actual message-bubble area before deciding
        ; that the source group has no rental listing.
        if (!blocks.Length && this.config.CaptureMethod != "selectall") {
            fallbackText := this.ui.CaptureConversationText("selectall")
            fallbackNormalized := NormalizeNewlines(fallbackText)
            fallbackBlocks := ListingParser.SplitBlocks(
                fallbackNormalized,
                this.config.ListingStartPattern,
                this.config.ImageMarkerPattern
            )
            if fallbackBlocks.Length {
                normalized := fallbackNormalized
                blocks := fallbackBlocks
            }
        }

        captureHash := FnvHash(normalized)
        previousHash := this.state.GetCaptureHash(groupName)
        ; Conversation unchanged → already-read messages; skip re-copy/re-parse.
        if previousHash != "" && previousHash = captureHash {
            this.state.MarkNeedsRevisit(groupName, false)
            this.state.TouchHarvest(groupName)
            return result
        }

        this.state.SetCaptureHash(groupName, captureHash)
        this.state.MarkNeedsRevisit(groupName, false)

        pick := MessageActivityScanner.PickUnseenNewestFirst(
            blocks,
            ObjBindMethod(this.state, "IsSeen", groupName),
            this.config.MaxMessagesPerGroup)
        if pick["stopped_on_seen"]
            result["duplicate"]++

        for item in pick["items"] {
            block := item["block"]
            hash := item["hash"]

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
            if (this.mediaCapturer
                && this.config.AutoCapture
                && ((record.Has("image_count") && record["image_count"] > 0)
                    || this.config.AutoCaptureProbeImages)) {
                if this.mediaCapturer.CaptureForRecord(groupName, record)
                    result["media_captured"]++
                else
                    result["media_failed"]++
            }
        }

        this.state.TouchHarvest(groupName)
        return result
    }
}
