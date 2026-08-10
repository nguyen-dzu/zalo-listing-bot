#Requires AutoHotkey v2.0
; StateStore.ahk — Repository: per-group harvest cursor so only new messages are taken

class HarvestStateStore {
    __New(config) {
        this.config := config
        this.path := config.HarvestStateFile
        this.dir := config.HasProp("HarvestStateDir")
            ? config.HarvestStateDir : ""
        this.maxSeen := config.MaxSeenHashes
        this.state := Map()
        this.dirty := Map()
        this.Load()
    }

    Load() {
        this.state := Map()
        this.dirty := Map()
        raw := ReadTextFile(this.path)
        if Trim(raw) != "" {
            try {
                parsed := JSON.Parse(raw)
                if parsed is Array {
                    for entry in parsed
                        this._LoadEntry(entry)
                }
            } catch {
            }
        }

        if this.dir != "" && DirExist(this.dir) {
            Loop Files this.dir "\*.json", "F" {
                try {
                    entry := JSON.Parse(ReadTextFile(A_LoopFileFullPath))
                    this._LoadEntry(entry)
                } catch {
                }
            }
        }
    }

    Save() {
        if this.dir != "" {
            EnsureDir(this.dir)
            names := []
            for name, unused in this.dirty
                names.Push(name)
            for name in names {
                if !this.state.Has(name)
                    continue
                WriteTextFile(
                    this._GroupPath(name),
                    JSON.Stringify(this.state[name]))
                this.dirty.Delete(name)
            }
            return
        }

        records := []
        for name, entry in this.state
            records.Push(entry)
        WriteTextFile(this.path, JSON.Stringify(records))
    }

    _LoadEntry(entry) {
        if !(entry is Map) || !entry.Has("group_name")
            return false
        seen := entry.Has("seen") && entry["seen"] is Array
            ? entry["seen"] : []
        this.state[entry["group_name"]] := Map(
            "group_name", entry["group_name"],
            "last_harvest_at", entry.Has("last_harvest_at")
                ? entry["last_harvest_at"] : "",
            "last_capture_hash", entry.Has("last_capture_hash")
                ? entry["last_capture_hash"] : "",
            "needs_revisit", entry.Has("needs_revisit")
                && entry["needs_revisit"],
            "seen", seen
        )
        return true
    }

    _GroupPath(groupName) {
        return this.dir "\" FnvHash(groupName)
            . "-" FnvHash("state-v2|" groupName) ".json"
    }

    _MarkDirty(groupName) {
        this.dirty[groupName] := true
    }

    _Entry(groupName) {
        if !this.state.Has(groupName) {
            this.state[groupName] := Map(
                "group_name", groupName,
                "last_harvest_at", "",
                "last_capture_hash", "",
                "needs_revisit", false,
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
        this._MarkDirty(groupName)
        return true
    }

    TouchHarvest(groupName) {
        this._Entry(groupName)["last_harvest_at"] := NowStamp()
        this._MarkDirty(groupName)
    }

    LastHarvestAt(groupName) {
        return this._Entry(groupName)["last_harvest_at"]
    }

    ; Snapshot of the whole conversation at harvest time — detect new posts after publish.
    SetCaptureHash(groupName, hash) {
        this._Entry(groupName)["last_capture_hash"] := hash
        this._MarkDirty(groupName)
    }

    GetCaptureHash(groupName) {
        return this._Entry(groupName)["last_capture_hash"]
    }

    HasCaptureChanged(groupName, newHash) {
        old := this.GetCaptureHash(groupName)
        return old != "" && newHash != "" && old != newHash
    }

    MarkNeedsRevisit(groupName, needs := true) {
        this._Entry(groupName)["needs_revisit"] := needs
        this._MarkDirty(groupName)
    }

    ListRevisitGroups() {
        result := []
        for name, entry in this.state {
            if entry["needs_revisit"]
                result.Push(name)
        }
        return result
    }
}
