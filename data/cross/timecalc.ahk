#SingleInstance Force
#NoTrayIcon
Gui, Font, s12, Segoe UI

; --- Layout adjustments for larger font ---
Gui, Add, Text, x10 y10, Enter fractional hours (one per line):
Gui, Add, Edit, x10 y35 w360 h280 vHoursList

Gui, Add, Text, x10 y325, Target hours (e.g., 7.5 for 7h 30m):
Gui, Add, Edit, x10 y350 w120 vTargetHours, 7.5

Gui, Add, Button, x10 y390 w140 h35 gCalculate, Calculate

Gui, Add, Text, x10 y440 w360 vTotalText, Total: -
Gui, Add, Text, x10 y470 w360 vDiffText, Difference (target - total): -

Gui, Show, w364 h524, Fractional Time Calculator
return

Calculate:
    Gui, Submit, NoHide

    if (TargetHours = "")
    {
        MsgBox, Enter a numeric target (e.g., 7.5).
        return
    }

    target := TargetHours + 0
    total := 0

    Loop, Parse, HoursList, `n, `r
    {
        line := Trim(A_LoopField)
        if (line = "")
            continue

        StringReplace, line, line, `,, ., All

        if line is number
            total += line
    }

    diff := target - total

    totalHM := ToHoursMinutes(total)
    diffHM := ToHoursMinutes(diff)

    totalRounded := Round(total, 2)
    diffRounded := Round(diff, 2)

    GuiControl,, TotalText, Total: %totalRounded% hours (%totalHM%)
    GuiControl,, DiffText, Difference (target - total): %diffRounded% hours (%diffHM%)
return

ToHoursMinutes(hours) {
    sign := ""
    if (hours < 0)
        sign := "-"

    abs := Abs(hours)
    h := Floor(abs)
    m := Round((abs - h) * 60)

    if (m < 10)
        m := "0" . m

    return sign . h . "h " . m . "m"
}

GuiClose:
ExitApp
