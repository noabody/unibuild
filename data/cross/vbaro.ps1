Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Main Form Window ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Universal GBA Cheat Manager (RetroArch <-> VBA-M)"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"

# Memory tracking for loaded cheats: Keys = Descriptions, Values = List of Code Strings ("XXXXXXXX YYYY")
$script:CheatDatabase = [ordered]@{ }
$script:IsDirty = $false
$script:LastSelectedIndex = -1

# --- CORE HANDLER DEFINITIONS (Must be initialized early) ---
$script:TextChangeHandler = {
    $script:IsDirty = $true
}

# --- HELPER FUNCTIONS (Declared upfront to prevent scope reference errors) ---

function Update-UIState {
    # Dynamically manages button availability states based on active collection records
    $hasItems = $lstCheats.Items.Count -gt 0
    $btnMoveUp.Enabled = $hasItems
    $btnMoveDown.Enabled = $hasItems
    $btnDeleteGroup.Enabled = $hasItems
    $btnSaveGroup.Enabled = $hasItems
}

function Refresh-CheatList {
    # Suppress event firing during manual refresh rebuild
    $lstCheats.UnregisterAllEventsOnIndexChange()
    $lstCheats.Items.Clear()
    foreach ($key in $script:CheatDatabase.Keys) {
        [void]$lstCheats.Items.Add($key)
    }
    $script:IsDirty = $false
    if ($lstCheats.Items.Count -gt 0) {
        $script:LastSelectedIndex = 0
        $lstCheats.SelectedIndex = 0
        $selectedDesc = $lstCheats.SelectedItem.ToString()
        
        # Guard programmatic assignment against triggering text-change events
        $txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $txtEditor.Text = [string]::Join("`r`n", $script:CheatDatabase[$selectedDesc])
        $script:IsDirty = $false
        $txtEditor.Add_TextChanged($script:TextChangeHandler)
    } else {
        $script:LastSelectedIndex = -1
        $txtEditor.Clear()
    }
    Update-UIState
    $lstCheats.RegisterEventsOnIndexChange()
}

# Helper to automatically capture uncommitted edits before structural database shifts
function Save-CurrentSelectionIfDirty {
    if ($script:IsDirty -and $script:LastSelectedIndex -ge 0 -and $script:LastSelectedIndex -lt $lstCheats.Items.Count) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Save changes to the current group before proceeding?", "Unsaved Progress", "YesNoCancel", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult].Cancel) { return $false }
        if ($choice -eq [System.Windows.Forms.DialogResult].Yes) {
            $selectedDesc = $lstCheats.Items[$script:LastSelectedIndex].ToString()
            $updatedCodes = New-Object System.Collections.Generic.List[string]
            foreach ($line in $txtEditor.Lines) {
                if ($line -match '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4})') { $updatedCodes.Add($Matches[0].ToUpper()) }
            }
            $script:CheatDatabase[$selectedDesc] = $updatedCodes
        }
        $script:IsDirty = $false
    }
    return $true
}

# --- GUI Controls Construction ---
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
$lstCheats.Size = New-Object System.Drawing.Size(260, 350)
$form.Controls.Add($lstCheats)

# Add helper properties dynamically to bypass event loops when clearing indexes
$lstCheats | Add-Member -MemberType ScriptMethod -Name "UnregisterAllEventsOnIndexChange" -Value {
    $this.Remove_SelectedIndexChanged($script:ListSelectionHandler)
} -Force
$lstCheats | Add-Member -MemberType ScriptMethod -Name "RegisterEventsOnIndexChange" -Value {
    $this.Add_SelectedIndexChanged($script:ListSelectionHandler)
} -Force

# --- Navigation and Edit Strips ---
$txtNewGroup = New-Object System.Windows.Forms.TextBox
$txtNewGroup.Location = New-Object System.Drawing.Point(20, 445)
$txtNewGroup.Size = New-Object System.Drawing.Size(100, 25)
$form.Controls.Add($txtNewGroup)

