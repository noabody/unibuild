Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Main Form Window ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Universal Saturn Cheat Manager (RetroArch <-> Kronos)"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"

# Memory tracking for loaded cheats: Keys = Descriptions, Values = List of Code Strings ("XXXXXXXX YYYY")
$script:CheatDatabase = [ordered]@{ }
$script:IsDirty = $false
$script:LastSelectedIndex = -1

# --- CORE HANDLER DEFINITIONS ---
$script:TextChangeHandler = {
    $script:IsDirty = $true
}

# --- HELPER FUNCTIONS ---

function Parse-AndNormalizeLine ([string]$inputLine) {
    if ([string]::IsNullOrWhiteSpace($inputLine)) { return $null }

    # Replace 'O'/'o' with '0' to fix visual OCR typos
    $sanitizedLine = $inputLine.Replace("O", "0").Replace("o", "0")
    
    $cleanLines = [regex]::Matches($sanitizedLine, '([Dd130-9A-Fa-f][0-9A-Fa-f]{7})[^0-9A-Fa-f]*([0-9A-Fa-f]{4})')
    if ($cleanLines.Count -eq 0) { return $null }

    $normalizedSegments = New-Object System.Collections.Generic.List[string]
    foreach ($m in $cleanLines) {
        $normalizedSegments.Add("$($m.Groups[1].Value.ToUpper()) $($m.Groups[2].Value.ToUpper())")
    }
    return $normalizedSegments.ToArray()
}

function Get-SafeCodeDescription ([string]$baseDesc, [string]$incomingCode) {
    if (-not $script:CheatDatabase.Contains($baseDesc)) {
        return $baseDesc
    }
    $counter = 1
    while ($script:CheatDatabase.Contains("$baseDesc ($counter)")) {
        $counter++
    }
    return "$baseDesc ($counter)"
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
$btnLoad.Text = "Load File (.cht / .yct)"
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

$btnExportYct = New-Object System.Windows.Forms.Button
$btnExportYct.Text = "Export to Kronos .yct"
$btnExportYct.Location = New-Object System.Drawing.Point(20, 485)
$btnExportYct.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportYct)

$btnExportRa = New-Object System.Windows.Forms.Button
$btnExportRa.Text = "Export to RetroArch .cht"
$btnExportRa.Location = New-Object System.Drawing.Point(155, 485)
$btnExportRa.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnExportRa)

# --- PARSING ENGINES ---

function Import-RetroArchCht ([string]$filePath) {
    $lines = [System.IO.File]::ReadAllLines($filePath)
    
    $descMap = [ordered]@{ }
    $codeMap = [ordered]@{ }
    $categoryHeader = "Unassigned Code Block"
    
    # Pass 1: Map raw indexes
    foreach ($line in $lines) {
        if ($line -match '^cheat(\d+)_desc\s*=\s*"(.*)"') {
            $descMap[$Matches[1]] = $Matches[2].Trim()
        }
        elseif ($line -match '^cheat(\d+)_code\s*=\s*"(.*)"') {
            $codeMap[$Matches[1]] = $Matches[2].Trim()
        }
    }

    # Pass 1b: Orphan key detection
    $hasOrphans = $false
    foreach ($k in $descMap.Keys) {
        if (-not $codeMap.Contains($k)) { $hasOrphans = $true; break }
    }

    $mergeCategories = $false
    if ($hasOrphans) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Cheat descriptions found without matching codes.`n`nTreat empty labels as parent categories and group subsequent blocks?", "Category Layout Detected", "YesNo", "Question")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { $mergeCategories = $true }
    }

    # Pass 2: Extract, normalize, and commit
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

function Import-KronosYct ([string]$filePath) {
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 8) { return }

    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -ne "YCHT") { return }

    $totalRecords = [int]$bytes[7]
    $offset = 8

    # --- PASS 1: Extract Raw Binary Structures to Intermediate List ---
    $intermediateList = New-Object System.Collections.Generic.List[PSCustomObject]

    for ($i = 0; $i -lt $totalRecords; $i++) {
        if ($offset + 12 -gt $bytes.Length) { break }

        $typeByte = $bytes[$offset + 3]
        $prefix = "D"
        if ($typeByte -eq 0x02) { $prefix = "3" }
        elseif ($typeByte -eq 0x03) { $prefix = "1" }

        $addr1 = "{0:X1}" -f ($bytes[$offset + 4] -band 0x0F)
        $addr2 = "{0:X2}" -f $bytes[$offset + 5]
        $addr3 = "{0:X2}" -f $bytes[$offset + 6]
        $addr4 = "{0:X2}" -f $bytes[$offset + 7]
        $fullAddr = $prefix + $addr1 + $addr2 + $addr3 + $addr4

        $val1 = "{0:X2}" -f $bytes[$offset + 10]
        $val2 = "{0:X2}" -f $bytes[$offset + 11]
        $rawCodeString = "$fullAddr $val1$val2"

        $nameLengthByte = $bytes[$offset + 12]
        $nameLength = [int]$nameLengthByte - 1
        if ($nameLength -lt 1) { $nameLength = 1 }

        $descOffset = $offset + 13
        if ($descOffset + $nameLength -gt $bytes.Length) { break }

        $rawDesc = [System.Text.Encoding]::ASCII.GetString($bytes, $descOffset, $nameLength).Split("`0")[0]

        $intermediateList.Add([PSCustomObject]@{
            RawDesc = $rawDesc
            RawCode = $rawCodeString
        })

        $offset += 12 + 1 + $nameLength + 5
    }

    # --- PASS 2: Normalization, Title Cleaning & Group Aggregation ---
    foreach ($item in $intermediateList) {
        # 1. Normalize code formatting (e.g. UPPERCASE, validate hex pairs)
        $cleanCodes = Parse-AndNormalizeLine $item.RawCode
        if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }

        # 2. Clean title text identical to RetroArch importer
        $finalTitle = $item.RawDesc.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

        # 3. Merge identical titles so multi-line codes stay grouped in one block
        if (-not $script:CheatDatabase.Contains($finalTitle)) {
            $script:CheatDatabase[$finalTitle] = New-Object System.Collections.Generic.List[string]
        }
        $script:CheatDatabase[$finalTitle].AddRange([string[]]$cleanCodes)
    }
}

