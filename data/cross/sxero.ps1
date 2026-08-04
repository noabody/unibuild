Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Main Form Window ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Universal PlayStation Cheat Manager (RetroArch <-> ePSXe)"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"

# Memory tracking for loaded cheats: Keys = Descriptions, Values = List of Code Strings
$script:CheatDatabase = [ordered]@{ }
$script:IsDirty = $false
$script:LastSelectedIndex = -1

# Core Hex Extractor Pattern: Matches an 8-digit block, then grabs the trailing 4 to 8 digit block
$script:HexBlockPattern = '([0-9A-Fa-f]{8})[\s+:+]*([0-9A-Fa-f]{4,8})'

# --- CORE HANDLER DEFINITIONS ---
$script:TextChangeHandler = {
    $script:IsDirty = $true
}

# --- HELPER FUNCTIONS ---

# Centralized normalization engine to fix malformed formatting issues
function Parse-AndNormalizeLine ([string]$inputLine) {
    if ([string]::IsNullOrWhiteSpace($inputLine)) { return $null }
    
    # Mirroring Bash logic: Replace capital/lowercase 'O' with '0'
    $sanitizedLine = $inputLine.Replace("O", "0").Replace("o", "0")
    
    # Extract all valid hex pairs on the line
    $matches = [regex]::Matches($sanitizedLine, $script:HexBlockPattern)
    if ($matches.Count -eq 0) { return $null }
    
    $normalizedSegments = New-Object System.Collections.Generic.List[string]
    foreach ($m in $matches) {
        $addr = $m.Groups[1].Value.ToUpper()
        $val  = $m.Groups[2].Value.ToUpper()
        $normalizedSegments.Add("$addr $val")
    }
    
    return $normalizedSegments.ToArray()
}

# Helper to verify if an incoming description key collision shares the same architecture type
function Get-SafeCodeDescription ([string]$baseDesc, [string]$incomingCode) {
    if (-not $script:CheatDatabase.Contains($baseDesc)) {
        return $baseDesc
    }
    
    # Paradigm check: True if standard 8-4 code layout, False if long 8-8 text layout
    $cleanSplit = $incomingCode -split '\s+'
    $incomingIsShort = ($cleanSplit[-1].Length -eq 4)
    $existingList = $script:CheatDatabase[$baseDesc]
    
    if ($existingList.Count -gt 0) {
        $existingSplit = $existingList[0] -split '\s+'
        $existingIsShort = ($existingSplit[-1].Length -eq 4)
        # If architectures match, safe to group under the same key
        if ($incomingIsShort -eq $existingIsShort) {
            return $baseDesc
        }
    }
    
    $suffix = if ($incomingIsShort) { " [Short]" } else { " [Long]" }
    $resolvedDesc = $baseDesc + $suffix
    
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
        $txtEditor.Text = [string]::Join([Environment]::NewLine, $script:CheatDatabase[$selectedDesc])
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
        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            $selectedDesc = $lstCheats.Items[$script:LastSelectedIndex].ToString()
            $updatedCodes = New-Object System.Collections.Generic.List[string]
            foreach ($line in $txtEditor.Lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $cleanCodes = Parse-AndNormalizeLine $line
                if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
                    $updatedCodes.AddRange([string[]]$cleanCodes)
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
$btnLoad.Text = "Load File (.cht / .txt)"
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
$lblEditor.Text = "Codes (One per line, XXXXXXXX YYYY or XXXXXXXX YYYYYYYY):"
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

$btnExportEpsxe = New-Object System.Windows.Forms.Button
$btnExportEpsxe.Text = "Export to ePSXe .txt"
$btnExportEpsxe.Location = New-Object System.Drawing.Point(20, 485)
$btnExportEpsxe.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportEpsxe)

$btnExportRa = New-Object System.Windows.Forms.Button
$btnExportRa.Text = "Export to RetroArch .cht"
$btnExportRa.Location = New-Object System.Drawing.Point(155, 485)
$btnExportRa.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportRa)

