Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Main Form Window ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Universal SNES Cheat Manager (RetroArch <-> Snes9x)"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"

# Memory tracking for loaded cheats: Keys = Descriptions, Values = List of Code Strings ("XXXX-XXXX" or "XXXXXXXX")
$script:CheatDatabase = [ordered]@{ }
$script:IsDirty = $false
$script:LastSelectedIndex = -1

# RegEx Pattern for Valid SNES Codes: Game Genie (XXXX-XXXX) or Pro Action Replay (XXXXXX=XX / XXXXXXXX)
$script:SnesCodePattern = '([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}=[0-9A-Fa-f]{2}|[0-9A-Fa-f]{8})'

# --- CORE HANDLER DEFINITIONS ---
$script:TextChangeHandler = {
    $script:IsDirty = $true
}

# --- HELPER FUNCTIONS ---

# Helper to verify if an incoming description key collision shares the same architecture type
function Get-SafeCodeDescription ([string]$baseDesc, [string]$incomingCode) {
    if (-not $script:CheatDatabase.Contains($baseDesc)) {
        return $baseDesc
    }
    
    # Paradigm check: True if Game Genie (contains a hyphen), False if pure Hex PAR
    $incomingIsGG = $incomingCode.Contains("-")
    $existingList = $script:CheatDatabase[$baseDesc]
    
    if ($existingList.Count -gt 0) {
        $existingIsGG = $existingList[0].Contains("-")
        # If architectures match (GG+GG or PAR+PAR), it's safe to group under the same key
        if ($incomingIsGG -eq $existingIsGG) {
            return $baseDesc
        }
    }
    
    # Incompatible architectural styles or explicit separate keys: split them safely
    $suffix = if ($incomingIsGG) { " [GG]" } else { " [PAR]" }
    $resolvedDesc = $baseDesc + $suffix
    
    # Edge case check for secondary safety collisions
    $counter = 1
    $baseResolved = $resolvedDesc
    while ($script:CheatDatabase.Contains($resolvedDesc)) {
        $resolvedDesc = "${baseResolved} (${counter})"
        $counter++
    }
    return $resolvedDesc
}

function Update-UIState {
    $hasItems = $lstCheats.Items.Count -gt 0
    $btnMoveUp.Enabled = $hasItems
    $btnMoveDown.Enabled = $hasItems
    $btnDeleteGroup.Enabled = $hasItems
    $btnSaveGroup.Enabled = $hasItems
}

function Refresh-CheatList {
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

function Save-CurrentSelectionIfDirty {
    if ($script:IsDirty -and $script:LastSelectedIndex -ge 0 -and $script:LastSelectedIndex -lt $lstCheats.Items.Count) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Save changes to the current group before proceeding?", "Unsaved Progress", "YesNoCancel", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult].Cancel) { return $false }
        if ($choice -eq [System.Windows.Forms.DialogResult].Yes) {
            $selectedDesc = $lstCheats.Items[$script:LastSelectedIndex].ToString()
            $updatedCodes = New-Object System.Collections.Generic.List[string]
            foreach ($line in $txtEditor.Lines) {
                if ($line -match $script:SnesCodePattern) { 
                    # Store as clean format inside internal UI cache (stripping any accidental manually entered '=')
                    $cleanCode = $Matches[0].ToUpper().Replace("=", "")
                    $updatedCodes.Add($cleanCode) 
                }
            }
            $script:CheatDatabase[$selectedDesc] = $updatedCodes
        }
        $script:IsDirty = $false
    }
    return $true
}

# --- GUI Controls Construction ---
$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load File (.cht)"
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
$lblEditor.Text = "Codes (One per line, XXXX-XXXX or XXXXXXXX):"
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

$btnExportS9x = New-Object System.Windows.Forms.Button
$btnExportS9x.Text = "Export to Snes9x .cht"
$btnExportS9x.Location = New-Object System.Drawing.Point(20, 485)
$btnExportS9x.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportS9x)

$btnExportRa = New-Object System.Windows.Forms.Button
$btnExportRa.Text = "Export to RetroArch .cht"
$btnExportRa.Location = New-Object System.Drawing.Point(155, 485)
$btnExportRa.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportRa)

# --- PARSING ENGINES ---

function Import-RetroArchCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    $rawDesc = $null
    $currentDesc = $null

    foreach ($line in $lines) {
        if ($line -match '^cheat\d+_desc\s*=\s*"(.*)"') {
            $rawDesc = $Matches[1].Trim()
            $currentDesc = $null 
        }
        elseif ($line -match '^cheat\d+_code\s*=\s*"(.*)"') {
            $descToUse = if ($null -ne $rawDesc) { $rawDesc } else { "Unassigned Code Block" }

            $rawCodes = $Matches[1].Trim()
            $individualCodes = $rawCodes -split '[\++\s+]'
            
            foreach ($code in $individualCodes) {
                $sanitizedCode = $code.Replace("O", "0").Replace("o", "0")
                if ($sanitizedCode -match $script:SnesCodePattern) {
                    # Capture the clean code (keeps it strictly as XXXX-XXXX or clean XXXXXXXX)
                    $cleanCode = $Matches[0].ToUpper().Replace("=", "")

                    if ($null -eq $currentDesc) {
                        $currentDesc = Get-SafeCodeDescription $descToUse $cleanCode
                        if (-not $script:CheatDatabase.Contains($currentDesc)) {
                            $script:CheatDatabase[$currentDesc] = New-Object System.Collections.Generic.List[string]
                        }
                    }

                    $script:CheatDatabase[$currentDesc].Add($cleanCode)
                }
            }
        }
    }
}

