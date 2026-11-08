#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
#MaxThreadsPerHotkey 2

class SimConfig {
    ; Input and target
    InputFile := A_ScriptDir . "\text.txt"
    TargetProcesses := ["Code.exe", "Code - Insiders.exe"]

    ; General typing behavior
    TypingSpeed := 0.9             
    StartDelay := 1200             
    ; Newline and tab compatibility options.
    ; If VS Code auto-indent or autocomplete changes your formatting, try:
    ;   UseEnterKeyForNewline := false
    ;   UseTabKeyForTabs := false
    UseEnterKeyForNewline := true
    UseTabKeyForTabs := true

    ; Keyboard shortcuts
    HotkeyStart := "F6"
    HotkeyPause := "F7"
    HotkeyStop := "F8"
    HotkeyReload := "F9"
    HotkeyEmergency := "Esc"      
    ; Character delays, milliseconds
    LetterDelayMin := 37
    LetterDelayMax := 208

    DigitDelayMin := 46
    DigitDelayMax := 171

    SymbolDelayMin := 70
    SymbolDelayMax := 220

    PunctuationDelayMin := 130
    PunctuationDelayMax := 380

    SpaceDelayMin := 50
    SpaceDelayMax := 190

    ; Occasional pause after a space
    WordPauseChance := 0.07         ; 0.0 = never, 1.0 = always
    WordPauseMin := 180
    WordPauseMax := 750

    ; End-of-line delays
    LineDelayMin := 258
    LineDelayMax := 953

    BlankLineDelayMin := 160
    BlankLineDelayMax := 650

    ; Code-block pauses never modifies text.
    BlockPauseChance := 0.35
    BlockDelayMin := 450
    BlockDelayMax := 1800

    ; Natural thinking pauses
    NaturalPauseChance := 0.015
    NaturalPauseMin := 700
    NaturalPauseMax := 2600

    ; Mistakes and corrections
    MistakeChance := 0.019          ; Chance per character that a correction sequence may occur.
    MultiCharDeleteChance := 0.25   ; When a mistake occurs, chance of deleting multiple chars.
    MaxMultiCharDelete := 3
    CorrectionDelayMin := 120
    CorrectionDelayMax := 420

    ; Optional mouse movement.
    EnableMouseMovement := true
    MouseMoveChance := 0.02
    MouseMoveMin := 4
    MouseMoveMax := 18

    ; Focus handling
    FocusPollMs := 90
    MaxFocusWaitMs := 0             ; 0 = wait indefinitely for VS Code focus.
    UserInputQuietMs := 5000   
}


; Simulator implementation
class Simulator {
    cfg := SimConfig()

    state := "Idle"                 ; Idle, Running, Paused, Done
    rawText := ""
    lines := []
    endsWithNewline := false

    stopRequested := false
    pauseRequested := false
    reloadRequested := false
    emergencyRequested := false

    lastError := ""


    ; File loading
    LoadSource() {
        this.lastError := ""
        path := this.cfg.InputFile

        if !FileExist(path) {
            this.lastError := "Input file not found: " . path
            this.rawText := ""
            this.lines := []
            this.endsWithNewline := false
            return false
        }

        try {
            text := FileRead(path, "UTF-8")
        } catch Error as e {
            this.lastError := "Could not read input file: " . e.Message
            this.rawText := ""
            this.lines := []
            this.endsWithNewline := false
            return false
        }

        ; Remove UTF-8 BOM if present.
        if (Ord(text) = 65279)
            text := SubStr(text, 2)

        ; Normalize line endings to LF internally.
        text := StrReplace(text, "`r`n", "`n")
        text := StrReplace(text, "`r", "`n")

        this.rawText := text
        textLength := StrLen(text)

        this.endsWithNewline := textLength > 0 && SubStr(text, textLength, 1) == "`n"

        if (textLength = 0) {
            this.lines := []
            return true
        }

        this.lines := StrSplit(text, "`n")

        ; If the file ends with a newline, StrSplit creates a trailing empty
        ; element. We remove that artificial element and use endsWithNewline
        ; to decide whether to press Enter after the final real line.(hope the comment help :))
        if this.endsWithNewline && this.lines.Length > 0 && this.lines[this.lines.Length] == ""
            this.lines.Pop()

