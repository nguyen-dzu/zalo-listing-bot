#Requires AutoHotkey v2.0
; Minimal blocking TCP socket wrapper used by WebBridge.

class Socket {
    static _wsaStarted := false

    __New(handle := -1) {
        Socket._EnsureWinsock()
        this.handle := handle
        if this.handle = -1 {
            this.handle := DllCall(
                "Ws2_32\socket",
                "Int", 2,       ; AF_INET
                "Int", 1,       ; SOCK_STREAM
                "Int", 6,       ; IPPROTO_TCP
                "Ptr"
            )
            if this.handle = -1
                throw OSError(DllCall("Ws2_32\WSAGetLastError", "Int"))
        }
    }

    static _EnsureWinsock() {
        if Socket._wsaStarted
            return
        data := Buffer(512, 0)
        result := DllCall("Ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", data)
        if result
            throw OSError(result, "WSAStartup failed")
        Socket._wsaStarted := true
    }

    Bind(host, port) {
        reuse := Buffer(4, 0)
        NumPut("Int", 1, reuse)
        DllCall(
            "Ws2_32\setsockopt",
            "Ptr", this.handle,
            "Int", 0xFFFF, ; SOL_SOCKET
            "Int", 0x0004, ; SO_REUSEADDR
            "Ptr", reuse,
            "Int", reuse.Size
        )

        address := Buffer(16, 0)
        NumPut("UShort", 2, address, 0)
        NumPut("UShort", DllCall("Ws2_32\htons", "UShort", port, "UShort"), address, 2)
        if DllCall(
            "Ws2_32\inet_pton",
            "Int", 2,
            "AStr", host,
            "Ptr", address.Ptr + 4,
            "Int"
        ) != 1
            throw Error("Địa chỉ bridge không hợp lệ: " host)
        if DllCall(
            "Ws2_32\bind",
            "Ptr", this.handle,
            "Ptr", address,
            "Int", address.Size,
            "Int"
        ) = -1
            this._ThrowLastError("bind")
        return this
    }

    Listen(backlog := 16) {
        if DllCall("Ws2_32\listen", "Ptr", this.handle, "Int", backlog, "Int") = -1
            this._ThrowLastError("listen")
        return this
    }

    Accept() {
        handle := DllCall(
            "Ws2_32\accept",
            "Ptr", this.handle,
            "Ptr", 0,
            "Ptr", 0,
            "Ptr"
        )
        if handle = -1
            this._ThrowLastError("accept")
        client := Socket(handle)
        client.SetReceiveTimeout(2000)
        return client
    }

    SetReceiveTimeout(timeoutMs) {
        value := Buffer(4, 0)
        NumPut("UInt", timeoutMs, value)
        if DllCall(
            "Ws2_32\setsockopt",
            "Ptr", this.handle,
            "Int", 0xFFFF, ; SOL_SOCKET
            "Int", 0x1006, ; SO_RCVTIMEO
            "Ptr", value,
            "Int", value.Size,
            "Int"
        ) = -1
            this._ThrowLastError("setsockopt")
        return this
    }

    Select(timeoutMs := 0) {
        arrayOffset := A_PtrSize = 8 ? 8 : 4
        readSet := Buffer(arrayOffset + A_PtrSize, 0)
        NumPut("UInt", 1, readSet, 0)
        NumPut("Ptr", this.handle, readSet, arrayOffset)

        timeout := Buffer(8, 0)
        NumPut("Int", Floor(timeoutMs / 1000), timeout, 0)
        NumPut("Int", Mod(timeoutMs, 1000) * 1000, timeout, 4)
        result := DllCall(
            "Ws2_32\select",
            "Int", 0,
            "Ptr", readSet,
            "Ptr", 0,
            "Ptr", 0,
            "Ptr", timeout,
            "Int"
        )
        if result = -1
            this._ThrowLastError("select")
        return result > 0 ? [this] : []
    }

    Recv(maxBytes := 65536) {
        buffer := Buffer(maxBytes, 0)
        received := DllCall(
            "Ws2_32\recv",
            "Ptr", this.handle,
            "Ptr", buffer,
            "Int", buffer.Size,
            "Int", 0,
            "Int"
        )
        if received = 0
            return ""
        if received = -1 {
            code := DllCall("Ws2_32\WSAGetLastError", "Int")
            if code = 10060
                throw Error("Timeout")
            throw OSError(code, "recv failed")
        }
        return StrGet(buffer, received, "UTF-8")
    }

    Send(text) {
        byteCount := StrPut(text, "UTF-8") - 1
        buffer := Buffer(byteCount + 1, 0)
        StrPut(text, buffer, "UTF-8")
        sentTotal := 0
        while sentTotal < byteCount {
            sent := DllCall(
                "Ws2_32\send",
                "Ptr", this.handle,
                "Ptr", buffer.Ptr + sentTotal,
                "Int", byteCount - sentTotal,
                "Int", 0,
                "Int"
            )
            if sent = -1
                this._ThrowLastError("send")
            if sent = 0
                throw Error("Socket đóng trước khi gửi hết response.")
            sentTotal += sent
        }
        return sentTotal
    }

    Close() {
        if this.handle != -1 {
            DllCall("Ws2_32\closesocket", "Ptr", this.handle, "Int")
            this.handle := -1
        }
    }

    __Delete() {
        this.Close()
    }

    _ThrowLastError(operation) {
        code := DllCall("Ws2_32\WSAGetLastError", "Int")
        throw OSError(code, operation " failed")
    }
}
