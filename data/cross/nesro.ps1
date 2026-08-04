Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Main Form Window ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Universal NES Cheat Manager (RetroArch <-> nes.emu)"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"

# Memory tracking for loaded cheats: Keys = Descriptions, Values = List of Code Strings
$script:CheatDatabase = [ordered]@{ }
$script:IsDirty = $false
$script:LastSelectedIndex = -1

# Core Game Genie / Raw Address Matching Pattern (Updated to include 'O')
$script:NesCodePattern = '([AEGIKLN-PS-VX-Z]{6,8}|[0-9A-F]{4}:[0-9A-F]{2}(?::[0-9A-F]{2})?)'

# --- CORE HANDLER DEFINITIONS ---
$script:TextChangeHandler = {
    $script:IsDirty = $true
}

# --- NATIVE EMULATED UGGCONV NES LOGIC CORRELATION ---

function Convert-UnmapNesChar ([char]$c) {
    switch ([char]::ToUpper($c)) {
        'A' { return 0 } 'P' { return 1 } 'Z' { return 2 } 'L' { return 3 }
        'G' { return 4 } 'I' { return 5 } 'T' { return 6 } 'Y' { return 7 }
        'E' { return 8 } 'O' { return 9 } 'X' { return 10 } 'U' { return 11 }
        'K' { return 12 } 'S' { return 13 } 'V' { return 14 } 'N' { return 15 }
        default { return 0 }
    }
}

function Convert-MapNesChar ([int]$v) {
    switch ($v) {
        0 { return 'A' } 1 { return 'P' } 2 { return 'Z' } 3 { return 'L' }
        4 { return 'G' } 5 { return 'I' } 6 { return 'T' } 7 { return 'Y' }
        8 { return 'E' } 9 { return 'O' } 10 { return 'X' } 11 { return 'U' }
        12 { return 'K' } 13 { return 'S' } 14 { return 'V' } 15 { return 'N' }
        default { return '?' }
    }
}

function Invoke-GameGenieDecodeNES ([string]$gg) {
    $gg = $gg.Trim().ToUpper()
    if ($gg.Length -ne 6 -and $gg.Length -ne 8) { return $null }
    
    $data = New-Object int[] 8
    for ($i = 0; $i -lt $gg.Length; $i++) {
        $data[$i] = Convert-UnmapNesChar $gg[$i]
    }
    
    $address = 0x8000
    $address = $address -bor (($data[1] -band 8) -shl 4)
    $address = $address -bor (($data[2] -band 7) -shl 4)
    $address = $address -bor (($data[3] -band 7) -shl 12)
    $address = $address -bor (($data[3] -band 8) -shl 0)
    $address = $address -bor (($data[4] -band 7) -shl 0)
    $address = $address -bor (($data[4] -band 8) -shl 8)
    $address = $address -bor (($data[5] -band 7) -shl 8)
    
    $value = 0
    $check = 0
    $haveCheck = ($gg.Length -eq 8)
    
    if ($haveCheck) {
        $value = $value -bor (($data[0] -band 7) -shl 0)
        $value = $value -bor (($data[0] -band 8) -shl 4)
        $value = $value -bor (($data[1] -band 7) -shl 4)
        $value = $value -bor (($data[7] -band 8) -shl 0)
        
        $check = $check -bor (($data[5] -band 8) -shl 0)
        $check = $check -bor (($data[6] -band 7) -shl 0)
        $check = $check -bor (($data[6] -band 8) -shl 4)
        $check = $check -bor (($data[7] -band 7) -shl 4)
        
        return [string]::Format("{0:X4}:{1:X2}:{2:X2}", $address, $value, $check)
    } else {
        $value = $value -bor (($data[0] -band 7) -shl 0)
        $value = $value -bor (($data[0] -band 8) -shl 4)
        $value = $value -bor (($data[1] -band 7) -shl 4)
        $value = $value -bor (($data[5] -band 8) -shl 0)
        
        return [string]::Format("{0:X4}:{1:X2}", $address, $value)
    }
}

