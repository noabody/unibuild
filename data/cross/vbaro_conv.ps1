Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Main Form Window ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Universal GBA Cheat Manager (RetroArch <-> VBA-M)"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"

# Memory tracking for loaded cheats: Keys = Descriptions, Values = List of Code Strings ("XXXXXXXX YYYY")
$script:CheatDatabase = [ordered]@{ }

# --- GUI Controls ---
$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load File (.cht / .clt)"
$btnLoad.Location = New-Object System.Drawing.Point(20, 15)
$btnLoad.Size = New-Object System.Drawing.Size(180, 35)
$form.Controls.Add($btnLoad)

$lblList = New-Object System.Windows.Forms.Label
$lblList.Text = "Grouped Cheat Descriptions:"
$lblList.Location = New-Object System.Drawing.Point(20, 65)
$lblList.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($lblList)

$lstCheats = New-Object System.Windows.Forms.ListBox
$lstCheats.Location = New-Object System.Drawing.Point(20, 85)
$lstCheats.Size = New-Object System.Drawing.Size(260, 390)
$form.Controls.Add($lstCheats)

$lblEditor = New-Object System.Windows.Forms.Label
$lblEditor.Text = "Codes in Selected Group (One per line, XXXXXXXX YYYY):"
$lblEditor.Location = New-Object System.Drawing.Point(300, 65)
$lblEditor.Size = New-Object System.Drawing.Size(400, 20)
$form.Controls.Add($lblEditor)

$txtEditor = New-Object System.Windows.Forms.TextBox
$txtEditor.Multiline = $true
$txtEditor.ScrollBars = "Vertical"
$txtEditor.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtEditor.Location = New-Object System.Drawing.Point(300, 85)
$txtEditor.Size = New-Object System.Drawing.Size(460, 390)
$form.Controls.Add($txtEditor)

$btnSaveGroup = New-Object System.Windows.Forms.Button
$btnSaveGroup.Text = "Update Current Group Modifications"
$btnSaveGroup.Location = New-Object System.Drawing.Point(300, 485)
$btnSaveGroup.Size = New-Object System.Drawing.Size(460, 30)
$form.Controls.Add($btnSaveGroup)

$btnExportVba = New-Object System.Windows.Forms.Button
$btnExportVba.Text = "Export to VBA-M .clt"
$btnExportVba.Location = New-Object System.Drawing.Point(20, 485)
$btnExportVba.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportVba)

$btnExportRa = New-Object System.Windows.Forms.Button
$btnExportRa.Text = "Export to RetroArch .cht"
$btnExportRa.Location = New-Object System.Drawing.Point(155, 485)
$btnExportRa.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportRa)

# --- HELPER FUNCTIONS ---

function Refresh-CheatList {
    $lstCheats.Items.Clear()
    foreach ($key in $script:CheatDatabase.Keys) {
        [void]$lstCheats.Items.Add($key)
    }
    if ($lstCheats.Items.Count -gt 0) {
        $lstCheats.SelectedIndex = 0
    } else {
        $txtEditor.Clear()
    }
}

# --- PARSING ENGINES ---

function Import-RetroArchCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    $tempDesc = @{}
    $tempCode = @{}

    foreach ($line in $lines) {
        if ($line -match '^cheat(\d+)_desc\s*=\s*"(.*)"') {
            $tempDesc[$Matches[1]] = $Matches[2].Trim()
        }
        elseif ($line -match '^cheat(\d+)_code\s*=\s*"(.*)"') {
            $tempCode[$Matches[1]] = $Matches[2].Trim()
        }
    }

    foreach ($idx in $tempDesc.Keys) {
        $desc = $tempDesc[$idx]
        $rawCodes = $tempCode[$idx]
        
        $cleanLines = [regex]::Matches($rawCodes, '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4})')
        
        if (-not $script:CheatDatabase.Contains($desc)) {
            $script:CheatDatabase[$desc] = New-Object System.Collections.Generic.List[string]
        }
        foreach ($m in $cleanLines) {
            $script:CheatDatabase[$desc].Add($m.Value.ToUpper())
        }
    }
}

function Import-VbaClt ([string]$filePath) {
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 12) { return }

    $totalRecords = [System.BitConverter]::ToInt32($bytes, 8)
    
    # Dynamic Stride Calculation Strategy: Detect structural footprint layout on the fly
    $remainingBytes = $bytes.Length - 12
    $stride = 84 
    if ($totalRecords -gt 0) {
        $calculatedStride = $remainingBytes / $totalRecords
        if ($calculatedStride -eq 80) { $stride = 80 }
    }

    $offset = 12
    for ($i = 0; $i -lt $totalRecords; $i++) {
        if ($offset + $stride -gt $bytes.Length) { break }

        # Legacy 80-byte shifts code string tracking forward by 4 index positions due to missing rawaddress variable
        $codeStringOffset = if ($stride -eq 80) { $offset + 28 } else { $offset + 32 }
        $descStringOffset = if ($stride -eq 80) { $offset + 48 } else { $offset + 52 }

        $codeString = [System.Text.Encoding]::ASCII.GetString($bytes, $codeStringOffset, 20).Split("`0")[0].Trim()
        $descString = [System.Text.Encoding]::ASCII.GetString($bytes, $descStringOffset, 32).Split("`0")[0].Trim()

        if ([string]::IsNullOrWhiteSpace($descString)) { $descString = "Unassigned Code Block" }

        if ($codeString -match '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4})') {
            $cleanCode = $Matches[0].ToUpper()
            
            if (-not $script:CheatDatabase.Contains($descString)) {
                $script:CheatDatabase[$descString] = New-Object System.Collections.Generic.List[string]
            }
            $script:CheatDatabase[$descString].Add($cleanCode)
        }
        $offset += $stride
    }
}