$btnNewGroup = New-Object System.Windows.Forms.Button
$btnNewGroup.Text = "Add"
$btnNewGroup.Location = New-Object System.Drawing.Point(125, 444)
$btnNewGroup.Size = New-Object System.Drawing.Size(40, 26)
$form.Controls.Add($btnNewGroup)

$btnMoveUp = New-Object System.Windows.Forms.Button
$btnMoveUp.Text = "▲"
$btnMoveUp.Location = New-Object System.Drawing.Point(170, 444)
$btnMoveUp.Size = New-Object System.Drawing.Size(35, 26)
$btnMoveUp.Enabled = $false
$form.Controls.Add($btnMoveUp)

$btnMoveDown = New-Object System.Windows.Forms.Button
$btnMoveDown.Text = "▼"
$btnMoveDown.Location = New-Object System.Drawing.Point(210, 444)
$btnMoveDown.Size = New-Object System.Drawing.Size(35, 26)
$btnMoveDown.Enabled = $false
$form.Controls.Add($btnMoveDown)

$btnDeleteGroup = New-Object System.Windows.Forms.Button
$btnDeleteGroup.Text = "❌"
$btnDeleteGroup.Location = New-Object System.Drawing.Point(250, 444)
$btnDeleteGroup.Size = New-Object System.Drawing.Size(30, 26)
$btnDeleteGroup.Enabled = $false
$form.Controls.Add($btnDeleteGroup)

# --- Right-Side Controls ---
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
$txtEditor.Add_TextChanged($script:TextChangeHandler)
$form.Controls.Add($txtEditor)

$btnSaveGroup = New-Object System.Windows.Forms.Button
$btnSaveGroup.Text = "Update Current Group Modifications"
$btnSaveGroup.Location = New-Object System.Drawing.Point(300, 485)
$btnSaveGroup.Size = New-Object System.Drawing.Size(460, 30)
$btnSaveGroup.Enabled = $false
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

# --- PARSING ENGINES ---

function Import-RetroArchCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    $currentDesc = $null

    foreach ($line in $lines) {
        if ($line -match '^cheat\d+_desc\s*=\s*"(.*)"') {
            $currentDesc = $Matches[1].Trim()
            if (-not $script:CheatDatabase.Contains($currentDesc)) {
                $script:CheatDatabase[$currentDesc] = New-Object System.Collections.Generic.List[string]
            }
        }
        elseif ($line -match '^cheat\d+_code\s*=\s*"(.*)"') {
            if ($null -eq $currentDesc) {
                $currentDesc = "Unassigned Code Block"
                if (-not $script:CheatDatabase.Contains($currentDesc)) {
                    $script:CheatDatabase[$currentDesc] = New-Object System.Collections.Generic.List[string]
                }
            }

            $rawCodes = $Matches[1].Trim()
            $cleanLines = [regex]::Matches($rawCodes, '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4})')
            
            foreach ($m in $cleanLines) {
                $script:CheatDatabase[$currentDesc].Add($m.Value.ToUpper())
            }
        }
    }
}

