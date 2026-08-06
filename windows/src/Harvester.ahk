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

    ; Harvest every enabled source group. Returns a summary Map.
    HarvestAll() {
        summary := Map("groups", 0, "saved", 0, "blocked", 0, "duplicate", 0, "invalid", 0, "errors", [])

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

    HarvestGroup(groupName) {
        result := Map("saved", 0, "blocked", 0, "duplicate", 0, "invalid", 0)

        this.ui.OpenGroup(groupName)
        text := this.ui.CaptureConversationText()
        if Trim(text) = ""
            return result

        blocks := ListingParser.SplitBlocks(
            text, this.config.ListingStartPattern, this.config.ImageMarkerPattern
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

            this.repo.SaveListing(listing, groupName, hash)
            this.state.MarkSeen(groupName, hash)
            result["saved"]++
        }

        this.state.TouchHarvest(groupName)
        return result
    }
}