# --- PARSING ENGINES ---

# Stateful RetroArch Engine mirroring the advanced lookbehind context of the original Bash tool
function Import-RetroArchCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    
    # Pre-scan for orphan categories exactly like the Bash pipeline
    $descMap = [ordered]@{ }
    $codeMap = [ordered]@{ }
    $categoryHeader = "Unassigned Code Block"
    
    foreach ($line in $lines) {
        if ($line -match '^cheat(\d+)_desc\s*=\s*"(.*)"') {
            $descMap[$Matches[1]] = $Matches[2].Trim()
        }
        elseif ($line -match '^cheat(\d+)_code\s*=\s*"(.*)"') {
            $codeMap[$Matches[1]] = $Matches[2].Trim()
        }
    }

    # Determine if we have unmapped description blocks to bundle as structural categories
    $hasOrphans = $false
    foreach ($k in $descMap.Keys) {
        if (-not $codeMap.Contains($k)) { $hasOrphans = $true; break }
    }

    $mergeCategories = $false
    if ($hasOrphans) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Cheat descriptions found without matching codes.`n`nTreat empty labels as parent categories and group subsequent blocks?", "Category Layout Detected", "YesNo", "Question")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { $mergeCategories = $true }
    }

    foreach ($k in $descMap.Keys) {
        $descText = $descMap[$k]
        
        if (-not $codeMap.Contains($k)) {
            if ($mergeCategories) { $categoryHeader = $descText }
            continue
        }
        
        $rawCodes = $codeMap[$k]
        $cleanCodes = Parse-AndNormalizeLine $rawCodes
        if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }
        
        $finalTitle = if ($mergeCategories) { "$categoryHeader - $descText" } else { $descText }
        $finalTitle = $finalTitle.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

        $safeTitle = Get-SafeCodeDescription $finalTitle ($cleanCodes[0])
        
        if (-not $script:CheatDatabase.Contains($safeTitle)) {
            $script:CheatDatabase[$safeTitle] = New-Object System.Collections.Generic.List[string]
        }
        $script:CheatDatabase[$safeTitle].AddRange([string[]]$cleanCodes)
    }
}

function Import-EpsxeTxt ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    
    # Pre-scan into memory structures to handle orphans and categories consistently
    $blocks = New-Object System.Collections.Generic.List[psobject]
    $currentHeader = "Unassigned Code Block"
    $currentCodes = New-Object System.Collections.Generic.List[string]
    $hasOrphans = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^#(.*)') {
            # Check if previous header contained no codes (orphan / parent category candidate)
            if ($currentCodes.Count -eq 0 -and $currentHeader -ne "Unassigned Code Block") {
                $hasOrphans = $true
            }

            if ($currentCodes.Count -gt 0) {
                $blocks.Add([PSCustomObject]@{
                    Header = $currentHeader
                    Codes  = $currentCodes.ToArray()
                })
                $currentCodes = New-Object System.Collections.Generic.List[string]
            }
            $currentHeader = $Matches[1].Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($currentHeader)) { $currentHeader = "Unassigned Code Block" }
        }
        else {
            $cleanCodes = Parse-AndNormalizeLine $trimmed
            if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
                $currentCodes.AddRange([string[]]$cleanCodes)
            }
        }
    }

    # Flush final block
    if ($currentCodes.Count -gt 0) {
        $blocks.Add([PSCustomObject]@{
            Header = $currentHeader
            Codes  = $currentCodes.ToArray()
        })
    } elseif ($currentHeader -ne "Unassigned Code Block") {
        $hasOrphans = $true
    }

    # Prompt user for parent category merging if empty headers are present
    $mergeCategories = $false
    if ($hasOrphans) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Empty cheat headers found without codes.`n`nTreat empty headers as parent categories and group subsequent blocks?", "Category Layout Detected", "YesNo", "Question")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { $mergeCategories = $true }
    }

    # Populate the central database using Get-SafeCodeDescription
    $categoryHeader = "Unassigned Code Block"
    foreach ($block in $blocks) {
        $rawHeader = $block.Header
        $codes = $block.Codes

        if ($mergeCategories -and $codes.Count -eq 0) {
            $categoryHeader = $rawHeader
            continue
        }

        $finalTitle = if ($mergeCategories -and $categoryHeader -ne "Unassigned Code Block") { 
            "$categoryHeader - $rawHeader" 
        } else { 
            $rawHeader 
        }

        $safeTitle = Get-SafeCodeDescription $finalTitle ($codes[0])

        if (-not $script:CheatDatabase.Contains($safeTitle)) {
            $script:CheatDatabase[$safeTitle] = New-Object System.Collections.Generic.List[string]
        }
        $script:CheatDatabase[$safeTitle].AddRange([string[]]$codes)
    }
}