# --- INTERACTIVE EVENT TRIGGERS ---

$btnLoad.Add_Click({
    if ($script:IsDirty) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes and load a new file?", "Unsaved Changes", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }
    }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Saturn Cheat Files (*.cht;*.yct)|*.cht;*.yct"
    
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:CheatDatabase.Clear()
            
            $sniffLines = ""
            if (Test-Path $ofd.FileName) {
                $sniffLines = [System.IO.File]::ReadLines($ofd.FileName) | Select-Object -First 3
                $sniffLines = [string]::Join(" ", $sniffLines).Trim()
            }

            if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
                Import-RetroArchCht $ofd.FileName
            }
            else {
                Import-KronosYct $ofd.FileName
            }
            Refresh-CheatList
            $txtNewGroup.Clear()
            [System.Windows.Forms.MessageBox]::Show("Successfully parsed and grouped Saturn items by description name!", "Import Finished", "OK", "Information")
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

$btnExportYct.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Database tracking fields are currently empty.", "Error", "OK", "Warning")
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "Kronos Cheat Files (*.yct)|*.yct"
    
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $stream = $null
        $writer = $null
        try {
            if (Test-Path $sfd.FileName) { Remove-Item $sfd.FileName -Force }

            $stream = [System.IO.File]::Create($sfd.FileName)
            $writer = New-Object System.IO.BinaryWriter($stream)

            $writer.Write([byte]0x59); $writer.Write([byte]0x43); $writer.Write([byte]0x48); $writer.Write([byte]0x54)
            $writer.Write([byte]0x00); $writer.Write([byte]0x00); $writer.Write([byte]0x00)

            $totalFlattenedCheats = 0
            foreach ($key in $script:CheatDatabase.Keys) {
                foreach ($codeItem in $script:CheatDatabase[$key]) {
                    if ($codeItem -match '^[Dd13][0-9A-Fa-f]{7}') { $totalFlattenedCheats++ }
                }
            }
            $writer.Write([byte]$totalFlattenedCheats)

            foreach ($desc in $script:CheatDatabase.Keys) {
                $cnam = [System.Text.RegularExpressions.Regex]::Replace($desc, '[^\x20-\x7E]', '')
                if ($cnam.Length -gt 255) { $cnam = $cnam.Substring(0, 255) }
                
                $chdgCount = [byte]($cnam.Length + 1)
                $cnamBytes = [System.Text.Encoding]::ASCII.GetBytes($cnam)
            
                foreach ($codeItem in $script:CheatDatabase[$desc]) {
                    $parts = $codeItem -split '\s+'
                    if ($parts.Count -lt 2) { continue }
                    $part1 = $parts[0].ToUpper().PadRight(8, '0').Substring(0,8)
                    $part2 = $parts[1].ToUpper().PadRight(4, '0').Substring(0,4)
                    $ctyp = $part1.Substring(0, 1)
                    if ("D","1","3" -notcontains $ctyp) { continue }
                    $typeStr = "01"
                    if ($ctyp -eq "3") { $typeStr = "02" }
                    elseif ($ctyp -eq "1") { $typeStr = "03" }
            
                    $hexString = "000000" + $typeStr + "0" + $part1.Substring(1, 7) + "0000" + $part2
                    for ($bIdx = 0; $bIdx -lt 24; $bIdx += 2) {
                        $writer.Write([System.Convert]::ToByte($hexString.Substring($bIdx, 2), 16))
                    }
                    $writer.Write([byte]$chdgCount)
                    $writer.Write($cnamBytes, 0, $cnamBytes.Length)
                    $writer.Write([byte]0x00); $writer.Write([byte]0x00); $writer.Write([byte]0x00)
                    $writer.Write([byte]0x00); $writer.Write([byte]0x00)
                }
            }
            [System.Windows.Forms.MessageBox]::Show("Successfully generated compliant Kronos binary structures!", "Export Complete", "OK", "Information")
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
            [System.Windows.Forms.MessageBox]::Show("Successfully generated RetroArch text format configuration file!", "Export Complete", "OK", "Information")
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Text write error encountered: `n$_", "Error", "OK", "Error")
        }
    }
})

$form.ShowDialog()