function Import-VbaClt ([string]$filePath) {
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 12) { return }

    $totalRecords = [System.BitConverter]::ToInt32($bytes, 8)
    $remainingBytes = $bytes.Length - 12
    $stride = 84 
    if ($totalRecords -gt 0) {
        $calculatedStride = $remainingBytes / $totalRecords
        if ($calculatedStride -eq 80) { $stride = 80 }
    }

    $offset = 12
    for ($i = 0; $i -lt $totalRecords; $i++) {
        if ($offset + $stride -gt $bytes.Length) { break }

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

function Import-MyBoyCht ([string]$filePath) {
    try {
        # Load the file directly as an XML DOM structure
        [xml]$xml = Get-Content $filePath -ErrorAction Stop
        
        # Guard clause in case it's a different XML format
        if ($null -eq $xml.cheats -or $null -eq $xml.cheats.cheat) { return }

        # Filter down exclusively to CodeBreaker type tags
        $cbCheats = $xml.cheats.cheat | Where-Object { $_.type -eq 'cb' }

        foreach ($cheat in $cbCheats) {
            $descString = $cheat.name.Trim()
            if ([string]::IsNullOrWhiteSpace($descString)) { $descString = "Unassigned Code Block" }

            # Enforce strict canonical labeling rule for [M] master codes
            if ($descString -eq "M") { $descString = "[M] Must Be On" }

            if (-not $script:CheatDatabase.Contains($descString)) {
                $script:CheatDatabase[$descString] = New-Object System.Collections.Generic.List[string]
            }

            # Gather all internal <code> elements, cleaning spacing anomalies
            foreach ($rawLine in $cheat.code) {
                $line = $rawLine.Trim()
                if ($line -match '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4})') {
                    $script:CheatDatabase[$descString].Add($Matches[0].ToUpper())
                }
            }
        }
    }
    catch {
        throw "Failed parsing MyBoy XML target: $_"
    }
}

# --- INTERACTIVE EVENT TRIGGERS ---

$btnLoad.Add_Click({
    if ($script:IsDirty) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes and load a new file?", "Unsaved Changes", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }
    }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "GBA Cheat Files (*.cht;*.clt)|*.cht;*.clt"
    
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:CheatDatabase.Clear()
            
            # Read first 3 lines to sniff out XML structure safely
            $sniffLines = ""
            if (Test-Path $ofd.FileName) {
                $sniffLines = [System.IO.File]::ReadLines($ofd.FileName) | Select-Object -First 3
                $sniffLines = [string]::Join(" ", $sniffLines).Trim()
            }

            # 1. Check for RetroArch Signature
            if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
                Import-RetroArchCht $ofd.FileName
            }
            # 2. Check for MyBoy XML Signature
            elseif ($sniffLines -match '<\?xml' -and $sniffLines -match '<cheats>') {
                Import-MyBoyCht $ofd.FileName
            }
            # 3. Fallback to Binary Signature evaluation (VBA-M)
            else {
                $stream = [System.IO.File]::OpenRead($ofd.FileName)
                $buffer = New-Object byte[] 12
                $bytesRead = $stream.Read($buffer, 0, 12)
                $stream.Close()
                $stream.Dispose()
                if ($bytesRead -ge 12) {
                    $hexSignature = [string]::Join(" ", ($buffer | ForEach-Object { "{0:X2}" -f $_ })).Trim()
                    if ($hexSignature -imatch '^01 00 00 00 (01|00) 00 00 00 [0-9A-Fa-f]{2} 00 00 00') {
                        Import-VbaClt $ofd.FileName
                    }
                    else {
                        [System.Windows.Forms.MessageBox]::Show("Unknown or invalid cheat file format signature.", "Error", "OK", "Error")
                        return
                    }
                }
                else {
                    [System.Windows.Forms.MessageBox]::Show("File is too small to contain a valid binary cheat header.", "Error", "OK", "Error")
                    return
                }
            }
            Refresh-CheatList
            $txtNewGroup.Clear()
            [System.Windows.Forms.MessageBox]::Show("Successfully parsed and grouped items by description name!", "Import Finished", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Parsing execution error: `n$_", "Error", "OK", "Error")
        }
    }
})

$script:ListSelectionHandler = {
    if ($lstCheats.SelectedIndex -eq $script:LastSelectedIndex) { return }

    if ($script:IsDirty -and $script:LastSelectedIndex -ge 0 -and $script:LastSelectedIndex -lt $lstCheats.Items.Count) {
        $choice = [System.Windows.Forms.MessageBox]::Show("You modified this cheat group but didn't save. Discard modifications?", "Unsaved Progress", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
            $lstCheats.UnregisterAllEventsOnIndexChange()
            $lstCheats.SelectedIndex = $script:LastSelectedIndex
            $lstCheats.RegisterEventsOnIndexChange()
            return
        }
    }

    if ($lstCheats.SelectedItem -ne $null) {
        $script:LastSelectedIndex = $lstCheats.SelectedIndex
        $selectedDesc = $lstCheats.SelectedItem.ToString()
        
        # Unhook/re-hook explicitly avoids ghost programmatic change detections
        $txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $txtEditor.Text = [string]::Join("`r`n", $script:CheatDatabase[$selectedDesc])
        $script:IsDirty = $false
        $txtEditor.Add_TextChanged($script:TextChangeHandler)
    }
}
$lstCheats.RegisterEventsOnIndexChange()

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
    $script:IsDirty = $false
    [System.Windows.Forms.MessageBox]::Show("Group data cache updated.", "Saved", "OK", "Information")
})

$btnNewGroup.Add_Click({
    $newTitle = $txtNewGroup.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($newTitle)) { return }

    if ($script:CheatDatabase.Contains($newTitle)) {
        [System.Windows.Forms.MessageBox]::Show("A cheat group with this description name already exists.", "Duplicate Found", "OK", "Warning")
        return
    }

    if (-not (Save-CurrentSelectionIfDirty)) { return }

    $script:CheatDatabase[$newTitle] = New-Object System.Collections.Generic.List[string]
    $txtNewGroup.Clear()

    $lstCheats.UnregisterAllEventsOnIndexChange()
    [void]$lstCheats.Items.Add($newTitle)
    $lstCheats.SelectedIndex = $lstCheats.Items.Count - 1
    $script:LastSelectedIndex = $lstCheats.SelectedIndex
    
    $txtEditor.Remove_TextChanged($script:TextChangeHandler)
    $txtEditor.Clear()
    $script:IsDirty = $false
    $txtEditor.Add_TextChanged($script:TextChangeHandler)
    
    Update-UIState
    $lstCheats.RegisterEventsOnIndexChange()
})

$txtNewGroup.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        $btnNewGroup.PerformClick()
    }
})

$btnDeleteGroup.Add_Click({
    $idx = $lstCheats.SelectedIndex
    if ($idx -lt 0) { return }
    $selectedDesc = $lstCheats.SelectedItem.ToString()

    $msg = "Are you sure you want to completely delete the group '$selectedDesc' and all its associated codes?"
    $choice = [System.Windows.Forms.MessageBox]::Show($msg, "Confirm Deletion", "YesNo", "Warning")
    if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }

    $script:CheatDatabase.Remove($selectedDesc)
    $script:IsDirty = $false

    $lstCheats.UnregisterAllEventsOnIndexChange()
    $lstCheats.Items.RemoveAt($idx)
    
    if ($lstCheats.Items.Count -gt 0) {
        $newIdx = if ($idx -lt $lstCheats.Items.Count) { $idx } else { $lstCheats.Items.Count - 1 }
        $lstCheats.SelectedIndex = $newIdx
        $script:LastSelectedIndex = $newIdx
        $nextDesc = $lstCheats.SelectedItem.ToString()
        
        $txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $txtEditor.Text = [string]::Join("`r`n", $script:CheatDatabase[$nextDesc])
        $txtEditor.Add_TextChanged($script:TextChangeHandler)
    } else {
        $script:LastSelectedIndex = -1
        $txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $txtEditor.Clear()
    }
    Update-UIState
    $lstCheats.RegisterEventsOnIndexChange()
})

function Move-CheatGroup ([int]$direction) {
    $idx = $lstCheats.SelectedIndex
    if ($idx -lt 0) { return }
    
    $targetIdx = $idx + $direction
    if ($targetIdx -lt 0 -or $targetIdx -ge $lstCheats.Items.Count) { return }

    if (-not (Save-CurrentSelectionIfDirty)) { return }

    $keys = [System.Collections.ArrayList]$script:CheatDatabase.Keys
    $temp = $keys[$idx]
    $keys[$idx] = $keys[$targetIdx]
    $keys[$targetIdx] = $temp

    $newDb = [ordered]@{ }
    foreach ($k in $keys) { $newDb[$k] = $script:CheatDatabase[$k] }
    $script:CheatDatabase = $newDb

    $lstCheats.UnregisterAllEventsOnIndexChange()
    $lstCheats.Items.Clear()
    foreach ($k in $script:CheatDatabase.Keys) { [void]$lstCheats.Items.Add($k) }
    
    $lstCheats.SelectedIndex = $targetIdx
    $script:LastSelectedIndex = $targetIdx
    $script:IsDirty = $false
    $lstCheats.RegisterEventsOnIndexChange()
}

$btnMoveUp.Add_Click({ Move-CheatGroup -1 })
$btnMoveDown.Add_Click({ Move-CheatGroup 1 })

# --- EXPORT PIPELINES ---

$btnExportVba.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are currently empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "VBA Cheat Files (*.clt)|*.clt"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $stream = $null
        $writer = $null
        try {
            if (Test-Path $sfd.FileName) { Remove-Item $sfd.FileName -Force }

            $stream = [System.IO.File]::Create($sfd.FileName)
            $writer = New-Object System.IO.BinaryWriter($stream)

            $maskMap = @{
                '0' = 0xFF; '1' = 0x70; '2' = 0x21; '3' = 0x00
                '4' = 0x09; '5' = 0x24; '6' = 0x0B; '7' = 0x08
                '8' = 0x01; '9' = 0xFF; 'A' = 0x0A; 'B' = 0x23
                'C' = 0x22; 'D' = 0x07; 'E' = 0x20; 'F' = 0x32
            }

            $totalFlattenedCheats = 0
            foreach ($key in $script:CheatDatabase.Keys) { $totalFlattenedCheats += $script:CheatDatabase[$key].Count }
            $writer.Write([int]1)
            $writer.Write([int]1)
            $writer.Write([int]$totalFlattenedCheats)

            foreach ($desc in $script:CheatDatabase.Keys) {
                $safeDesc = [System.Text.RegularExpressions.Regex]::Replace($desc, '[^\x20-\x7E]', '')
                $descBytes = [System.Text.Encoding]::ASCII.GetBytes($safeDesc.PadRight(32, "`0"))
                if ($descBytes.Length -gt 32) { $descBytes = $descBytes[0..31] }

                # Down-counters for handling trailing data blocks dynamically
                $dataLinesRemaining = 0
                $isSlideNextLine = $false

                foreach ($codeItem in $script:CheatDatabase[$desc]) {
                    $parts = $codeItem -split '\s+'
                    if ($parts.Count -lt 2) { continue }
                    
                    $part1 = $parts[0].ToUpper().PadRight(8, '0').Substring(0,8)
                    $part2 = $parts[1].ToUpper().PadRight(4, '0').Substring(0,4)
                    $ctyp = $part1.Substring(0, 1)

                    # --- PARSE ENDIAN AND SYSTEM BYTE PATTERNS ---
                    $cd8Bytes = New-Object byte[] 4
                    for($i=0; $i -lt 4; $i++) { $cd8Bytes[$i] = [System.Convert]::ToByte($part1.Substring((6 - $i*2), 2), 16) }

                    $part1Zeroed = "0" + $part1.Substring(1)
                    $cd8zBytes = New-Object byte[] 4
                    for($i=0; $i -lt 4; $i++) { $cd8zBytes[$i] = [System.Convert]::ToByte($part1Zeroed.Substring((6 - $i*2), 2), 16) }

                    $cd4Bytes = New-Object byte[] 2
                    for($i=0; $i -lt 2; $i++) { $cd4Bytes[$i] = [System.Convert]::ToByte($part2.Substring((2 - $i*2), 2), 16) }

                    # --- EVALUATE MULTI-LINE MASKING STATES ---
                    $isMultiLineOverride = $false
                    
                    if ($dataLinesRemaining -gt 0) {
                        # Explicitly mask current trailing line as raw binary payload data
                        $isMultiLineOverride = $true
                        $dataLinesRemaining--
                    }
                    elseif ($isSlideNextLine) {
                        # Handle the single explicit parameter trailing line for Type 4 codes
                        $isMultiLineOverride = $true
                        $isSlideNextLine = $false
                    }

                    # Determine internal emulator verification mask
                    $maskVal = if ($isMultiLineOverride) { 0xFF } else { $maskMap[$ctyp] }
                    if ($null -eq $maskVal) { $maskVal = 0x00 }

                    # Raw payload lines do not clear the code identifier digit prefix
                    if ($maskVal -eq 0xFF) { $cd8zBytes = $cd8Bytes }

                    $codeStrBytes = [System.Text.Encoding]::ASCII.GetBytes($codeItem.PadRight(20, "`0"))
                    if ($codeStrBytes.Length -gt 20) { $codeStrBytes = $codeStrBytes[0..19] }

                    # --- BINARY FILE WRITER SERIALIZATION ---
                    $writer.Write([byte]0x00); $writer.Write([byte]0x02); $writer.Write([byte]0x00); $writer.Write([byte]0x00)

                    if ($isMultiLineOverride -or $ctyp -eq '0' -or $ctyp -eq '9') {
                        $writer.Write([byte]0xFF); $writer.Write([byte]0xFF); $writer.Write([byte]0xFF); $writer.Write([byte]0xFF)
                    } else {
                        $writer.Write([byte]$maskVal); $writer.Write([byte]0x00); $writer.Write([byte]0x00); $writer.Write([byte]0x00)
                    }
                    $writer.Write([int]0)
                    $writer.Write([int]0)
                    
                    for ($bIdx = 0; $bIdx -lt 4; $bIdx++) { $writer.Write([byte]$cd8Bytes[$bIdx]) }
                    for ($bIdx = 0; $bIdx -lt 4; $bIdx++) { $writer.Write([byte]$cd8zBytes[$bIdx]) }
                    for ($bIdx = 0; $bIdx -lt 2; $bIdx++) { $writer.Write([byte]$cd4Bytes[$bIdx]) }
                    
                    $writer.Write([byte]0x00); $writer.Write([byte]0x00); $writer.Write([byte]0x00)
                    $writer.Write([byte]0x00); $writer.Write([byte]0x00); $writer.Write([byte]0x00)

                    for ($bIdx = 0; $bIdx -lt 20; $bIdx++) { $writer.Write([byte]$codeStrBytes[$bIdx]) }
                    for ($bIdx = 0; $bIdx -lt 32; $bIdx++) { $writer.Write([byte]$descBytes[$bIdx]) }

                    # --- SET STATE LOOK-AHEAD FOR NEXT ITERATIONS ---
                    if (-not $isMultiLineOverride) {
                        if ($ctyp -eq '5') {
                            # Type 5 math: Calculate total trailing raw data lines to ingest
                            $halfwordCount = [System.Convert]::ToInt32($part2, 16)
                            $dataLinesRemaining = [int](([Math]::Floor(($halfwordCount - 1) -band 0xFFFF) / 3) + 1)
                        } 
                        elseif ($ctyp -eq '4') {
                            # Type 4 (Slide Code) takes exactly 1 subsequent parameter configuration line
                            $isSlideNextLine = $true
                        }
                    }
                }
            }
            [System.Windows.Forms.MessageBox]::Show("Successfully generated compliant 84-byte binary structures!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Serialization error encountered: `n$_", "Error", "OK", "Error")
        }
        finally {
            if ($null -ne $writer) { $writer.Close(); $writer.Dispose() }
            if ($null -ne $stream) { $stream.Close(); $stream.Dispose() }
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
            if (Test-Path $sfd.FileName) { Remove-Item $sfd.FileName -Force }

            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("cheats = $($script:CheatDatabase.Count)")
            
            $idx = 0
            foreach ($desc in $script:CheatDatabase.Keys) {
                $joinedCodes = [string]::Join("+", $script:CheatDatabase[$desc])
                [void]$sb.AppendLine("cheat${idx}_desc = `"$desc`"")
                [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
                [void]$sb.AppendLine("cheat${idx}_enable = false")
                $idx++
            }
            
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
