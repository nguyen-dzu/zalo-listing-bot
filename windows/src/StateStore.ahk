#Requires AutoHotkey v2.0
; StateStore.ahk — Repository: per-group harvest cursor so only new messages are taken

class HarvestStateStore {
    __New(config) {
        this.config := config
        this.path := config.HarvestStateFile
        this.maxSeen := config.MaxSeenHashes
        this.state := Map()
        this.Load()
    }

    Load() {
        this.state := Map()
        raw := ReadTextFile(this.path)
        if Trim(raw) = ""
            return

        try {
            parsed := JSON.Parse(raw)
        } catch {
            return
        }
        if !(parsed is Array)
            return

        for entry in parsed {
            if !(entry is Map) || !entry.Has("group_name")
                continue
            seen := entry.Has("seen") && entry["seen"] is Array ? entry["seen"] : []
            this.state[entry["group_name"]] := Map(
                "group_name", entry["group_name"],
                "last_harvest_at", entry.Has("last_harvest_at") ? entry["last_harvest_at"] : "",
                "seen", seen
            )
        }
    }

    Save() {
        records := []
        for name, entry in this.state
            records.Push(entry)
        WriteTextFile(this.path, JSON.Stringify(records))
    }

    _Entry(groupName) {
        if !this.state.Has(groupName) {
            this.state[groupName] := Map(
                "group_name", groupName,
                "last_harvest_at", "",
                "seen", []
            )
        }
        return this.state[groupName]
    }

    IsSeen(groupName, hash) {
        for value in this._Entry(groupName)["seen"] {
            if value = hash
                return true
        }
        return false
    }

    MarkSeen(groupName, hash) {
        entry := this._Entry(groupName)
        if this.IsSeen(groupName, hash)
            return false
        entry["seen"].Push(hash)
        while entry["seen"].Length > this.maxSeen
            entry["seen"].RemoveAt(1)
        return true
    }

    TouchHarvest(groupName) {
        this._Entry(groupName)["last_harvest_at"] := NowStamp()
    }

    LastHarvestAt(groupName) {
        return this._Entry(groupName)["last_harvest_at"]
    }
}