function Invoke-GameGenieEncodeNES ([string]$raw) {
    $parts = $raw.Split(':')
    if ($parts.Length -lt 2) { return $null }
    
    $address = [Convert]::ToInt32($parts[0], 16)
    $value = [Convert]::ToInt32($parts[1], 16)
    $check = 0
    $haveCheck = $false
    if ($parts.Length -eq 3) {
        $check = [Convert]::ToInt32($parts[2], 16)
        $haveCheck = $true
    }
    
    $data = New-Object int[] 8
    
    $data[1] = $data[1] -bor (($address -shr 4) -band 8)
    $data[2] = $data[2] -bor (($address -shr 4) -band 7)
    $data[3] = $data[3] -bor (($address -shr 12) -band 7)
    $data[3] = $data[3] -bor (($address -shr 0) -band 8)
    $data[4] = $data[4] -bor (($address -shr 0) -band 7)
    $data[4] = $data[4] -bor (($address -shr 8) -band 8)
    $data[5] = $data[5] -bor (($address -shr 8) -band 7)
    
    if ($haveCheck) {
        $data[0] = $data[0] -bor (($value -shr 0) -band 7)
        $data[0] = $data[0] -bor (($value -shr 4) -band 8)
        $data[1] = $data[1] -bor (($value -shr 4) -band 7)
        $data[2] = $data[2] -bor 8
        $data[7] = $data[7] -bor (($value -shr 0) -band 8)
        
        $data[5] = $data[5] -bor (($check -shr 0) -band 8)
        $data[6] = $data[6] -bor (($check -shr 0) -band 7)
        $data[6] = $data[6] -bor (($check -shr 4) -band 8)
        $data[7] = $data[7] -bor (($check -shr 4) -band 7)
    } else {
        $data[0] = $data[0] -bor (($value -shr 0) -band 7)
        $data[0] = $data[0] -bor (($value -shr 4) -band 8)
        $data[1] = $data[1] -bor (($value -shr 4) -band 7)
        $data[5] = $data[5] -bor (($value -shr 0) -band 8)
    }
    
    $sb = New-Object System.Text.StringBuilder
    $len = if ($haveCheck) { 8 } else { 6 }
    for ($i = 0; $i -lt $len; $i++) {
        [void]$sb.Append((Convert-MapNesChar $data[$i]))
    }
    return $sb.ToString()
}

# --- HELPER FUNCTIONS ---

# Naming collision resolution engine
function Get-SafeCodeDescription ([string]$baseDesc, [string]$codeSignature) {
    if (-not $script:CheatDatabase.Contains($baseDesc)) {
        return $baseDesc
    }
    $suffix = if ($codeSignature -match '^[A-Z0-9]{6,8}$') { "[GG]" } else { "[RAW]" }
    $candidate = "$baseDesc $suffix"
    if (-not $script:CheatDatabase.Contains($candidate)) {
        return $candidate
    }
    $counter = 1
    while ($script:CheatDatabase.Contains("$baseDesc $suffix ($counter)")) {
        $counter++
    }
    return "$baseDesc $suffix ($counter)"
}

# Centralized normalization engine adapted from the PlayStation parsing code
function Parse-AndNormalizeLine ([string]$inputLine) {
    if ([string]::IsNullOrWhiteSpace($inputLine)) { return $null }
    $sanitized = $inputLine.Trim().Trim('"').ToUpper()
    $tokens = $sanitized.Split('+', [System.StringSplitOptions]::RemoveEmptyEntries)
    $results = New-Object System.Collections.Generic.List[string]
    $ggPattern  = '^[AEGIKLN-PS-VX-ZO]{6,8}$'
    $rawPattern = '^[0-9A-F]{4}:[0-9A-F]{2}(?::[0-9A-F]{2})?$'

    foreach ($token in $tokens) {
        $token = $token.Trim()
        if ($token -match $ggPattern -or $token -match $rawPattern) {
            [void]$results.Add($token)
        }
    }

    if ($results.Count -gt 0) { return $results } else { return $null }
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
                $cleanCodes = Parse-AndNormalizeLine $line
                if ($null -ne $cleanCodes) { $updatedCodes.AddRange([string[]]$cleanCodes) }
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

$lblEditor = New-Object System.Windows.Forms.Label
$lblEditor.Text = "Codes in Selected Group (One per line, GG or AAAA:VV[:CC]):"
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

$btnExportNes = New-Object System.Windows.Forms.Button
$btnExportNes.Text = "Export to nes.emu .cht"
$btnExportNes.Location = New-Object System.Drawing.Point(20, 485)
$btnExportNes.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportNes)

