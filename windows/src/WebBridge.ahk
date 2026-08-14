#Requires AutoHotkey v2.0
; WebBridge.ahk — HTTP bridge between Tampermonkey (Zalo Web) and AHK v2

#Include JSON.ahk
#Include Util.ahk
#Include Socket.ahk

class WebBridge {
    __New(config) {
        this.config := config
        this.host := config.WebBridgeHost
        this.port := config.WebBridgePort
        this.server := 0
        this.running := false
        this.pollCallback := ObjBindMethod(this, "_Poll")
        this.pendingByRole := Map(
            "bot", Map()
        )
        this.commandSeq := 0
        this.lastResults := Map()
        this.eventHandlers := []
        this.clients := []
        this._polling := false
        this.registered := Map(
            "bot", Map(
                "role", "bot", "version", "",
                "title", "", "url", "", "ts", 0)
        )
    }

    Start() {
        if this.running
            return true
        try {
            this.server := Socket()
            this.server.Bind(this.host, this.port)
            this.server.Listen()
            this.running := true
            SetTimer(this.pollCallback, 30)
            this._Log("listening " this.host ":" this.port)
            return true
        } catch as err {
            this._Log("start_failed " err.Message)
            throw Error("WebBridge không bind được port "
                . this.port ": " err.Message)
        }
    }

    Stop() {
        this.running := false
        SetTimer(this.pollCallback, 0)
        for client in this.clients
            try client.Close()
        this.clients := []
        if this.server {
            try this.server.Close()
            this.server := 0
        }
    }

    OnEvent(handler) {
        this.eventHandlers.Push(handler)
    }

    RegisterStatus() {
        return Map(
            "bot", this._RoleSnapshot("bot")
        )
    }

    _RoleSnapshot(role) {
        entry := this.registered[role]
        ageMs := entry["ts"] ? (A_TickCount - entry["ts"]) : -1
        return Map(
            "registered", entry["ts"] > 0 && ageMs < 45000,
            "version", entry.Has("version") ? entry["version"] : "",
            "title", entry["title"],
            "url", entry["url"],
            "age_ms", ageMs
        )
    }

    WaitForRoles(timeoutSeconds := 30) {
        deadline := A_TickCount + (timeoutSeconds * 1000)
        while A_TickCount < deadline {
            this._Poll()
            snap := this._RoleSnapshot("bot")
            if snap["registered"]
                return true
            Sleep 50
        }
        throw Error(
            "Chưa kết nối tab Zalo Web.`n"
            . "Mở đúng 1 tab https://chat.zalo.me/ (bookmark #bot) "
            . "và bật Tampermonkey userscript v4.")
    }

    _Poll(*) {
        if !this.running || !this.server || this._polling
            return
        this._polling := true
        try {
            try {
                ready := this.server.Select(0)
                for sock in ready {
                    if sock = this.server {
                        client := this.server.Accept()
                        this.clients.Push(client)
                    }
                }
            } catch {
                return
            }

            alive := []
            for client in this.clients {
                try {
                    if this._ServeClient(client)
                        alive.Push(client)
                } catch {
                    try client.Close()
                }
            }
            this.clients := alive
        } finally {
            this._polling := false
        }
    }

    _ServeClient(client) {
        request := ""
        Loop 16 {
            chunk := ""
            try chunk := client.Recv(65536)
            catch as err {
                if err.Message = "Timeout" && this._RequestComplete(request)
                    break
                throw err
            }
            if chunk = ""
                break
            request .= chunk
            if this._RequestComplete(request)
                break
        }
        if request = "" || !this._RequestComplete(request)
            return false

        response := this._HandleRequest(request)
        try {
            client.Send(response)
            client.Close()
        }
        return false
    }

    _RequestComplete(request) {
        separatorLength := 4
        headerEnd := InStr(request, "`r`n`r`n")
        if !headerEnd {
            headerEnd := InStr(request, "`n`n")
            separatorLength := 2
        }
        if !headerEnd
            return false

        headers := SubStr(request, 1, headerEnd - 1)
        expectedBytes := 0
        if RegExMatch(headers, "im)^Content-Length:\s*(\d+)\s*$", &match)
            expectedBytes := Integer(match[1])
        if expectedBytes = 0
            return true

        body := SubStr(request, headerEnd + separatorLength)
        return StrPut(body, "UTF-8") - 1 >= expectedBytes
    }

    _ParseQuery(path) {
        query := Map()
        if !(pos := InStr(path, "?"))
            return query
        for part in StrSplit(SubStr(path, pos + 1), "&") {
            if (eq := InStr(part, "=")) {
                key := SubStr(part, 1, eq - 1)
                val := SubStr(part, eq + 1)
                query[key] := val
            }
        }
        return query
    }

    _HandleRequest(raw) {
        lines := StrSplit(raw, "`n", "`r")
        if !lines.Length
            return this._HttpResponse(400, "Bad Request")

        parts := StrSplit(Trim(lines[1]), " ")
        method := parts.Length >= 1 ? StrUpper(parts[1]) : "GET"
        fullPath := parts.Length >= 2 ? parts[2] : "/"
        path := fullPath
        if (qpos := InStr(fullPath, "?"))
            path := SubStr(fullPath, 1, qpos - 1)
        query := this._ParseQuery(fullPath)

        body := ""
        if blank := InStr(raw, "`r`n`r`n")
            body := SubStr(raw, blank + 4)
        else if blank := InStr(raw, "`n`n")
            body := SubStr(raw, blank + 2)

        switch path {
            case "/api/health":
                return this._JsonResponse(200, Map(
                    "ok", true,
                    "platform", "web",
                    "port", this.port,
                    "roles", this.RegisterStatus()
                ))
            case "/api/register":
                if method = "POST"
                    return this._HandleRegister(body)
                return this._JsonResponse(200, this.RegisterStatus())
            case "/api/command":
                role := query.Has("role") ? query["role"] : "bot"
                if role = "harvest" || role = "publish"
                    role := "bot"
                pending := this.pendingByRole.Has(role)
                    ? this.pendingByRole[role] : Map()
                if pending.Has("action")
                    return this._JsonResponse(200, pending)
                return this._JsonResponse(200, Map())
            case "/api/command-result":
                return this._HandleCommandResult(body)
            case "/api/event":
                return this._HandleEvent(body)
            case "/api/config":
                return this._JsonResponse(200, this._PublicConfig())
            default:
                return this._JsonResponse(404, Map("error", "not found"))
        }
    }