# --- INTERACTIVE EVENT TRIGGERS ---

$btnLoad.Add_Click({
    if ($script:IsDirty) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes and load a new file?", "Unsaved Changes", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }
    }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Cheat Files (*.cht;*.txt)|*.cht;*.txt|RetroArch Files (*.cht)|*.cht|ePSXe Files (*.txt)|*.txt"
    
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:CheatDatabase.Clear()
            
            $sampleLines = [System.IO.File]::ReadLines($ofd.FileName) | 
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
                Select-Object -First 5
                
            $isRetroArch = $false
            foreach ($line in $sampleLines) {
                if ($line -match '^cheats\s*=' -or $line -match '^cheat\d+_') {
                    $isRetroArch = $true
                    break
                }
            }

            if ($isRetroArch) {
                Import-RetroArchCht $ofd.FileName
            } else {
                Import-EpsxeTxt $ofd.FileName
            }
            
            Refresh-CheatList
            $txtNewGroup.Clear()
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
        $txtEditor.Text = [string]::Join([Environment]::NewLine, $script:CheatDatabase[$selectedDesc])
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
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $cleanCodes = Parse-AndNormalizeLine $line
        if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
            $updatedCodes.AddRange([string[]]$cleanCodes)
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

    $msg = "Are you sure you want to completely delete the group '$selectedDesc'?"
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
        $txtEditor.Text = [string]::Join([Environment]::NewLine, $script:CheatDatabase[$nextDesc])
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

    $keys = New-Object System.Collections.Generic.List[string] ($script:CheatDatabase.Keys)
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

$btnExportEpsxe.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "ePSXe Cheat Files (*.txt)|*.txt"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $sb = New-Object System.Text.StringBuilder
            foreach ($desc in $script:CheatDatabase.Keys) {
                if ($script:CheatDatabase[$desc].Count -eq 0) { continue }
                [void]$sb.AppendLine("#$desc")
                foreach ($codeItem in $script:CheatDatabase[$desc]) {
                    [void]$sb.AppendLine($codeItem)
                }
            }
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show("Successfully generated ePSXe file!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Serialization error: `n$_", "Error", "OK", "Error")
        }
    }
})

$btnExportRa.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "RetroArch Cheat Files (*.cht)|*.cht"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.AppendLine("cheats = $($script:CheatDatabase.Count)")
            [void]$sb.AppendLine("")
            
            $idx = 0
            foreach ($desc in $script:CheatDatabase.Keys) {
                $joinedCodes = [string]::Join("+", $script:CheatDatabase[$desc])
                [void]$sb.AppendLine("cheat${idx}_desc = `"$desc`"")
                [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
                [void]$sb.AppendLine("cheat${idx}_enable = false")
                [void]$sb.AppendLine("")
                $idx++
            }
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show("Successfully generated RetroArch file!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Text write error: `n$_", "Error", "OK", "Error")
        }
    }
})

# Display the application context
$form.ShowDialog()