$btnExportRa = New-Object System.Windows.Forms.Button
$btnExportRa.Text = "Export to RetroArch .cht"
$btnExportRa.Location = New-Object System.Drawing.Point(155, 485)
$btnExportRa.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportRa)

# --- PARSING ENGINES (With Stateful Lookbehind & Category Support) ---

function Import-RetroArchCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    
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
    $hasOrphans = $false
    foreach ($k in $descMap.Keys) {
        if (-not $codeMap.Contains($k)) { $hasOrphans = $true; break }
    }

    $mergeCategories = $false
    if ($hasOrphans) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Cheat descriptions found without matching codes.`n`nTreat empty labels as parent categories and group subsequent blocks?", 
            "Category Layout Detected", "YesNo", "Question"
        )
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

function Import-NesEmuCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    
    # Pass 1: Parse lines into structured intermediate objects
    $parsedEntries = New-Object System.Collections.Generic.List[psobject]
    $hasOrphans = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^(?:SC|C|S)?:?([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?:(.*)$') {
            $addr = $Matches[1].ToUpper()
            $val  = $Matches[2].ToUpper()
            $cmp  = if ($Matches[3]) { $Matches[3].ToUpper() } else { "" }
            $desc = $Matches[4].Replace("'", "").Trim()
            
            if ([string]::IsNullOrWhiteSpace($desc)) { 
                $desc = "Unassigned Code Block" 
            }
            
            $codeStr = "${addr}:${val}"
            if (-not [string]::IsNullOrEmpty($cmp)) { $codeStr += ":${cmp}" }
            
            $cleanCodes = Parse-AndNormalizeLine $codeStr
            
            $parsedEntries.Add([PSCustomObject]@{
                Description = $desc
                Codes       = $cleanCodes
            })
        }
    }

    # Detect structural orphans (entries with empty descriptions or standalone headers)
    foreach ($entry in $parsedEntries) {
        if ($null -eq $entry.Codes -or $entry.Codes.Count -eq 0) {
            $hasOrphans = $true
            break
        }
    }

    # Prompt user for parent category merging if structural empty headers exist
    $mergeCategories = $false
    if ($hasOrphans) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Cheat descriptions found without matching codes.`n`nTreat empty labels as parent categories and group subsequent blocks?", 
            "Category Layout Detected", "YesNo", "Question"
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { $mergeCategories = $true }
    }

    # Pass 2: Populate script database using safe title resolution
    $categoryHeader = "Unassigned Code Block"

    foreach ($entry in $parsedEntries) {
        $descText = $entry.Description
        $cleanCodes = $entry.Codes

        # Handle parent category assignment if code block is empty
        if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) {
            if ($mergeCategories) { $categoryHeader = $descText }
            continue
        }

        $finalTitle = if ($mergeCategories -and $categoryHeader -ne "Unassigned Code Block") { 
            "$categoryHeader - $descText" 
        } else { 
            $descText 
        }

        if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

        # Check existing group vs. safe creation
        if ($script:CheatDatabase.Contains($finalTitle)) {
            if (-not $script:CheatDatabase[$finalTitle].Contains($cleanCodes[0])) {
                $script:CheatDatabase[$finalTitle].AddRange([string[]]$cleanCodes)
            }
        } else {
            $safeTitle = Get-SafeCodeDescription $finalTitle $cleanCodes[0]
            if (-not $script:CheatDatabase.Contains($safeTitle)) {
                $script:CheatDatabase[$safeTitle] = New-Object System.Collections.Generic.List[string]
            }
            $script:CheatDatabase[$safeTitle].AddRange([string[]]$cleanCodes)
        }
    }
}

# --- INTERACTIVE EVENT TRIGGERS ---