# --- INTERACTIVE EVENT TRIGGERS ---

$btnLoad.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "GBA Cheat Files (*.cht;*.clt)|*.cht;*.clt"
    
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:CheatDatabase.Clear()
            if ($ofd.FileName.EndsWith(".cht", [System.StringComparison]::OrdinalIgnoreCase)) {
                Import-RetroArchCht $ofd.FileName
            } else {
                Import-VbaClt $ofd.FileName
            }
            Refresh-CheatList
            [System.Windows.Forms.MessageBox]::Show("Successfully parsed and grouped items by description name!", "Import Finished", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Parsing execution error: `n$_", "Error", "OK", "Error")
        }
    }
})

$lstCheats.Add_SelectedIndexChanged({
    if ($lstCheats.SelectedItem -ne $null) {
        $selectedDesc = $lstCheats.SelectedItem.ToString()
        $txtEditor.Text = [string]::Join("`r`n", $script:CheatDatabase[$selectedDesc])
    }
})

$btnSaveGroup.Add_Click({
    if ($lstCheats.SelectedItem -eq $null) { return }
    $selectedDesc = $lstCheats.SelectedItem.ToString()
    
    $updatedCodes = New-Object System.Collections.Generic.List[string]
    foreach ($line in $txtEditor.Lines) {
        if ($line -match '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4})') {
            $updatedCodes.Add($Matches[0].ToUpper())
        }
    }
    $script:CheatDatabase[$selectedDesc] = $updatedCodes
    [System.Windows.Forms.MessageBox]::Show("Group data cache updated.", "Saved", "OK", "Information")
})

# --- EXPORT PIPELINES ---

$btnExportVba.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are currently empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "VBA Cheat Files (*.clt)|*.clt"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $totalFlattenedCheats = 0
            foreach ($key in $script:CheatDatabase.Keys) { $totalFlattenedCheats += $script:CheatDatabase[$key].Count }

            $stream = [System.IO.File]::OpenWrite($sfd.FileName)
            $writer = New-Object System.IO.BinaryWriter($stream)

            $writer.Write([int]1)
            $writer.Write([int]1)
            $writer.Write([int]$totalFlattenedCheats)

            foreach ($desc in $script:CheatDatabase.Keys) {
                # Force sanitization to true 7-bit ASCII boundaries to eliminate '?' corruptions
                $safeDesc = [System.Text.RegularExpressions.Regex]::Replace($desc, '[^\x20-\x7E]', '')
                $descBytes = [System.Text.Encoding]::ASCII.GetBytes($safeDesc.PadRight(32, "`0"))
                if ($descBytes.Length -gt 32) { $descBytes = $descBytes[0..31] }

                foreach ($codeItem in $script:CheatDatabase[$desc]) {
                    $parts = $codeItem -split '\s+'
                    $part1 = $parts[0]
                    $part2 = $parts[1]

                    $typeHex = $part1.Substring(0, 1)
                    $typeInt = [System.Convert]::ToInt32($typeHex, 16)
                    $rawAddr = [System.Convert]::ToUInt32($part1, 16)
                    $value   = [System.Convert]::ToUInt32($part2, 16)
                    
                    $cleanAddrHex = "0" + $part1.Substring(1)
                    $cleanAddr    = [System.Convert]::ToUInt32($cleanAddrHex, 16)

                    $codeStrBytes = [System.Text.Encoding]::ASCII.GetBytes($codeItem.PadRight(20, "`0"))

                    $writer.Write([int]$typeInt)      # code
                    $writer.Write([int]0)             # size
                    $writer.Write([int]0)             # status
                    $writer.Write([int]1)             # enabled
                    $writer.Write([uint32]$rawAddr)   # rawaddress
                    $writer.Write([uint32]$cleanAddr) # address
                    $writer.Write([uint32]$value)     # value
                    $writer.Write([uint32]0)          # oldValue
                    $writer.Write($codeStrBytes)      # codestring[20]
                    $writer.Write($descBytes)         # desc[32]
                }
            }
            $writer.Close()
            $stream.Close()
            [System.Windows.Forms.MessageBox]::Show("Generated fixed-width 84-byte .clt file container structure!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Serialization error encountered: `n$_", "Error", "OK", "Error")
        }
    }
})

$btnExportRa.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are currently empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "RetroArch Cheat Files (*.cht)|*.cht"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("cheats = $($script:CheatDatabase.Count)")
            
            $idx = 0
            foreach ($desc in $script:CheatDatabase.Keys) {
                # Collapse all multi-line codes under this group name together using "+"
                $joinedCodes = [string]::Join("+", $script:CheatDatabase[$desc])
                
                [void]$sb.AppendLine("cheat${idx}_desc = `"$desc`"")
                [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
                [void]$sb.AppendLine("cheat${idx}_enable = false")
                
                $idx++
            }
            
            # Secure cross-platform output using standard UTF-8 encoding without complex BOM conflicts
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show("Successfully generated RetroArch text-collapsed format configuration file!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Text write error encountered: `n$_", "Error", "OK", "Error")
        }
    }
})

# Launch GUI Window Thread Context
$form.ShowDialog()