    _HandleRegister(body) {
        try {
            payload := JSON.parse(body)
            role := payload.Has("role") ? payload["role"] : ""
            if role = "harvest" || role = "publish"
                role := "bot"
            if role != "bot"
                return this._JsonResponse(400, Map("error", "invalid role"))
            this.registered[role] := Map(
                "role", role,
                "version", payload.Has("version") ? payload["version"] : "",
                "title", payload.Has("title") ? payload["title"] : "",
                "url", payload.Has("url") ? payload["url"] : "",
                "ts", A_TickCount
            )
            return this._JsonResponse(200, Map("ok", true, "role", role))
        } catch as err {
            return this._JsonResponse(400, Map("error", err.Message))
        }
    }

    _HandleCommandResult(body) {
        try {
            payload := JSON.parse(body)
            id := payload.Has("id") ? payload["id"] : ""
            this.lastResults[id] := payload
            for role in this.pendingByRole {
                pending := this.pendingByRole[role]
                if pending.Has("id") && pending["id"] = id
                    this.pendingByRole[role] := Map()
            }
            return this._JsonResponse(200, Map("ok", true))
        } catch as err {
            return this._JsonResponse(400, Map("error", err.Message))
        }
    }

    _HandleEvent(body) {
        try {
            payload := JSON.parse(body)
            for handler in this.eventHandlers
                try handler.Call(payload)
            return this._JsonResponse(200, Map("ok", true))
        } catch as err {
            return this._JsonResponse(400, Map("error", err.Message))
        }
    }

    _PublicConfig() {
        groups := []
        if this.config.HasProp("OutputGroupNames") {
            for name in this.config.OutputGroupNames
                groups.Push(name)
        }
        return Map(
            "platform", "web",
            "mode", "single_tab",
            "bridge_port", this.port,
            "output_groups", groups
        )
    }

    _DefaultRoleForAction(action) {
        return "bot"
    }

    IssueCommand(action, params := 0, targetRole := "") {
        if targetRole = "" || targetRole = "harvest" || targetRole = "publish"
            targetRole := this._DefaultRoleForAction(action)
        if !this.pendingByRole.Has(targetRole)
            throw Error("WebBridge role không hợp lệ: " targetRole)
        if this.pendingByRole[targetRole].Has("action")
            throw Error("WebBridge đang xử lý lệnh khác cho role " targetRole ".")
        this.commandSeq++
        cmd := Map("id", "cmd" this.commandSeq, "action", action, "role", targetRole)
        if IsObject(params)
            for key, value in params
                cmd[key] := value
        this.pendingByRole[targetRole] := cmd
        if this.lastResults.Has(cmd["id"])
            this.lastResults.Delete(cmd["id"])
        return cmd["id"]
    }

    WaitForResult(id, timeoutMs := 15000) {
        deadline := A_TickCount + timeoutMs
        while A_TickCount < deadline {
            this._Poll()
            if this.lastResults.Has(id) {
                payload := this.lastResults[id]
                this.lastResults.Delete(id)
                if payload.Has("ok") && !payload["ok"]
                    throw Error(payload.Has("error") ? payload["error"] : "JS command failed")
                if payload.Has("result") && (payload["result"] is Map)
                    return payload["result"]
                if payload is Map
                    return payload
                return Map()
            }
            Sleep 30
        }
        for role in this.pendingByRole {
            pending := this.pendingByRole[role]
            if pending.Has("id") && pending["id"] = id
                this.pendingByRole[role] := Map()
        }
        throw Error("WebBridge timeout chờ JS (" id "): kiểm tra tab "
            . "Zalo Web [ZaloBot] và Tampermonkey.")
    }

    RunCommand(action, params := 0, timeoutMs := 15000, targetRole := "") {
        id := this.IssueCommand(action, params, targetRole)
        return this.WaitForResult(id, timeoutMs)
    }

    _JsonResponse(status, obj) {
        body := JSON.stringify(obj)
        return this._HttpResponse(status, body, "application/json; charset=utf-8")
    }

    _HttpResponse(status, body, contentType := "text/plain; charset=utf-8") {
        reason := status = 200 ? "OK" : status = 404 ? "Not Found" : "Error"
        bodyBytes := StrPut(body, "UTF-8") - 1
        header := "HTTP/1.1 " status " " reason "`r`n"
            . "Content-Type: " contentType "`r`n"
            . "Access-Control-Allow-Origin: *`r`n"
            . "Connection: close`r`n"
            . "Content-Length: " bodyBytes "`r`n`r`n"
        return header body
    }

    _Log(message) {
        path := this.config.HasProp("QueueLogFile") ? this.config.QueueLogFile : ""
        line := "[" NowStamp() "] webbridge " message "`n"
        if path != ""
            try FileAppend line, path, "UTF-8-RAW"
    }
}
