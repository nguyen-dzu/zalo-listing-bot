#Requires AutoHotkey v2.0
; GroupRegistry.ahk — Repository: Zalo group list loaded from Excel/CSV

class GroupRegistry {
    __New(config) {
        this.config := config
        this.rows := []
        this.Reload()
    }

    Reload() {
        this.rows := TableLoader.Load(
            this.config.GroupsXlsx,
            this.config.GroupsSheet,
            this.config.GroupsCsv
        )
        return this.rows.Length
    }

    SourceGroups() {
        return this._Filter("source")
    }

    MainGroups() {
        return this._Filter("main")
    }

    _Filter(kind) {
        result := []
        for row in this.rows {
            if !this._IsEnabled(row)
                continue
            if StrLower(this._Get(row, "type")) != kind
                continue
            name := this._Get(row, "group_name")
            if name = ""
                continue
            result.Push(Map(
                "group_name", name,
                "type", kind,
                "note", this._Get(row, "note")
            ))
        }
        return result
    }

    _IsEnabled(row) {
        value := StrLower(this._Get(row, "enabled"))
        return value = "" || value = "1" || value = "true" || value = "yes" || value = "x"
    }

    _Get(row, key) {
        return row.Has(key) ? Trim(row[key]) : ""
    }
}