$btnLoad.Add_Click({
    if (-not (Save-CurrentSelectionIfDirty)) { return }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "NES Cheat Files (*.cht;*.txt)|*.cht;*.txt"
    
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:CheatDatabase.Clear()
            
            $sniffLines = ""
            if (Test-Path $ofd.FileName) {
                $sniffLines = [System.IO.File]::ReadLines($ofd.FileName) | 
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | 
                    Select-Object -First 5
                $sniffLines = [string]::Join(" ", $sniffLines).Trim()
            }

            if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
                Import-RetroArchCht $ofd.FileName
            }
            else {
                Import-NesEmuCht $ofd.FileName
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
        $cleanCodes = Parse-AndNormalizeLine $line
        if ($null -ne $cleanCodes) { $updatedCodes.AddRange([string[]]$cleanCodes) }
    }
    $script:CheatDatabase[$selectedDesc] = $updatedCodes
    $script:IsDirty = $false
    [System.Windows.Forms.MessageBox]::Show("Group data cache updated.", "Saved", "OK", "Information")
})

$btnNewGroup.Add_Click({
    $newTitle = $txtNewGroup.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($newTitle)) { return }

    if ($script:CheatDatabase.Contains($newTitle)) {
        [System.Windows.Forms.MessageBox]::Show("A cheat group name already exists.", "Duplicate Found", "OK", "Warning")
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

$btnExportNes.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are currently empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "nes.emu Cheat Files (*.cht)|*.cht"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $sb = New-Object System.Text.StringBuilder
            
            foreach ($desc in $script:CheatDatabase.Keys) {
                foreach ($codeItem in $script:CheatDatabase[$desc]) {
                    $rawCode = $codeItem
                    if ($rawCode -match '^[A-Z0-9]{6,8}$') {
                        $rawCode = Invoke-GameGenieDecodeNES $rawCode
                    }
                    if ($null -eq $rawCode) { continue }
                    
                    $parts = $rawCode.Split(':')
                    $addressInt = [Convert]::ToInt32($parts[0], 16)
                    $isHighAddress = $addressInt -ge 0x8000
                    $isThreePart = ($parts.Length -eq 3)
                    
                    $prefix = ""
                    if ($isHighAddress) {
                        $prefix = if ($isThreePart) { "SC" } else { "S" }
                    } else {
                        $prefix = if ($isThreePart) { "C" } else { "" }
                    }
                    
                    [void]$sb.AppendLine("${prefix}:${rawCode}:${desc}")
                }
            }
            
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show("Successfully generated nes.emu plain text structures!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Serialization error encountered: `n$_", "Error", "OK", "Error")
        }
    }
})

$btnExportRa.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) { return }
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "RetroArch Cheat Files (*.cht)|*.cht"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $sb = New-Object System.Text.StringBuilder
            
            [void]$sb.AppendLine("cheats = $($script:CheatDatabase.Count)")
            [void]$sb.AppendLine("")
            
            $idx = 0
            foreach ($desc in $script:CheatDatabase.Keys) {
                $convertedCodes = New-Object System.Collections.Generic.List[string]
                foreach ($codeItem in $script:CheatDatabase[$desc]) {
                    if ($codeItem -match '^[A-Z0-9]{6,8}$') {
                        $convertedCodes.Add($codeItem)
                    } else {
                        $parts = $codeItem.Split(':')
                        $addressInt = [Convert]::ToInt32($parts[0], 16)
                        if ($addressInt -lt 0x8000) {
                            $convertedCodes.Add($codeItem)
                        } else {
                            $gg = Invoke-GameGenieEncodeNES $codeItem
                            if ($null -ne $gg) { $convertedCodes.Add($gg) } else { $convertedCodes.Add($codeItem) }
                        }
                    }
                }
                $joinedCodes = [string]::Join("+", $convertedCodes)
                
                [void]$sb.AppendLine("cheat${idx}_desc = `"$desc`"")
                [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
                [void]$sb.AppendLine("cheat${idx}_enable = false")
                [void]$sb.AppendLine("")
                $idx++
            }
            
            [System.IO.File]::WriteAllText($sfd.FileName, $sb.ToString(), [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show("Successfully generated RetroArch text-collapsed format file!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Text write error encountered: `n$_", "Error", "OK", "Error")
        }
    }
})

# Launch GUI Window Thread Context
$form.ShowDialog()
