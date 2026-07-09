Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Helper function: convert decimal hours to H/M ---
function To-HoursMinutes {
    param([double]$hours)

    if ($hours -eq $null -or [double]::IsNaN($hours)) {
        return "N/A"
    }

    $sign = ""
    if ($hours -lt 0) { $sign = "-" }

    $abs = [math]::Abs($hours)
    $h = [math]::Floor($abs)
    $m = [math]::Round(($abs - $h) * 60)

    return "$sign$h" + "h " + ("{0:00}" -f $m) -f $m + "m"
}

# --- Create Form ---
$form = New-Object System.Windows.Forms.Form
$form.Font = New-Object System.Drawing.Font("Segoe UI", 12)
$form.Text = "Fractional Time Calculator"
$form.Size = New-Object System.Drawing.Size(380, 550)
$form.StartPosition = "CenterScreen"

# --- Label: List ---
$lblList = New-Object System.Windows.Forms.Label
$lblList.Text = "Enter fractional hours (one per line):"
$lblList.Location = New-Object System.Drawing.Point(10, 10)
$lblList.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($lblList)

# --- Textbox: List ---
$txtList = New-Object System.Windows.Forms.TextBox
$txtList.Multiline = $true
$txtList.ScrollBars = "Vertical"
$txtList.Location = New-Object System.Drawing.Point(10, 35)
$txtList.Size = New-Object System.Drawing.Size(340, 250)
$form.Controls.Add($txtList)

# --- Label: Target ---
$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "Target hours (e.g., 7.5 for 7h 30m):"
$lblTarget.Location = New-Object System.Drawing.Point(10, 300)
$lblTarget.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($lblTarget)

# --- Textbox: Target ---
$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(10, 325)
$txtTarget.Size = New-Object System.Drawing.Size(100, 25)
$txtTarget.Text = "7.5"
$form.Controls.Add($txtTarget)

# --- Button: Calculate ---
$btnCalc = New-Object System.Windows.Forms.Button
$btnCalc.Text = "Calculate"
$btnCalc.Location = New-Object System.Drawing.Point(10, 360)
$btnCalc.Size = New-Object System.Drawing.Size(120, 35)
$form.Controls.Add($btnCalc)

# --- Output Labels ---
$lblTotal = New-Object System.Windows.Forms.Label
$lblTotal.Text = "Total: -"
$lblTotal.Location = New-Object System.Drawing.Point(10, 410)
$lblTotal.Size = New-Object System.Drawing.Size(340, 25)
$form.Controls.Add($lblTotal)

$lblDiff = New-Object System.Windows.Forms.Label
$lblDiff.Text = "Difference (target - total): -"
$lblDiff.Location = New-Object System.Drawing.Point(10, 440)
$lblDiff.Size = New-Object System.Drawing.Size(340, 25)
$form.Controls.Add($lblDiff)

# --- Calculate Logic ---
$btnCalc.Add_Click({
    $num = $null
    $target = $null
    $raw = $txtList.Text
    $targetStr = $txtTarget.Text

    if (-not [double]::TryParse($targetStr, [ref]$target)) {
        [System.Windows.Forms.MessageBox]::Show("Enter a numeric target (e.g., 7.5).")
        return
    }

    $lines = $raw -split "`r?`n"
    $values = @()

    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -eq "") { continue }

        if ([double]::TryParse($trim.Replace(",", "."), [ref]$num)) {
            $values += $num
        }
    }

    if ($values.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No valid numeric values found.")
        return
    }

    $total = ($values | Measure-Object -Sum).Sum
    $diff = $target - $total

    $lblTotal.Text = "Total: {0:N2} hours ({1})" -f $total, (To-HoursMinutes $total)
    $lblDiff.Text = "Difference (target - total): {0:N2} hours ({1})" -f $diff, (To-HoursMinutes $diff)
})

# --- Run the Form ---
[void]$form.ShowDialog()
