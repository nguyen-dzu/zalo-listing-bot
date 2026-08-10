#Requires AutoHotkey v2.0
; BotControlWindow.ahk — always-visible emergency stop control.

class BotControlWindow {
    __New(bot, config) {
        this.bot := bot
        this.config := config
        this.window := 0
    }

    Show() {
        if !this.config.StartupShowStopButton
            return false
        this.window := Gui("+AlwaysOnTop +ToolWindow -Caption", "Zalo Bot Control")
        this.window.BackColor := "202020"
        this.window.SetFont("s10 Bold", "Segoe UI")
        this.status := this.window.AddText(
            "xm ym w210 Center cWhite", "ZALO BOT DANG CHAY")
        this.stopButton := this.window.AddText(
            "xm y+7 w210 h52 Center 0x200 Border BackgroundC00000 cWhite",
            "DUNG BOT")
        this.stopButton.SetFont("s13 Bold cWhite", "Segoe UI")
        this.stopButton.OnEvent("Click", ObjBindMethod(this, "_Stop"))

        x := Max(10, A_ScreenWidth - 240)
        this.window.Show("x" x " y20 w230 h92 NoActivate")
        return true
    }

    _Stop(*) {
        this.stopButton.Enabled := false
        this.stopButton.Value := "DANG DUNG..."
        this.stopButton.Opt("Background808080")
        this.status.Value := "CHO HOAN TAT BUOC AN TOAN"
        this.bot.EmergencyStop()
    }
}