        return true
    }


    ; Public controls
    Start() {
        if this.state == "Running"
            return

        if this.state == "Paused" {
            this.TogglePause()
            return
        }

        if !this.LoadSource() {
            this.SetState("Idle")
            UpdateTrayTip("Error: " . this.lastError)
            try SoundBeep(280, 250)
            return
        }

        if this.rawText == "" {
            this.SetState("Done")
            UpdateTrayTip("Input file is empty")
            return
        }

        this.stopRequested := false
        this.pauseRequested := false
        this.emergencyRequested := false
        this.reloadRequested := false

        this.SetState("Running")
        this.RunTyping()
    }

    TogglePause() {
        if this.state == "Running" {
            this.pauseRequested := true
            this.SetState("Paused")
        } else if this.state == "Paused" {
            this.pauseRequested := false
            this.SetState("Running")
        }
    }

    Stop() {
        if this.state == "Running" || this.state == "Paused" {
            this.stopRequested := true
            this.pauseRequested := false
            UpdateTrayTip("Stopping")
        } else {
            this.stopRequested := true
            this.pauseRequested := false
            this.SetState("Idle")
        }
    }

    EmergencyStop() {
        this.emergencyRequested := true
        this.stopRequested := true
        this.pauseRequested := false
        UpdateTrayTip("Emergency stop requested")
    }

    Reload() {
        if this.state == "Running" || this.state == "Paused" {
            this.reloadRequested := true
            this.stopRequested := true
            this.pauseRequested := false
            UpdateTrayTip("Stopping for reload")
            return
        }

        if this.LoadSource()
            UpdateTrayTip("Reloaded source file")
        else
            UpdateTrayTip("Reload failed: " . this.lastError)
    }


    ; Main typing loop
    RunTyping() {
        if !this.EnsureTarget() {
            this.Finish("Stopped")
            return
        }

        if !this.Wait(this.cfg.StartDelay) {
            this.Finish("Stopped")
            return
        }

        lineCount := this.lines.Length

        for index, line in this.lines {
            if !this.CanContinue() || !this.EnsureTarget() {
                this.Finish("Stopped")
                return
            }

            if !this.MaybeNaturalPause() {
                this.Finish("Stopped")
                return
            }

            ; Type the line content unless it is truly empty.
            ; Lines containing spaces or tabs are still typed.
            if line != "" {
                if !this.TypeLine(line, index) {
                    this.Finish("Stopped")
                    return
                }
            }

            ; Send a line break where the original file had one.
            shouldSendEnter := index < lineCount || this.endsWithNewline

            if shouldSendEnter {
                if !this.CanContinue() || !this.EnsureTarget() {
                    this.Finish("Stopped")
                    return
                }

                if !this.SendNewline() {
                    this.Finish("Stopped")
                    return
                }

                if line == ""
                    delay := this.ScaleDelay(Random(this.cfg.BlankLineDelayMin, this.cfg.BlankLineDelayMax))
                else
                    delay := this.ScaleDelay(Random(this.cfg.LineDelayMin, this.cfg.LineDelayMax))

                if !this.Wait(delay) {
                    this.Finish("Stopped")
                    return
                }

                if !this.MaybeBlockPause(line, index) {
                    this.Finish("Stopped")
                    return
                }
            }
        }

        this.Finish("Done")
    }

    TypeLine(line, lineNumber) {
        lineLength := StrLen(line)

        Loop lineLength {
            if !this.CanContinue() || !this.EnsureTarget()
                return false

            ch := SubStr(line, A_Index, 1)

            this.MaybeMoveMouse()

            if !this.MaybeCorrection(line, A_Index, ch)
                return false

            if !this.CanContinue() || !this.EnsureTarget()
                return false

            if !this.SendChar(ch)
                return false    

            delay := this.GetCharDelay(ch, line, A_Index)
            if !this.Wait(delay)
                return false

            ; Occasional pause between words / around spaces.
            if ch == " " && Random(0.0, 1.0) < this.cfg.WordPauseChance {
                if !this.Wait(this.ScaleDelay(Random(this.cfg.WordPauseMin, this.cfg.WordPauseMax)))
                    return false
            }
        }

        return true
    }


    ; Mistakes and corrections
    MaybeCorrection(line, index, correctChar) {
        if Random(0.0, 1.0) >= this.cfg.MistakeChance
            return true

        ; Occasionally delete a short previous sequence and retype it.
        if index > 1 && Random(0.0, 1.0) < this.cfg.MultiCharDeleteChance {
            maxDelete := Min(this.cfg.MaxMultiCharDelete, index - 1)

            if maxDelete >= 1 {
                deleteCount := Random(1, maxDelete)

                if !this.Wait(this.ScaleDelay(Random(this.cfg.CorrectionDelayMin, this.cfg.CorrectionDelayMax)))
                    return false

                if !this.SendToTarget("{Backspace " . deleteCount . "}")
                    return false

                if !this.Wait(this.ScaleDelay(Random(this.cfg.CorrectionDelayMin, this.cfg.CorrectionDelayMax)))
                    return false

                startPos := index - deleteCount
                segment := SubStr(line, startPos, deleteCount)
                segmentLength := StrLen(segment)

                Loop segmentLength {
                    if !this.CanContinue() || !this.EnsureTarget()
                        return false

                    repairChar := SubStr(segment, A_Index, 1)

                    if !this.SendChar(repairChar)
                        return false

                    if !this.Wait(this.ScaleDelay(Random(this.cfg.LetterDelayMin, this.cfg.LetterDelayMax)))
                        return false
                }

                return true
            }
        }

        ; Simple one-character mistake and correction.
        wrongChar := this.GetWrongChar(correctChar)

        if !this.Wait(this.ScaleDelay(Random(this.cfg.CorrectionDelayMin, this.cfg.CorrectionDelayMax)))
            return false

        if !this.CanContinue() || !this.EnsureTarget()
            return false

        if !this.SendChar(wrongChar)
            return false

        if !this.Wait(this.ScaleDelay(Random(this.cfg.CorrectionDelayMin, this.cfg.CorrectionDelayMax)))
            return false

        if !this.SendToTarget("{Backspace}")
            return false

        if !this.Wait(this.ScaleDelay(Random(this.cfg.CorrectionDelayMin, this.cfg.CorrectionDelayMax)))
            return false

        return true
    }

    GetWrongChar(correctChar) {
        if this.IsLetter(correctChar) {
            letters := "qwertasdfgzxcvbpoiuytrewqasdfghjklmnbvcxz"
            return SubStr(letters, Random(1, StrLen(letters)), 1)
        }

        if this.IsDigit(correctChar)
            return "" . Random(0, 9)

        if correctChar == " "
            return "x"

        if correctChar == "`t"
            return "t"

        return "x"
    }

    ; Character output — guarded against focus loss
    WaitForUserIdle() {
        quietMs := this.cfg.UserInputQuietMs

        while A_TimeIdlePhysical < quietMs {
            if !this.CanContinue()
                return false

            Sleep(50)
        }

        return this.CanContinue()
    }
    SendToTarget(keys) {
        ; Wait until the user has been physically idle for 5 seconds.
        if !this.WaitForUserIdle()
            return false

        ; Check for stop or pause requests.
        if !this.CanContinue()
            return false
        ; Confirm VS Code is still the active window.
        if !this.IsTargetActive() {
            this.stopRequested := true
            UpdateTrayTip("Stopped: VS Code lost focus")
            return false
        }

        ; Send only after the checks pass.
        Send(keys)
        return true
    }

    SendChar(ch) {
        if ch == "`t" && this.cfg.UseTabKeyForTabs {
            return this.SendToTarget("{Tab}")
        } else if ch == "`n" {
            return this.SendNewline()
        } else {
            ; {Text} sends the character literally.
            return this.SendToTarget("{Text}" . ch)
        }
    }

    SendNewline() {
        if this.cfg.UseEnterKeyForNewline
            return this.SendToTarget("{Enter}")
        else
            return this.SendToTarget("{Text}`n")
    }

    ; Timing and character categories
    GetCharDelay(ch, line, index) {
        if ch == " "
            base := Random(this.cfg.SpaceDelayMin, this.cfg.SpaceDelayMax)
        else if ch == "`t"
            base := Random(this.cfg.SymbolDelayMin, this.cfg.SymbolDelayMax)
        else if this.IsLetter(ch)
            base := Random(this.cfg.LetterDelayMin, this.cfg.LetterDelayMax)
        else if this.IsDigit(ch)
            base := Random(this.cfg.DigitDelayMin, this.cfg.DigitDelayMax)
        else if this.IsPunctuation(ch)
            base := Random(this.cfg.PunctuationDelayMin, this.cfg.PunctuationDelayMax)
        else
            base := Random(this.cfg.SymbolDelayMin, this.cfg.SymbolDelayMax)

        ; Longer pause around punctuation.
        nextChar := index < StrLen(line) ? SubStr(line, index + 1, 1) : ""
        if this.IsPunctuation(ch) || (nextChar != "" && this.IsPunctuation(nextChar))
            base := Max(base, Random(this.cfg.PunctuationDelayMin, this.cfg.PunctuationDelayMax))

        return this.ScaleDelay(base)
    }

    IsLetter(ch) {
        return RegExMatch(ch, "[A-Za-z]") > 0
    }

    IsDigit(ch) {
        return RegExMatch(ch, "[0-9]") > 0
    }

    IsPunctuation(ch) {
        return RegExMatch(ch, "[.,;:!?]") > 0
    }

    MaybeNaturalPause() {
        if Random(0.0, 1.0) < this.cfg.NaturalPauseChance
            return this.Wait(this.ScaleDelay(Random(this.cfg.NaturalPauseMin, this.cfg.NaturalPauseMax)))

        return true
    }


    ; Code-aware pause heuristics
    ; These heuristics only add pauses. They never rewrite, reformat, or remove
    ; source text. 
    MaybeBlockPause(line, index) {
        nextLine := index < this.lines.Length ? this.lines[index + 1] : ""

        if !this.ShouldBlockPause(line, nextLine)
            return true

        if Random(0.0, 1.0) >= this.cfg.BlockPauseChance
            return true

        return this.Wait(this.ScaleDelay(Random(this.cfg.BlockDelayMin, this.cfg.BlockDelayMax)))
    }

    ShouldBlockPause(line, nextLine) {
        t := Trim(line)
        nt := Trim(nextLine)

        if t == ""
            return false

        ; Lines ending with an opening brace or bracket.
        if RegExMatch(t, "(\{|\[)$")
            return true

        ; Lines beginning with a closing brace or bracket.
        if RegExMatch(t, "^[}\]]")
            return true

        ; Next line begins with a closing brace or bracket.
        if RegExMatch(nt, "^[}\]]")
            return true

        ; Common block-start keywords across several languages.
        if RegExMatch(t, "^(export\s+|default\s+|abstract\s+|public\s+|private\s+|protected\s+|static\s+|async\s+)*(class|interface|struct|enum|namespace|module|function|func|def|if|else|elif|for|foreach|while|switch|try|catch|finally|do|begin|end)\b")
            return true

        ; Python-like colon block starts.
        if RegExMatch(t, ":\s*$") && RegExMatch(nt, "^\S")
            return true

        return false
    }

    ; Optional mouse movement
    MaybeMoveMouse() {
        if !this.cfg.EnableMouseMovement
            return

        if Random(0.0, 1.0) >= this.cfg.MouseMoveChance
            return

        if !this.IsTargetActive()
            return

        minDistance := Max(0, Min(this.cfg.MouseMoveMin, this.cfg.MouseMoveMax))
        maxDistance := Max(0, Max(this.cfg.MouseMoveMin, this.cfg.MouseMoveMax))

        distance := Random(minDistance, maxDistance)
        angle := Random(0.0, 6.28318530718)

        dx := Round(Cos(angle) * distance)
        dy := Round(Sin(angle) * distance)

        if dx == 0 && dy == 0
            dx := 1

        MouseMove(dx, dy, 2, "R")
    }


    ; Target focus handling
    EnsureTarget() {
        waited := 0
        lastTip := 0
        poll := this.PollInterval()

        while !this.IsTargetActive() {
            if !this.CanContinue()
                return false

            Sleep(poll)
            waited += poll

            if waited - lastTip >= 1000 {
                UpdateTrayTip("Waiting for VS Code focus...")
                lastTip := waited
            }

            if this.cfg.MaxFocusWaitMs > 0 && waited >= this.cfg.MaxFocusWaitMs
                return false
        }

        if waited > 0
            UpdateTrayTip("Running")

        return true
    }

    IsTargetActive() {
        for proc in this.cfg.TargetProcesses {
            if WinActive("ahk_exe " . proc)
                return true
        }

        return false
    }


    ; Responsive waiting, pause, and abort handling
    Wait(ms) {
        ms := Round(ms)

        if ms <= 0
            return this.CanContinue()

        elapsed := 0
        chunk := 50

        while elapsed < ms {
            if !this.CanContinue()
                return false

            sleepTime := Min(chunk, ms - elapsed)
            Sleep(sleepTime)
            elapsed += sleepTime
        }

        return this.CanContinue()
    }

    CanContinue() {
        if this.AbortRequested()
            return false

        return this.HandlePause()
    }

    HandlePause() {
        if !this.pauseRequested
            return true

        this.SetState("Paused")

        poll := this.PollInterval()

        while this.pauseRequested && !this.AbortRequested()
            Sleep(poll)

        if this.AbortRequested()
            return false

        this.SetState("Running")
        return true
    }

    AbortRequested() {
        return this.stopRequested || this.emergencyRequested
    }

    PollInterval() {
        return this.cfg.FocusPollMs > 0 ? this.cfg.FocusPollMs : 50
    }

    ScaleDelay(ms) {
        speed := this.cfg.TypingSpeed

        if speed <= 0
            speed := 1.0

        return Round(ms / speed)
    }


    ; State management
    SetState(newState) {
        this.state := newState

        ; Enable the emergency hotkey only while a simulation is active.
        try {
            if newState == "Running" || newState == "Paused"
                Hotkey(this.cfg.HotkeyEmergency, HotkeyEmergencyStop, "On")
            else
                Hotkey(this.cfg.HotkeyEmergency, HotkeyEmergencyStop, "Off")
        } catch Error as e {
            ; Ignore hotkey state errors. The primary simulation should continue.
        }

        UpdateTrayTip(newState)
    }

    Finish(reason) {
        if this.reloadRequested {
            loaded := this.LoadSource()
            this.reloadRequested := false
            reason := loaded ? "Reloaded" : "Reload failed"
        }

        if reason == "Done"
            this.SetState("Done")
        else
            this.SetState("Idle")

        UpdateTrayTip(reason)
    }
}