function Import-Snes9xCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    $rawDesc = $null
    $currentDesc = $null

    foreach ($line in $lines) {
        if ($line -match '^\s*name:\s*(.*)') {
            $rawDesc = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($rawDesc)) { $rawDesc = "Unassigned Code Block" }
            $currentDesc = $null 
        }
        elseif ($line -match '^\s*code:\s*(.*)') {
            $descToUse = if ($null -ne $rawDesc) { $rawDesc } else { "Unassigned Code Block" }

            $rawCodes = $Matches[1].Trim()
            $individualCodes = $rawCodes -split '[\++\s+]'
            
            foreach ($code in $individualCodes) {
                # Strip the Snes9x '=' instantly to normalize to clean 8-char internal layout
                $sanitizedCode = $code.Replace("=", "").Replace("O", "0").Replace("o", "0")
                if ($sanitizedCode -match $script:SnesCodePattern) {
                    $cleanCode = $Matches[0].ToUpper().Replace("=", "")

                    if ($null -eq $currentDesc) {
                        $currentDesc = Get-SafeCodeDescription $descToUse $cleanCode
                        if (-not $script:CheatDatabase.Contains($currentDesc)) {
                            $script:CheatDatabase[$currentDesc] = New-Object System.Collections.Generic.List[string]
                        }
                    }

                    $script:CheatDatabase[$currentDesc].Add($cleanCode)
                }
            }
        }
    }
}

# --- INTERACTIVE EVENT TRIGGERS ---

$btnLoad.Add_Click({
    if ($script:IsDirty) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes and load a new file?", "Unsaved Changes", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }
    }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "SNES Cheat Files (*.cht)|*.cht"
    
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:CheatDatabase.Clear()
            $firstLine = ([System.IO.File]::ReadLines($ofd.FileName) | Select-Object -First 1).Trim()
            if ($firstLine -match '^cheats\s*=' -or $firstLine -match '^cheat\d+_') {
                Import-RetroArchCht $ofd.FileName
            }
            elseif ($firstLine -eq "cheat") {
                Import-Snes9xCht $ofd.FileName
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("Unknown or invalid cheat file format.", "Error", "OK", "Error")
            }
            Refresh-CheatList
            $txtNewGroup.Clear()
            [System.Windows.Forms.MessageBox]::Show("Successfully parsed and isolated items safely by architecture matching rules!", "Import Finished", "OK", "Information")
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
        if ($line -match $script:SnesCodePattern) {
            # Keep as clean XXXXXXXX text strings inside UI cache
            $cleanCode = $Matches[0].ToUpper().Replace("=", "")
            $updatedCodes.Add($cleanCode)
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

$btnExportS9x.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are currently empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "Snes9x Cheat Files (*.cht)|*.cht"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            if (Test-Path $sfd.FileName) { Remove-Item $sfd.FileName -Force }

            $sb = New-Object System.Text.StringBuilder
            
            foreach ($desc in $script:CheatDatabase.Keys) {
                foreach ($codeItem in $script:CheatDatabase[$desc]) {
                    $outputCode = $codeItem
                    # Dynamically add the '=' partition structure ONLY on output execution
                    if ($outputCode.Length -eq 8 -and -not $outputCode.Contains("-")) {
                        $outputCode = $outputCode.Substring(0, 6) + "=" + $outputCode.Substring(6, 2)
                    }
                    
                    [void]$sb.AppendLine("cheat")
                    [void]$sb.AppendLine("  name: $desc")
                    [void]$sb.AppendLine("  code: $outputCode")
                    [void]$sb.AppendLine("")
                }
            }
            
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show("Successfully generated Snes9x multi-block text layout file!", "Export Complete", "OK", "Information")
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
            if (Test-Path $sfd.FileName) { Remove-Item $sfd.FileName -Force }

            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("cheats = $($script:CheatDatabase.Count)")
            
            $idx = 0
            foreach ($desc in $script:CheatDatabase.Keys) {
                # We can now join directly since codes are saved clean internally
                $joinedCodes = [string]::Join("+", $script:CheatDatabase[$desc])
                [void]$sb.AppendLine("cheat${idx}_desc = `"$desc`"")
                [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
                [void]$sb.AppendLine("cheat${idx}_enable = false")
                $idx++
            }
            
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show("Successfully generated RetroArch text configuration file!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Text write error encountered: `n$_", "Error", "OK", "Error")
        }
    }
})

# Launch GUI Window Thread Context
$form.ShowDialog()