; Global helper functions
UpdateTrayTip(text) {
    try {
        A_IconTip := "TypingSimulator: " . text
    } catch Error as e {
        ; Tray tooltip is optional.
    }
}


; Hotkey callback functions
HotkeyStart(ThisHotkey := "") {
    global Sim
    Sim.Start()
}

HotkeyPause(ThisHotkey := "") {
    global Sim
    Sim.TogglePause()
}

HotkeyStop(ThisHotkey := "") {
    global Sim
    Sim.Stop()
}

HotkeyReload(ThisHotkey := "") {
    global Sim
    Sim.Reload()
}

HotkeyEmergencyStop(ThisHotkey := "") {
    global Sim
    Sim.EmergencyStop()
}


; Script startup
SetWorkingDir(A_ScriptDir)
SendMode("Event")
SetKeyDelay(15, 15)
CoordMode("Mouse", "Screen")

InstallKeybdHook()
InstallMouseHook()

Sim := Simulator()

hotkeysReady := true

try {
    Hotkey(Sim.cfg.HotkeyStart, HotkeyStart)
    Hotkey(Sim.cfg.HotkeyPause, HotkeyPause)
    Hotkey(Sim.cfg.HotkeyStop, HotkeyStop)
    Hotkey(Sim.cfg.HotkeyReload, HotkeyReload)

    ; Emergency stop is disabled unless a simulation is active.
    Hotkey(Sim.cfg.HotkeyEmergency, HotkeyEmergencyStop, "Off")
} catch Error as e {
    hotkeysReady := false
    try SoundBeep(220, 300)
    UpdateTrayTip("Hotkey registration failed: " . e.Message)
    MsgBox("Hotkey registration failed:`n`n" . e.Message)
}

if hotkeysReady {
    UpdateTrayTip(
        "Ready. " .
        Sim.cfg.HotkeyStart . " start, " .
        Sim.cfg.HotkeyPause . " pause, " .
        Sim.cfg.HotkeyStop . " stop, " .
        Sim.cfg.HotkeyReload . " reload."
    )
}

return
