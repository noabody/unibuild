Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================================================================
# GLOBAL DATA & STATE (Refactored for Multi-Format Architecture)
# ==============================================================================
$script:CheatDatabase = [ordered]@{ }  # Key: String ("Name:::Format"), Value: PSCustomObject @{ BaseDesc, Format, Codes, Health }
$script:IsDirty = $false
$script:LastSelectedIndex = -1
$script:SuppressEvents = $false
$script:LastDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)

# Code Health Threshold Configuration
$script:HealthThreshold = 0.80

# Enforce UTF8 globally for standard I/O operations under Wine
$script:Utf8Encoding = New-Object System.Text.UTF8Encoding($false)

# Registries to hold input/output parser & writer functions
$script:InputModules  = [ordered]@{ }
$script:OutputModules = [ordered]@{ }

# Centralized profile-to-system key map to eliminate duplicate switch statements
$script:SystemKeyMap = @{
    "Nintendo NES"                   = "NES"
    "Super Nintendo / SNES"          = "SNES"
    "Game Boy / GBC"                 = "GBC"
    "Game Boy Advance / GBA"         = "GBA"
    "Nintendo DS"                    = "NDS"
    "Sega Master System / SMS"       = "SMS"
    "Sega Mega Drive / MD"           = "MD"
    "Sega Saturn"                    = "Saturn"
    "Sony PlayStation / PSX (PCSXR)" = "PCSXR"
    "Sony PlayStation / PSX (ePSXe)" = "ePSXe"
}

# ==============================================================================
# 1. CENTRALIZED COMPILED REGEX MASTER LIBRARY
# ==============================================================================
$script:RegexPatterns = [ordered]@{
    "rx333gg"   = [regex]::new('((?<![0-9A-F])[0-9A-F]{3}([\p{P}\p{S}\p{Z}][0-9A-F]{3}){2}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx422hex"  = [regex]::new('((?<![0-9A-F])[0-9A-F]{4}([\p{P}\p{S}\p{Z}][0-9A-F]{2}){1,2}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx44hex"   = [regex]::new('((?<![0-9A-F])[0-9A-F]{4}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx62hex"   = [regex]::new('((?<![0-9A-F])[0-9A-F]{6}[\p{P}\p{S}\p{Z}][0-9A-F]{2}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx8hex"    = [regex]::new('((?<![0-9A-F])[0-9A-F]{8}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx84hex"   = [regex]::new('((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx848hex"  = [regex]::new('((?<![0-9A-F])[0-9A-F]{8})[\p{P}\p{S}\p{Z}]([0-9A-F]{4,8}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx88hex"   = [regex]::new('((?<![0-9A-F])[0-9A-F]{8}[\p{P}\p{S}\p{Z}][0-9A-F]{8}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx64hex"   = [regex]::new('((?<![0-9A-F])[0-9A-F]{6}[\p{P}\p{S}\p{Z}][0-9A-F]{4}(?![0-9A-F]))', 'Compiled,IgnoreCase')
    "rx44gg"    = [regex]::new('((?<![0-9A-Z])[0-9A-Z]{4}[\p{P}\p{S}\p{Z}][0-9A-Z]{4}(?![0-9A-Z]))', 'Compiled,IgnoreCase')
    "rx68gg"    = [regex]::new('(?<![0-9A-Z])([AEGIKLN-PS-VX-Z]{6}|[AEGIKLN-PS-VX-Z]{8})(?![0-9A-Z])', 'Compiled,IgnoreCase')
}

# ==============================================================================
# 2. PER-SYSTEM PATTERN MAPPINGS (Using the Master Library)
# ==============================================================================
$script:SystemCodePatterns = @{
    "NES"    = [ordered]@{ "68gg"   = $script:RegexPatterns["rx68gg"];   "422hex" = $script:RegexPatterns["rx422hex"] }
    "SNES"   = [ordered]@{ "62hex"  = $script:RegexPatterns["rx62hex"];  "44hex"  = $script:RegexPatterns["rx44hex"]; "8hex" = $script:RegexPatterns["rx8hex"] }
    "GBC"    = @{ "8hex"   = $script:RegexPatterns["rx8hex"];   "333gg"  = $script:RegexPatterns["rx333gg"] }
    "GBA"    = @{ "84hex"  = $script:RegexPatterns["rx84hex"] }
    "NDS"    = @{ "88hex"  = $script:RegexPatterns["rx88hex"] }
    "SMS"    = @{ "333gg"  = $script:RegexPatterns["rx333gg"] }
    "MD"     = [ordered]@{ "64hex"  = $script:RegexPatterns["rx64hex"];  "44hex"  = $script:RegexPatterns["rx44hex"] }
    "Saturn" = @{ "84hex"  = $script:RegexPatterns["rx84hex"] }
    "ePSXe"  = @{ "848hex"    = $script:RegexPatterns["rx848hex"] }
    "PCSXR"  = @{ "848hex"    = $script:RegexPatterns["rx848hex"] }
}

# Mapping table connecting Input/Target modules to their explicit system Output modules
$script:ModuleOutputMap = @{
    "Game Boy / GBC"                 = "GBC.emu (.gbcht)"
    "Game Boy Advance / GBA"         = "VBA-M (.clt)"
    "Super Nintendo / SNES"          = "Snes9x (.cht)"
    "Nintendo DS"                    = "melonDS (.mch)"
    "Nintendo NES"                   = "nes.emu (.cht)"
    "Sega Master System / SMS"       = "md.emu SMS (.pat)"
    "Sega Mega Drive / MD"           = "md.emu MD (.pat)"
    "Sega Saturn"                    = "Kronos (.yct)"
    "Sony PlayStation / PSX (PCSXR)" = "PCSXR (.cht)"
    "Sony PlayStation / PSX (ePSXe)" = "ePSXe (.txt)"
}

# Local event handler definition with event suppression logic
$script:TextChangeHandler = {
    if ($script:SuppressEvents) { return }
    $script:IsDirty = $true
}

# Standalone helper functions for event handling on ListBox
function Disable-ListEvents {
    if ($null -ne $script:lstCheats) {
        $script:lstCheats.Remove_SelectedIndexChanged($script:ListSelectionHandler)
    }
}

function Enable-ListEvents {
    if ($null -ne $script:lstCheats) {
        $script:lstCheats.Add_SelectedIndexChanged($script:ListSelectionHandler)
    }
}

# ==============================================================================
# UNIVERSAL SYSTEM PARSER & STRUCTURAL ENGINES (Updated for multi-format output)
# ==============================================================================

function Invoke-SystemParser {
    param(
        [string]$SystemName,
        [string]$RawLine
    )
    
    $activePatterns = $script:SystemCodePatterns[$SystemName]
    if ($null -eq $activePatterns) { return $null }

    foreach ($patternKey in $activePatterns.Keys) {
        $match = $activePatterns[$patternKey].Match($RawLine)
        if ($match.Success) {
            return [PSCustomObject]@{
                Code        = $match.Value.ToUpper().Trim()
                Format      = $patternKey
                MatchLength = $match.Value.Length
            }
        }
    }
    return $null
}

function Import-Generic1to1Engine {
    param(
        [string]$FilePath,
        [string]$SystemName,
        [string]$Delimiter = "`t"
    )
    if (-not (Test-Path $FilePath)) { return }
    $lines = [System.IO.File]::ReadAllLines($FilePath, $script:Utf8Encoding)
    
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

        $parts = $trimmed -split $Delimiter, 2
        $rawCode = if ($parts.Count -gt 1) { $parts[0].Trim() } else { $trimmed }
        $rawDesc = if ($parts.Count -gt 1) { $parts[1].Replace("'", "").Trim() } else { "Unassigned Code Block" }

        $parseResult = Invoke-SystemParser -SystemName $SystemName -RawLine $rawCode
        
        # Initialize default values for a failed match
        $codeArray = [string[]]@()
        $matchLength = 0

        if ($null -ne $parseResult) {
            $codeArray = @($parseResult.Code)
            $matchLength = $parseResult.MatchLength
        }

        # ALWAYS pass the footprint downstream, even if $codeArray is empty and $matchLength is 0
        Add-CheatToDatabase -Description $rawDesc -Codes $codeArray -SystemName $SystemName -RawLength $rawCode.Length -MatchLength $matchLength
    }
}

function Import-Generic1fewEngine {
    param(
        [string]$FilePath,
        [string]$SystemName,
        [string]$HeaderPattern
    )
    if (-not (Test-Path $FilePath)) { return }
    $lines = [System.IO.File]::ReadAllLines($FilePath, $script:Utf8Encoding)
    
    $currentHeader = "Unassigned Code Block"
    $currentCodes = [System.Collections.Generic.List[string]]::new()
    
    $totalRawLength = 0
    $totalMatchLength = 0

    $commitBlock = {
        param($desc, $codeList, $rawLen, $matchLen)
        if ($codeList.Count -gt 0) {
            Add-CheatToDatabase -Description $desc -Codes $codeList.ToArray() -SystemName $SystemName -RawLength $rawLen -MatchLength $matchLen
            $codeList.Clear()
        }
    }

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match $HeaderPattern) {
            & $commitBlock $currentHeader $currentCodes $totalRawLength $totalMatchLength
            $currentHeader = $Matches[1].Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($currentHeader)) { $currentHeader = "Unassigned Code Block" }
            $totalRawLength = 0
            $totalMatchLength = 0
        } else {
            # ALWAYS log the raw footprint of lines found in the code block
            $totalRawLength += $trimmed.Length

            $parseResult = Invoke-SystemParser -SystemName $SystemName -RawLine $trimmed
            if ($null -ne $parseResult) {
                $currentCodes.Add($parseResult.Code)
                $totalMatchLength += $parseResult.MatchLength
            }
        }
    }
    & $commitBlock $currentHeader $currentCodes $totalRawLength $totalMatchLength
}

# ==============================================================================
# DEFERRED KEY STRATEGY & ARCHITECTURAL DATABASE MUTATORS
# ==============================================================================

function Add-CheatToDatabase {
    param (
        [string]$Description,
        [string[]]$Codes,
        [string]$SystemName = $null,
        [string]$FormatOverride = $null,
        [int]$RawLength = 0,
        [int]$MatchLength = 0
    )
    
    # Compute Code Health Metric (Default to 1.0/100% for Layout C / Manual entries)
    $healthScore = 1.0
    if ($RawLength -gt 0) {
        $healthScore = $MatchLength / $RawLength
    }

    # Evaluate Health Score against the configured limit guard
    if ($healthScore -lt $script:HealthThreshold) {
        $percentage = [Math]::Round($healthScore * 100, 1)
        $thresholdPercent = [Math]::Round($script:HealthThreshold * 100, 1)
        Write-Log "Discarded entry group '$Description' due to health failure ($percentage% score falls below required $thresholdPercent% threshold)." "WARN"
        return
    }

    $groupedFormats = [ordered]@{ }

    foreach ($code in $Codes) {
        $formatKey = "Unknown"
        $cleanCode = $code.Trim().ToUpper()

        if (-not [string]::IsNullOrEmpty($FormatOverride)) {
            $formatKey = $FormatOverride
        } elseif (-not [string]::IsNullOrEmpty($SystemName)) {
            $parseResult = Invoke-SystemParser -SystemName $SystemName -RawLine $cleanCode
            if ($null -ne $parseResult) {
                $formatKey = $parseResult.Format
                $cleanCode = $parseResult.Code
            }
        }

        if (-not $groupedFormats.Contains($formatKey)) {
            $groupedFormats[$formatKey] = [System.Collections.Generic.List[string]]::new()
        }
        $groupedFormats[$formatKey].Add($cleanCode)
    }

    foreach ($fmt in $groupedFormats.Keys) {
        $compositeKey = "$Description:::$fmt"
        if (-not $script:CheatDatabase.Contains($compositeKey)) {
            $script:CheatDatabase[$compositeKey] = [PSCustomObject]@{
                BaseDesc = $Description
                Format   = $fmt
                Codes    = $groupedFormats[$fmt]
                Health   = $healthScore
            }
        } else {
            foreach ($c in $groupedFormats[$fmt]) {
                $script:CheatDatabase[$compositeKey].Codes.Add($c)
            }
            # Maintain the lowest health evaluation floor if updating existing nodes
            if ($healthScore -lt $script:CheatDatabase[$compositeKey].Health) {
                $script:CheatDatabase[$compositeKey].Health = $healthScore
            }
        }
    }
}

function Update-UIState {
    $hasItems = $script:lstCheats.Items.Count -gt 0
    $script:btnMoveUp.Enabled = $hasItems
    $script:btnMoveDown.Enabled = $hasItems
    $script:btnDeleteGroup.Enabled = $hasItems
    $script:btnSaveGroup.Enabled = $hasItems
}

function Refresh-CheatList {
    Disable-ListEvents
    $script:lstCheats.BeginUpdate()
    try {
        $script:lstCheats.Items.Clear()
        foreach ($key in $script:CheatDatabase.Keys) {
            # Render only the Name layer to the UI box, keeping format tags entirely hidden
            [void]$script:lstCheats.Items.Add($script:CheatDatabase[$key].BaseDesc)
        }
        $script:IsDirty = $false
        if ($script:lstCheats.Items.Count -gt 0) {
            $script:LastSelectedIndex = 0
            $script:lstCheats.SelectedIndex = 0
            
            $dbKeys = @($script:CheatDatabase.Keys)
            $selectedKey = $dbKeys[0]

            $script:SuppressEvents = $true
            $flattenedCodes = @($script:CheatDatabase[$selectedKey].Codes)
            $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $flattenedCodes)
            $script:IsDirty = $false
            $script:SuppressEvents = $false
        } else {
            $script:LastSelectedIndex = -1
            $script:SuppressEvents = $true
            $script:txtEditor.Clear()
            $script:SuppressEvents = $false
        }
        Update-UIState
    } finally {
        $script:lstCheats.EndUpdate()
        Enable-ListEvents
    }
}

function Write-Log ([string]$message, [string]$level = "INFO") {
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = "[$timestamp] [$level] $message"
    if ($null -eq $script:txtStatusLog) { return }

    $logAction = [Action]{ $script:txtStatusLog.AppendText($logEntry + [Environment]::NewLine) }
    if ($script:txtStatusLog.InvokeRequired -or -not $script:txtStatusLog.IsHandleCreated) {
        try { [void]$script:txtStatusLog.Invoke($logAction) } catch { $logAction.Invoke() }
    } else {
        $logAction.Invoke()
    }
}

function Save-CurrentSelectionIfDirty {
    if ($script:IsDirty -and $script:LastSelectedIndex -ge 0 -and $script:LastSelectedIndex -lt $script:lstCheats.Items.Count) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Save changes to the current group before proceeding?", "Unsaved Progress", "YesNoCancel", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            $dbKeys = @($script:CheatDatabase.Keys)
            $targetKey = $dbKeys[$script:LastSelectedIndex]
            
            # Wine Consistency Optimization: Split explicitly on normalized line break boundaries
            $lines = $script:txtEditor.Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $updatedCodes = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $lines) { $updatedCodes.Add($line.Trim().ToUpper()) }

            $script:CheatDatabase[$targetKey].Codes = $updatedCodes
        }
        $script:IsDirty = $false
    }
    return $true
}

# --- Shared Engines ---
function Import-RetroArchChtEngine ([string]$filePath, [scriptblock]$parseFunc) {
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
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
        $choice = [System.Windows.Forms.MessageBox]::Show("Cheat descriptions found without matching codes.`n`nTreat empty labels as parent categories and group subsequent blocks?", "Category Layout Detected", "YesNo", "Question")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { $mergeCategories = $true }
    }

    foreach ($k in $descMap.Keys) {
        $descText = $descMap[$k]
        if (-not $codeMap.Contains($k)) {
            if ($mergeCategories) { $categoryHeader = $descText }
            continue
        }

        # Dynamic Layout parsing capture strategy
        $parseResult = & $parseFunc $codeMap[$k]
        if ($null -eq $parseResult) { continue }

        $cleanCodes = $null
        $rawLen = 0
        $matchLen = 0

        if ($parseResult -is [System.Management.Automation.PSCustomObject]) {
            # Layout A: Uniform tracking parameters mapped directly from complex string lines
            $cleanCodes = $parseResult.Codes
            $rawLen = $parseResult.RawLength
            $matchLen = $parseResult.MatchLength
        } else {
            # Layout B/C Fallback: Straight pass-through fallback processing
            $cleanCodes = @($parseResult)
            $rawLen = 0
            $matchLen = 0
        }

        if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }

        $finalTitle = if ($mergeCategories) { "$categoryHeader - $descText" } else { $descText }
        $finalTitle = $finalTitle.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

        # Extract targeted system context profile using decentralized mapping table
        $selectedInput = $script:cmbInputModule.SelectedItem.ToString()
        $sysName = if ($selectedInput -eq "RetroArch (Global)") { $script:cmbTargetRegex.SelectedItem.ToString() } else { $selectedInput }
        $systemKey = $script:SystemKeyMap[$sysName]

        Add-CheatToDatabase -Description $finalTitle -Codes $cleanCodes -SystemName $systemKey -RawLength $rawLen -MatchLength $matchLen
    }
}

function Import-VbaCltEngine ([string]$filePath) {
    $stream = $null
    $reader = $null
    $tempFile = $null
    try {
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $stream = [System.IO.MemoryStream]::new($fileBytes)
        $reader = [System.IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 12) { return }

        $stream.Position = 8
        $totalRecords = $reader.ReadInt32()
        $remainingBytes = $stream.Length - 12
        $stride = 84 
        if ($totalRecords -gt 0) {
            $calculatedStride = $remainingBytes / $totalRecords
            if ($calculatedStride -eq 80) { $stride = 80 }
        }

        $preprocessedLines = [System.Collections.Generic.List[string]]::new()

        for ($i = 0; $i -lt $totalRecords; $i++) {
            $recordStart = 12 + ($i * $stride)
            if (($recordStart + $stride) -gt $stream.Length) { break }

            $codeOffset = if ($stride -eq 80) { $recordStart + 28 } else { $recordStart + 32 }
            $descOffset = if ($stride -eq 80) { $recordStart + 48 } else { $recordStart + 52 }

            $stream.Position = $codeOffset
            $rawCode = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(20)).Split("`0")[0].Trim()

            $stream.Position = $descOffset
            $rawDesc = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(32)).Split("`0")[0].Trim()

            if ([string]::IsNullOrWhiteSpace($rawDesc)) { $rawDesc = "Unassigned Code Block" }
            if (-not [string]::IsNullOrWhiteSpace($rawCode)) {
                $preprocessedLines.Add("$rawCode`t$rawDesc")
            }
        }

        if ($preprocessedLines.Count -gt 0) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllLines($tempFile, $preprocessedLines.ToArray(), $script:Utf8Encoding)
            Import-Generic1to1Engine -FilePath $tempFile -SystemName "GBA" -Delimiter "`t"
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $tempFile -and (Test-Path $tempFile)) { Remove-Item $tempFile -Force }
    }
}

function Import-MyBoyChtEngine ([string]$filePath, [scriptblock]$parseFunc) {
    $reader = $null
    $tempFile = $null
    try {
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.IgnoreComments = $true
        $settings.IgnoreWhitespace = $true
        
        $reader = [System.Xml.XmlReader]::Create($filePath, $settings)
        $xml = [xml]::new()
        $xml.Load($reader)

        if ($null -eq $xml.cheats -or $null -eq $xml.cheats.cheat) { return }
        $cbCheats = $xml.cheats.cheat | Where-Object { $null -ne $_ -and $_.type -eq 'cb' }

        $strippedLines = [System.Collections.Generic.List[string]]::new()

        foreach ($cheat in $cbCheats) {
            if ($null -eq $cheat.name) { continue }
            $cleanDesc = $cheat.name.Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($cleanDesc)) { $cleanDesc = "Unassigned Code Block" }

            [void]$strippedLines.Add("[NAME] $cleanDesc")

            # FIX: Explicitly cast child code elements to a solid array 
            # to prevent single-string flattening or character looping.
            $codeNodes = $cheat.SelectNodes(".//code")
            foreach ($cNode in $codeNodes) {
                $rawCodeLine = $cNode.InnerText
                if (-not [string]::IsNullOrWhiteSpace($rawCodeLine)) {
                    [void]$strippedLines.Add($rawCodeLine.Trim())
                }
            }
        }

        if ($strippedLines.Count -gt 0) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            # Explicitly enforce the UTF-8 config standard you set globally
            [System.IO.File]::WriteAllLines($tempFile, $strippedLines.ToArray(), $script:Utf8Encoding)
            
            Import-Generic1fewEngine -FilePath $tempFile -SystemName "GBA" -HeaderPattern '^\[NAME\]\s*(.*)'
        }
    } catch {
        throw "Failed parsing MyBoy XML target: $_"
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $tempFile -and (Test-Path $tempFile)) { Remove-Item $tempFile -Force }
    }
}

function Import-KronosYctEngine ([string]$filePath) {
    $stream = $null
    $reader = $null
    $tempFile = $null
    try {
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $stream = [System.IO.MemoryStream]::new($fileBytes)
        $reader = [System.IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 8) { return }

        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne "YCHT") { return }

        $stream.Position = 7
        $totalRecords = [int]$reader.ReadByte()
        $preprocessedLines = [System.Collections.Generic.List[string]]::new()

        for ($i = 0; $i -lt $totalRecords; $i++) {
            if ($stream.Position + 13 -gt $stream.Length) { break }

            $typeByte = $reader.ReadBytes(4)[3]
            $prefix = "D"
            if ($typeByte -eq 0x02) { $prefix = "3" }
            elseif ($typeByte -eq 0x03) { $prefix = "1" }

            $addrBytes = $reader.ReadBytes(4)
            $addr1 = "{0:X1}" -f ($addrBytes[0] -band 0x0F)
            $addr2 = "{0:X2}" -f $addrBytes[1]
            $addr3 = "{0:X2}" -f $addrBytes[2]
            $addr4 = "{0:X2}" -f $addrBytes[3]
            $fullAddr = $prefix + $addr1 + $addr2 + $addr3 + $addr4

            $reader.ReadBytes(2) | Out-Null
            $valBytes = $reader.ReadBytes(2)
            $val1 = "{0:X2}" -f $valBytes[0]
            $val2 = "{0:X2}" -f $valBytes[1]
            $rawCodeString = "$fullAddr $val1$val2"

            $nameLengthByte = $reader.ReadByte()
            $nameLength = [Math]::Max(1, [int]$nameLengthByte - 1)
            if ($stream.Position + $nameLength + 5 -gt $stream.Length) { break }

            $rawDesc = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes($nameLength)).Split("`0")[0].Trim()
            $reader.ReadBytes(5) | Out-Null

            if ([string]::IsNullOrWhiteSpace($rawDesc)) { $rawDesc = "Unassigned Code Block" }
            $preprocessedLines.Add("$rawCodeString`t$rawDesc")
        }

        if ($preprocessedLines.Count -gt 0) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllLines($tempFile, $preprocessedLines.ToArray(), $script:Utf8Encoding)
            Import-Generic1to1Engine -FilePath $tempFile -SystemName "Saturn" -Delimiter "`t"
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $tempFile -and (Test-Path $tempFile)) { Remove-Item $tempFile -Force }
    }
}

function Import-NesChtEngine {
    param (
        [string]$filePath,
        [scriptblock]$parseFunc
    )
    
    if (-not (Test-Path $filePath)) { return }
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }

        $activeLine = $trimmed.TrimStart(':')
        $parts = $activeLine -split ':'
        if ($parts.Count -lt 2) { continue }

        $addrIndex = 0
        $prefix = ""

        if ($parts[0] -in @('S', 'SC', 'C')) {
            $prefix = $parts[0]
            $addrIndex = 1
        }

        if (($parts.Count - $addrIndex) -lt 2) { continue }

        $addressHex = $parts[$addrIndex]
        $val1       = $parts[$addrIndex + 1]
        
        $compareValue = $null
        $description = ""
        
        if ($parts.Count -eq ($addrIndex + 4)) {
            $compareValue = $parts[$addrIndex + 2]
            $description = $parts[$addrIndex + 3]
        } elseif ($parts.Count -gt ($addrIndex + 4)) {
            $compareValue = $parts[$addrIndex + 2]
            $description = $parts[($addrIndex + 3)..($parts.Count - 1)] -join ':'
        } elseif ($parts.Count -eq ($addrIndex + 3)) {
            $description = $parts[$addrIndex + 2]
        } else {
            $description = "Unassigned Code Block"
        }

        $cleanDesc = $description.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($cleanDesc)) { $cleanDesc = "Unassigned Code Block" }

        $codeList = [System.Collections.Generic.List[string]]::new()
        
        $addressVal = 0
        if ($addressHex -match '^[0-9A-Fa-f]{4}$') {
            $addressVal = [Convert]::ToInt32($addressHex, 16)
        }

        if ($addressVal -ge 0x8000) {
            $rawSegment = "${addressHex}:${val1}"
            if ($null -ne $compareValue) { $rawSegment += ":${compareValue}" }
            
            $encodedGG = Invoke-GameGenieEncodeNES $rawSegment
            if (-not [string]::IsNullOrEmpty($encodedGG)) {
                $codeList.Add($encodedGG)
            }
        }

        if ($codeList.Count -eq 0) {
            $rawSegment = if ($prefix) { "${prefix}:${addressHex}:${val1}" } else { "${addressHex}:${val1}" }
            $parseResult = Invoke-SystemParser -SystemName "NES" -RawLine $rawSegment
            
            if ($null -ne $parseResult) {
                $codeList.Add($parseResult.Code)
            } else {
                $parsedFallback = & $parseFunc "$addressHex $val1"
                if (-not [string]::IsNullOrEmpty($parsedFallback)) {
                    $codeList.Add($parsedFallback)
                }
            }
        }

        if ($codeList.Count -gt 0) {
            # Layout C pass-through execution rules
            Add-CheatToDatabase -Description $cleanDesc -Codes $codeList.ToArray() -SystemName "NES" -RawLength 0 -MatchLength 0
        }
    }
}

# ==============================================================================
# INPUT & OUTPUT MODULE REGISTRATION ENGINE
# ==============================================================================

function Register-InputModule {
    param(
        [string]$Name,
        [string]$Filter,
        [scriptblock]$ParseFunc,
        [scriptblock]$ImportFunc
    )
    $script:InputModules[$Name] = @{
        Filter     = $Filter
        ParseFunc  = $ParseFunc
        ImportFunc = $ImportFunc
    }
}

function Register-OutputModule {
    param(
        [string]$Name,
        [string]$Filter,
        [scriptblock]$ExportFunc
    )
    $script:OutputModules[$Name] = @{
        Filter     = $Filter
        ExportFunc = $ExportFunc
    }
}

# ==============================================================================
# INPUT & OUTPUT MODULE DEFINITIONS
# ==============================================================================

# --- SEGA SATURN MODULES ---
Register-InputModule -Name "Sega Saturn" -Filter "Saturn Cheat Files (*.yct)|*.yct" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "Saturn" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $sniffLines = ""
    if (Test-Path $filePath) {
        $sniffLines = [System.IO.File]::ReadLines($filePath, $script:Utf8Encoding) | Select-Object -First 3
        $sniffLines = [string]::Join(" ", $sniffLines).Trim()
    }

    if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
        Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
    } else {
        Import-KronosYctEngine -filePath $filePath
    }
}

Register-OutputModule -Name "Kronos (.yct)" -Filter "Kronos Cheat Files (*.yct)|*.yct" -ExportFunc {
    param([string]$filePath)
    $stream = $null
    $writer = $null
    try {
        if (Test-Path $filePath) { Remove-Item $filePath -Force }
        $stream = [System.IO.File]::Create($filePath)
        $writer = [System.IO.BinaryWriter]::new($stream)

        $writer.Write([byte[]]@(0x59, 0x43, 0x48, 0x54, 0x00, 0x00, 0x00))

        $totalFlattenedCheats = 0
        foreach ($key in $script:CheatDatabase.Keys) {
            foreach ($codeItem in $script:CheatDatabase[$key].Codes) {
                if ($codeItem -match '^[Dd13][0-9A-Fa-f]{7}') { $totalFlattenedCheats++ }
            }
        }
        $writer.Write([byte]$totalFlattenedCheats)

        foreach ($compositeKey in $script:CheatDatabase.Keys) {
            $entry = $script:CheatDatabase[$compositeKey]
            $cnam = [regex]::Replace($entry.BaseDesc, '[^\x20-\x7E]', '')
            if ($cnam.Length -gt 255) { $cnam = $cnam.Substring(0, 255) }
            
            $chdgCount = [byte]($cnam.Length + 1)
            $cnamBytes = [System.Text.Encoding]::ASCII.GetBytes($cnam)

            foreach ($codeItem in $entry.Codes) {
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
                $chunk = New-Object byte[] 12
                for ($bIdx = 0; $bIdx -lt 12; $bIdx++) {
                    $chunk[$bIdx] = [System.Convert]::ToByte($hexString.Substring($bIdx * 2, 2), 16)
                }
                $writer.Write($chunk)
                $writer.Write([byte]$chdgCount)
                $writer.Write($cnamBytes, 0, $cnamBytes.Length)
                $writer.Write([byte[]]@(0x00, 0x00, 0x00, 0x00, 0x00))
            }
        }
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
    }
}

# --- GAME BOY ADVANCE MODULES ---
Register-InputModule -Name "Game Boy Advance / GBA" -Filter "GBA Cheat Files (*.cht;*.clt)|*.cht;*.clt" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "GBA" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $sniffLines = ""
    if (Test-Path $filePath) {
        $sniffLines = [System.IO.File]::ReadLines($filePath, $script:Utf8Encoding) | Select-Object -First 3
        $sniffLines = [string]::Join(" ", $sniffLines).Trim()
    }

    if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
        Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
    }
    elseif ($sniffLines -match '<\?xml' -and $sniffLines -match '<cheats>') {
        Import-MyBoyChtEngine -filePath $filePath -parseFunc $parseFunc
    }
    else {
        $stream = $null
        $bytesRead = 0
        $buffer = New-Object byte[] 12
        try {
            $stream = [System.IO.File]::OpenRead($filePath)
            $bytesRead = $stream.Read($buffer, 0, 12)
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }

        if ($bytesRead -ge 12) {
            $hexSignature = [string]::Join(" ", ($buffer | ForEach-Object { "{0:X2}" -f $_ })).Trim()
            if ($hexSignature -imatch '^01 00 00 00 (01|00) 00 00 00 [0-9A-Fa-f]{2} 00 00 00') {
                Import-VbaCltEngine -filePath $filePath
            } else {
                throw "Unknown or invalid binary cheat file format signature."
            }
        } else {
            throw "File is too small to contain a valid binary cheat header."
        }
    }
}

Register-OutputModule -Name "VBA-M (.clt)" -Filter "VBA Cheat Files (*.clt)|*.clt" -ExportFunc {
    param([string]$filePath)
    $stream = $null
    $writer = $null
    try {
        if (Test-Path $filePath) { Remove-Item $filePath -Force }
        $stream = [System.IO.File]::Create($filePath)
        $writer = [System.IO.BinaryWriter]::new($stream)

        $maskMap = @{
            '0' = 0xFF; '1' = 0x70; '2' = 0x21; '3' = 0x00
            '4' = 0x09; '5' = 0x24; '6' = 0x0B; '7' = 0x08
            '8' = 0x01; '9' = 0xFF; 'A' = 0x0A; 'B' = 0x23
            'C' = 0x22; 'D' = 0x07; 'E' = 0x20; 'F' = 0x32
        }

        $totalFlattenedCheats = 0
        foreach ($key in $script:CheatDatabase.Keys) { $totalFlattenedCheats += $script:CheatDatabase[$key].Codes.Count }
        $writer.Write([int]1)
        $writer.Write([int]1)
        $writer.Write([int]$totalFlattenedCheats)

        foreach ($compositeKey in $script:CheatDatabase.Keys) {
            $entry = $script:CheatDatabase[$compositeKey]
            $safeDesc = [regex]::Replace($entry.BaseDesc, '[^\x20-\x7E]', '')
            $descBytes = [System.Text.Encoding]::ASCII.GetBytes($safeDesc.PadRight(32, "`0"))
            if ($descBytes.Length -gt 32) { $descBytes = $descBytes[0..31] }

            $dataLinesRemaining = 0
            $isSlideNextLine = $false

            foreach ($codeItem in $entry.Codes) {
                $parts = $codeItem -split '\s+'
                if ($parts.Count -lt 2) { continue }
                
                $part1 = $parts[0].ToUpper().PadRight(8, '0').Substring(0,8)
                $part2 = $parts[1].ToUpper().PadRight(4, '0').Substring(0,4)
                $ctyp = $part1.Substring(0, 1)

                $cd8Bytes = [System.BitConverter]::GetBytes([System.Convert]::ToUInt32($part1, 16))
                $part1Zeroed = "0" + $part1.Substring(1)
                $cd8zBytes = [System.BitConverter]::GetBytes([System.Convert]::ToUInt32($part1Zeroed, 16))
                $cd4Bytes = [System.BitConverter]::GetBytes([System.Convert]::ToUInt16($part2, 16))

                $isMultiLineOverride = $false
                if ($dataLinesRemaining -gt 0) {
                    $isMultiLineOverride = $true
                    $dataLinesRemaining--
                } elseif ($isSlideNextLine) {
                    $isMultiLineOverride = $true
                    $isSlideNextLine = $false
                }

                $maskVal = if ($isMultiLineOverride) { 0xFF } else { $maskMap[$ctyp] }
                if ($null -eq $maskVal) { $maskVal = 0x00 }
                if ($maskVal -eq 0xFF) { $cd8zBytes = $cd8Bytes }

                $codeStrBytes = [System.Text.Encoding]::ASCII.GetBytes($codeItem.PadRight(20, "`0"))
                if ($codeStrBytes.Length -gt 20) { $codeStrBytes = $codeStrBytes[0..19] }

                $writer.Write([byte[]]@(0x00, 0x02, 0x00, 0x00))
                if ($isMultiLineOverride -or $ctyp -eq '0' -or $ctyp -eq '9') {
                    $writer.Write([byte[]]@(0xFF, 0xFF, 0xFF, 0xFF))
                } else {
                    $writer.Write([byte]$maskVal); $writer.Write([byte[]]@(0x00, 0x00, 0x00))
                }
                $writer.Write([int]0)
                $writer.Write([int]0)
                $writer.Write($cd8Bytes)
                $writer.Write($cd8zBytes)
                $writer.Write($cd4Bytes)
                $writer.Write([byte[]]@(0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
                $writer.Write($codeStrBytes)
                $writer.Write($descBytes)

                if (-not $isMultiLineOverride) {
                    if ($ctyp -eq '5') {
                        $halfwordCount = [System.Convert]::ToInt32($part2, 16)
                        $dataLinesRemaining = [int](([Math]::Floor(($halfwordCount - 1) -band 0xFFFF) / 3) + 1)
                    } elseif ($ctyp -eq '4') {
                        $isSlideNextLine = $true
                    }
                }
            }
        }
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
    }
}

# --- SNES MODULES ---
Register-InputModule -Name "Super Nintendo / SNES" -Filter "SNES Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "SNES" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-Generic1fewEngine -FilePath $filePath -SystemName "SNES" -HeaderPattern '^\s*name:\s*(.*)'
}

Register-OutputModule -Name "Snes9x (.cht)" -Filter "Snes9x Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        foreach ($codeItem in $entry.Codes) {
            $outputCode = $codeItem
            if ($outputCode.Length -eq 8 -and -not $outputCode.Contains("-")) {
                $outputCode = $outputCode.Substring(0, 6) + "=" + $outputCode.Substring(6, 2)
            }
            [void]$sb.AppendLine("cheat`n  name: $($entry.BaseDesc)`n  code: $outputCode`n")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# --- MASTER SYSTEM MODULES ---
Register-InputModule -Name "Sega Master System / SMS" -Filter "Master System Cheats (*.pat)|*.pat" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "SMS" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-Generic1to1Engine -FilePath $filePath -SystemName "SMS" -Delimiter "`t"
}

Register-OutputModule -Name "md.emu SMS (.pat)" -Filter "md.emu Cheat Files (*.pat)|*.pat" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        foreach ($codeItem in $entry.Codes) {
            [void]$sb.AppendLine("$codeItem`t$($entry.BaseDesc)")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# --- PLAYSTATION / PSX MODULES ---
Register-InputModule -Name "Sony PlayStation / PSX (PCSXR)" -Filter "PCSXR Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "PCSXR" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-Generic1fewEngine -FilePath $filePath -SystemName "PCSXR" -HeaderPattern '^\[(.*)\]'
}

Register-InputModule -Name "Sony PlayStation / PSX (ePSXe)" -Filter "ePSXe Cheat Files (*.txt)|*.txt" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "ePSXe" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-Generic1fewEngine -FilePath $filePath -SystemName "ePSXe" -HeaderPattern '^#(.*)'
}

Register-OutputModule -Name "PCSXR (.cht)" -Filter "PCSXR Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        if ($entry.Codes.Count -eq 0) { continue }
        [void]$sb.AppendLine("[$($entry.BaseDesc)]")
        foreach ($codeItem in $entry.Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

Register-OutputModule -Name "ePSXe (.txt)" -Filter "ePSXe Cheat Files (*.txt)|*.txt" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        if ($entry.Codes.Count -eq 0) { continue }
        [void]$sb.AppendLine("#$($entry.BaseDesc)")
        foreach ($codeItem in $entry.Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# --- GBC MODULES ---
Register-InputModule -Name "Game Boy / GBC" -Filter "GBC Cheat Files (*.gbcht)|*.gbcht" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "GBC" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $stream = $null
    $reader = $null
    $tempFile = $null
    try {
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $stream = [System.IO.MemoryStream]::new($fileBytes)
        $reader = [System.IO.BinaryReader]::new($stream)

        if ($stream.Length -ge 4) {
            $stream.Position = 1
            $totalRecords = $reader.ReadByte()
            $stream.Position = 3
            
            $preprocessedLines = [System.Collections.Generic.List[string]]::new()

            for ($i = 0; $i -lt $totalRecords; $i++) {
                if ($stream.Position + 3 -gt $stream.Length) { break }
                $status = $reader.ReadByte()
                $descLen = $reader.ReadByte()
                $nullSep = $reader.ReadByte()

                if ($stream.Position + $descLen -gt $stream.Length) { break }
                $rawDesc = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes($descLen)).Trim()

                if ($stream.Position + 1 -gt $stream.Length) { break }
                $prefixByte = $reader.ReadByte()
                $codeLen = if ($prefixByte -eq 0x0b) { 11 } else { 8 }

                if ($stream.Position + $codeLen -gt $stream.Length) { break }
                $rawCode = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes($codeLen)).Trim()

                if ([string]::IsNullOrWhiteSpace($rawDesc)) { $rawDesc = "Unassigned Code Block" }
                if (-not [string]::IsNullOrWhiteSpace($rawCode)) {
                    $preprocessedLines.Add("$rawCode`t$rawDesc")
                }
            }

            if ($preprocessedLines.Count -gt 0) {
                $tempFile = [System.IO.Path]::GetTempFileName()
                [System.IO.File]::WriteAllLines($tempFile, $preprocessedLines.ToArray(), $script:Utf8Encoding)
                Import-Generic1to1Engine -FilePath $tempFile -SystemName "GBC" -Delimiter "`t"
            }
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $tempFile -and (Test-Path $tempFile)) { Remove-Item $tempFile -Force }
    }
}

Register-OutputModule -Name "GBC.emu (.gbcht)" -Filter "GBC Cheat Files (*.gbcht)|*.gbcht" -ExportFunc {
    param([string]$filePath)
    $stream = [System.IO.File]::Create($filePath)
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        $total = 0
        foreach ($d in $script:CheatDatabase.Keys) { $total += $script:CheatDatabase[$d].Codes.Count }
        $writer.Write([byte]0x00)
        $writer.Write([byte][Math]::Min($total, 255))
        $writer.Write([byte]0x00)

        $processed = 0
        foreach ($compositeKey in $script:CheatDatabase.Keys) {
            if ($processed -ge 255) { break }
            $entry = $script:CheatDatabase[$compositeKey]
            $safeDesc = [regex]::Replace($entry.BaseDesc, '[^\x20-\x7E]', '')
            $descBytes = [System.Text.Encoding]::ASCII.GetBytes($safeDesc)
            foreach ($code in $entry.Codes) {
                if ($processed -ge 255) { break }
                $prefixByte = if ($code.Contains("-")) { [byte]0x0b } else { [byte]0x08 }
                $codeBytes = [System.Text.Encoding]::ASCII.GetBytes($code)
                $writer.Write([byte]0x00)
                $writer.Write([byte]$descBytes.Length)
                $writer.Write([byte]0x00)
                $writer.Write($descBytes, 0, $descBytes.Length)
                $writer.Write([byte]$prefixByte)
                $writer.Write($codeBytes, 0, $codeBytes.Length)
                $processed++
            }
        }
    } finally { 
        if ($null -ne $writer) { $writer.Dispose() }
    }
}

# --- MEGA DRIVE / MD MODULES ---
Register-InputModule -Name "Sega Mega Drive / MD" -Filter "MD Cheats (*.pat)|*.pat" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "MD" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-Generic1to1Engine -FilePath $filePath -SystemName "MD" -Delimiter "`t"
}

Register-OutputModule -Name "md.emu MD (.pat)" -Filter "md.emu Cheat Files (*.pat)|*.pat" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        foreach ($codeItem in $entry.Codes) {
            [void]$sb.AppendLine("$codeItem`t$($entry.BaseDesc)")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# --- NINTENDO DS MODULES ---
Register-InputModule -Name "Nintendo DS" -Filter "NDS Cheat Files (*.mch)|*.mch" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "NDS" -RawLine $inputBlock
    if ($null -ne $res) { return $res.Code } else { return $null }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-Generic1fewEngine -FilePath $filePath -SystemName "NDS" -HeaderPattern '^CODE\s+\d+\s*(.*)'
}

Register-OutputModule -Name "melonDS (.mch)" -Filter "melonDS Cheat Files (*.mch)|*.mch" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("CAT Cheats")
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        [void]$sb.AppendLine("CODE 0 $($entry.BaseDesc)")
        foreach ($codeItem in $entry.Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# ==============================================================================
# NES GAME GENIE TRANSLATION ENGINE
# ==============================================================================
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
    for ($i = 0; $i -lt $gg.Length; $i++) { $data[$i] = Convert-UnmapNesChar $gg[$i] }
    
    $address = 0x8000
    $address = $address -bor (($data[1] -band 8) -shl 4)
    $address = $address -bor (($data[2] -band 7) -shl 4)
    $address = $address -bor (($data[3] -band 7) -shl 12)
    $address = $address -bor (($data[3] -band 8) -shl 0)
    $address = $address -bor (($data[4] -band 7) -shl 0)
    $address = $address -bor (($data[4] -band 8) -shl 8)
    $address = $address -bor (($data[5] -band 7) -shl 8)
    
    $value = 0; $check = 0; $haveCheck = ($gg.Length -eq 8)
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
    $check = 0; $haveCheck = $false
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

# --- NES MODULES ---
Register-InputModule -Name "Nintendo NES" -Filter "NES Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock)
    $res = Invoke-SystemParser -SystemName "NES" -RawLine $inputBlock
    if ($null -eq $res) { return $null }
    $cleanCode = $res.Code
    if (-not [string]::IsNullOrEmpty($cleanCode)) {
        if ($cleanCode -match '^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$') {
            $hexAddress = [System.Convert]::ToInt32($Matches[1], 16)
            if ($hexAddress -ge 0x8000) {
                $encoded = Invoke-GameGenieEncodeNES $cleanCode
                if ($null -ne $encoded) { return $encoded }
            }
        }
    }
    return $cleanCode
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $sniffLines = ""
    if (Test-Path $filePath) {
        $sniffLines = [System.IO.File]::ReadLines($filePath, $script:Utf8Encoding) | Select-Object -First 3
        $sniffLines = [string]::Join(" ", $sniffLines).Trim()
    }

    if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
        Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
    } else {
        Import-NesChtEngine -filePath $filePath -parseFunc $parseFunc
    }
}

Register-OutputModule -Name "nes.emu (.cht)" -Filter "nes.emu Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        $cleanDesc = $entry.BaseDesc.Trim()
        foreach ($codeItem in $entry.Codes) {
            $subCodes = $codeItem.Split('+', [System.StringSplitOptions]::RemoveEmptyEntries)
            foreach ($subCode in $subCodes) {
                $rawCode = $subCode.Trim().TrimStart(':')
                if ($rawCode.Length -eq 9 -and $rawCode -match '^[A-Z]{9}$') { $rawCode = $rawCode.Substring(1) }
                if ($rawCode -match '^[A-Z]{6}$|^[A-Z]{8}$') {
                    $decoded = Invoke-GameGenieDecodeNES $rawCode
                    if ($null -ne $decoded) { $rawCode = $decoded }
                }
                
                if ($rawCode -match '^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$') {
                    $addrStr = $Matches[1]; $valStr = $Matches[2]; $cmpStr = $Matches[3]
                    $isHighAddress = ([Convert]::ToInt32($addrStr, 16)) -ge 0x8000
                    $hasCompare = -not [string]::IsNullOrEmpty($cmpStr)
                    
                    $prefix = if ($isHighAddress) { if ($hasCompare) { "SC:" } else { "S:" } } else { if ($hasCompare) { "C:" } else { ":" } }
                    $bodyStr = if ($hasCompare) { "${addrStr}:${valStr}:${cmpStr}" } else { "${addrStr}:${valStr}" }
                    [void]$sb.AppendLine("${prefix}${bodyStr}:${cleanDesc}")
                } else {
                    $fallbackCode = if ($rawCode.StartsWith(':')) { $rawCode } else { ":$rawCode" }
                    [void]$sb.AppendLine("${fallbackCode}:${cleanDesc}")
                }
            }
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# --- GLOBAL RETROARCH MODULES ---
Register-InputModule -Name "RetroArch (Global)" -Filter "RetroArch Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock, [string]$targetModule)
    if ([string]::IsNullOrEmpty($targetModule)) { return $null }

    $results = [System.Collections.Generic.List[string]]::new()
    $systemKey = $script:SystemKeyMap[$targetModule]
    $totalMatchLength = 0

    if ($null -ne $systemKey -and $script:SystemCodePatterns.Contains($systemKey)) {
        $activePatterns = $script:SystemCodePatterns[$systemKey]
        $sanitizedBlock = $inputBlock.Replace('+', ' ')

        foreach ($patternKey in $activePatterns.Keys) {
            $regex = $activePatterns[$patternKey]
            $matches = $regex.Matches($sanitizedBlock)
            foreach ($match in $matches) {
                $cleanCode = $match.Value.ToUpper().Trim()
                if (-not [string]::IsNullOrEmpty($cleanCode)) {
                    $results.Add($cleanCode)
                    $totalMatchLength += $match.Value.Length
                }
            }
        }
    }
    
    # Layout A: Return full character match relationship telemetry objects down the stream
    return [PSCustomObject]@{
        Codes       = $results.ToArray()
        RawLength   = $inputBlock.Length
        MatchLength = $totalMatchLength
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
}

Register-OutputModule -Name "RetroArch (.cht)" -Filter "RetroArch Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("cheats = $($script:CheatDatabase.Count)")
    [void]$sb.AppendLine("")
    $idx = 0
    foreach ($compositeKey in $script:CheatDatabase.Keys) {
        $entry = $script:CheatDatabase[$compositeKey]
        $joinedCodes = [string]::Join("+", $entry.Codes)
        [void]$sb.AppendLine("cheat${idx}_desc = `"$($entry.BaseDesc)`"")
        [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
        [void]$sb.AppendLine("cheat${idx}_enable = false")
        [void]$sb.AppendLine("")
        $idx++
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# ==============================================================================
# MAIN GUI FORM & CONTROLS (Dynamic Grid Layout Optimization)
# ==============================================================================

$script:form = [System.Windows.Forms.Form]::new()
$script:form.Text = "Multi-Emulator Cheat Reformatter"
$script:form.Size = [System.Drawing.Size]::new(720, 650)
$script:form.StartPosition = "CenterScreen"
$script:form.MinimumSize = [System.Drawing.Size]::new(600, 500)

$mainPanel = [System.Windows.Forms.TableLayoutPanel]::new()
$mainPanel.Dock = "Fill"
$mainPanel.RowCount = 5
$mainPanel.ColumnCount = 1
$mainPanel.Padding = [System.Windows.Forms.Padding]::new(10)
[void]$mainPanel.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("Absolute", 40)))
[void]$mainPanel.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("Percent", 100)))
[void]$mainPanel.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("Absolute", 40)))
[void]$mainPanel.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("Absolute", 20)))
[void]$mainPanel.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("Absolute", 70)))
$script:form.Controls.Add($mainPanel)

# --- Row 0: Top Block (Import Components Flow) ---
$topFlow = [System.Windows.Forms.FlowLayoutPanel]::new()
$topFlow.Dock = "Fill"
$topFlow.FlowDirection = "LeftToRight"
$topFlow.WrapContents = $false

$script:lblInput = [System.Windows.Forms.Label]::new()
$script:lblInput.Text = "Input Module:"
$script:lblInput.Anchor = "Left"
$script:lblInput.AutoSize = $true
$topFlow.Controls.Add($script:lblInput)

$script:cmbInputModule = [System.Windows.Forms.ComboBox]::new()
$script:cmbInputModule.DropDownStyle = "DropDownList"
$script:cmbInputModule.Width = 190
foreach ($key in $script:InputModules.Keys) { [void]$script:cmbInputModule.Items.Add($key) }
$topFlow.Controls.Add($script:cmbInputModule)

$script:btnImport = [System.Windows.Forms.Button]::new()
$script:btnImport.Text = "Import File"
$script:btnImport.Width = 100
$topFlow.Controls.Add($script:btnImport)

$script:lblTargetRegex = [System.Windows.Forms.Label]::new()
$script:lblTargetRegex.Text = "Target System Regex:"
$script:lblTargetRegex.Anchor = "Left"
$script:lblTargetRegex.Margin = [System.Windows.Forms.Padding]::new(2, 0, 0, 0)
$script:lblTargetRegex.AutoSize = $true
$script:lblTargetRegex.Visible = $false
$topFlow.Controls.Add($script:lblTargetRegex)

$script:cmbTargetRegex = [System.Windows.Forms.ComboBox]::new()
$script:cmbTargetRegex.DropDownStyle = "DropDownList"
$script:cmbTargetRegex.Width = 185
foreach ($key in $script:InputModules.Keys) {
    if ($key -ne "RetroArch (Global)") { [void]$script:cmbTargetRegex.Items.Add($key) }
}
if ($script:cmbTargetRegex.Items.Count -gt 0) { $script:cmbTargetRegex.SelectedIndex = 0 }
$script:cmbTargetRegex.Visible = $false
$topFlow.Controls.Add($script:cmbTargetRegex)

$mainPanel.Controls.Add($topFlow, 0, 0)

# --- Row 1: Middle Block (Workspace Grid Layout) ---
$midGrid = [System.Windows.Forms.TableLayoutPanel]::new()
$midGrid.Dock = "Fill"
$midGrid.ColumnCount = 2
$midGrid.RowCount = 3
[void]$midGrid.ColumnStyles.Add(([System.Windows.Forms.ColumnStyle]::new("Percent", 44)))
[void]$midGrid.ColumnStyles.Add(([System.Windows.Forms.ColumnStyle]::new("Percent", 56)))
[void]$midGrid.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("AutoSize")))
[void]$midGrid.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("Percent", 100)))
[void]$midGrid.RowStyles.Add(([System.Windows.Forms.RowStyle]::new("Absolute", 35)))

$script:lblList = [System.Windows.Forms.Label]::new()
$script:lblList.Text = "Grouped Cheat Descriptions:"
$script:lblList.Dock = "Fill"
$midGrid.Controls.Add($script:lblList, 0, 0)

$script:lstCheats = [System.Windows.Forms.ListBox]::new()
$script:lstCheats.Dock = "Fill"
$midGrid.Controls.Add($script:lstCheats, 0, 1)

$leftActionTable = [System.Windows.Forms.TableLayoutPanel]::new()
$leftActionTable.Dock = "Fill"
$leftActionTable.RowCount = 1
$leftActionTable.ColumnCount = 5
$leftActionTable.Padding = [System.Windows.Forms.Padding]::new(0)
$leftActionTable.Margin = [System.Windows.Forms.Padding]::new(0)

[void]$leftActionTable.ColumnStyles.Add(([System.Windows.Forms.ColumnStyle]::new("Percent", 40)))
[void]$leftActionTable.ColumnStyles.Add(([System.Windows.Forms.ColumnStyle]::new("Percent", 21)))
[void]$leftActionTable.ColumnStyles.Add(([System.Windows.Forms.ColumnStyle]::new("Percent", 13)))
[void]$leftActionTable.ColumnStyles.Add(([System.Windows.Forms.ColumnStyle]::new("Percent", 13)))
[void]$leftActionTable.ColumnStyles.Add(([System.Windows.Forms.ColumnStyle]::new("Percent", 13)))

$script:txtNewGroup = [System.Windows.Forms.TextBox]::new()
$script:txtNewGroup.Dock = "Fill"
$leftActionTable.Controls.Add($script:txtNewGroup, 0, 0)

$script:btnNewGroup = [System.Windows.Forms.Button]::new()
$script:btnNewGroup.Text = "Add"
$script:btnNewGroup.Dock = "Fill"
$leftActionTable.Controls.Add($script:btnNewGroup, 1, 0)

$script:btnMoveUp = [System.Windows.Forms.Button]::new()
$script:btnMoveUp.Text = "▲"
$script:btnMoveUp.Dock = "Fill"
$script:btnMoveUp.Enabled = $false
$leftActionTable.Controls.Add($script:btnMoveUp, 2, 0)

$script:btnMoveDown = [System.Windows.Forms.Button]::new()
$script:btnMoveDown.Text = "▼"
$script:btnMoveDown.Dock = "Fill"
$script:btnMoveDown.Enabled = $false
$leftActionTable.Controls.Add($script:btnMoveDown, 3, 0)

$script:btnDeleteGroup = [System.Windows.Forms.Button]::new()
$script:btnDeleteGroup.Text = "❌"
$script:btnDeleteGroup.Dock = "Fill"
$script:btnDeleteGroup.Enabled = $false
$leftActionTable.Controls.Add($script:btnDeleteGroup, 4, 0)

$midGrid.Controls.Add($leftActionTable, 0, 2)

$script:lblEditor = [System.Windows.Forms.Label]::new()
$script:lblEditor.Text = "Codes in Selected Group (One per line):"
$script:lblEditor.Dock = "Fill"
$midGrid.Controls.Add($script:lblEditor, 1, 0)

$script:txtEditor = [System.Windows.Forms.TextBox]::new()
$script:txtEditor.Multiline = $true
$script:txtEditor.ScrollBars = "Vertical"
$script:txtEditor.Font = [System.Drawing.Font]::new([System.Drawing.FontFamily]::GenericMonospace, 10)
$script:txtEditor.Dock = "Fill"
$script:txtEditor.Add_TextChanged($script:TextChangeHandler)
$midGrid.Controls.Add($script:txtEditor, 1, 1)

$script:btnSaveGroup = [System.Windows.Forms.Button]::new()
$script:btnSaveGroup.Text = "Update Current Modifications"
$script:btnSaveGroup.Dock = "Fill"
$script:btnSaveGroup.Enabled = $false
$midGrid.Controls.Add($script:btnSaveGroup, 1, 2)

$mainPanel.Controls.Add($midGrid, 0, 1)

# --- Row 2: Export Block Section ---
$exportFlow = [System.Windows.Forms.FlowLayoutPanel]::new()
$exportFlow.Dock = "Fill"
$exportFlow.FlowDirection = "LeftToRight"
$exportFlow.WrapContents = $false

$script:lblOutput = [System.Windows.Forms.Label]::new()
$script:lblOutput.Text = "Export To:"
$script:lblOutput.Anchor = "Left"
$script:lblOutput.AutoSize = $true
$exportFlow.Controls.Add($script:lblOutput)

$script:cmbOutputModule = [System.Windows.Forms.ComboBox]::new()
$script:cmbOutputModule.DropDownStyle = "DropDownList"
$script:cmbOutputModule.Width = 185
$exportFlow.Controls.Add($script:cmbOutputModule)

$script:btnExport = [System.Windows.Forms.Button]::new()
$script:btnExport.Text = "Export File"
$script:btnExport.Width = 100
$exportFlow.Controls.Add($script:btnExport)

$mainPanel.Controls.Add($exportFlow, 0, 2)

# --- Row 3 & 4: Bottom Status Log ---
$script:lblStatus = [System.Windows.Forms.Label]::new()
$script:lblStatus.Text = "System Activity Log:"
$script:lblStatus.Dock = "Fill"
$mainPanel.Controls.Add($script:lblStatus, 0, 3)

$script:txtStatusLog = [System.Windows.Forms.TextBox]::new()
$script:txtStatusLog.Multiline = $true
$script:txtStatusLog.ReadOnly = $true
$script:txtStatusLog.ScrollBars = "Vertical"
$script:txtStatusLog.Font = New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericMonospace, 8.5)
$script:txtStatusLog.BackColor = [System.Drawing.Color]::White
$script:txtStatusLog.ForeColor = [System.Drawing.Color]::Black
$script:txtStatusLog.Dock = "Fill"
$mainPanel.Controls.Add($script:txtStatusLog, 0, 4)

# ==============================================================================
# DYNAMIC INPUT/OUTPUT MODULE RELATIONSHIP LOGIC
# ==============================================================================

function Update-OutputModuleChoices {
    if ($null -eq $script:cmbInputModule -or $null -eq $script:cmbOutputModule) { return }
    if ($null -eq $script:cmbInputModule.SelectedItem) { return }

    $selectedInput = $script:cmbInputModule.SelectedItem.ToString()

    $script:cmbOutputModule.BeginUpdate()
    try {
        $script:cmbOutputModule.Items.Clear()
        $retroArchOutputKey = "RetroArch (.cht)"

        if ($selectedInput -eq "RetroArch (Global)") {
            $script:lblTargetRegex.Visible = $true
            $script:cmbTargetRegex.Visible = $true
            $script:cmbTargetRegex.Enabled = $true

            if ($null -ne $script:cmbTargetRegex.SelectedItem) {
                $targetSys = $script:cmbTargetRegex.SelectedItem.ToString()
                $mappedOutputKey = $script:ModuleOutputMap[$targetSys]
                if ($null -ne $mappedOutputKey -and $script:OutputModules.Contains($mappedOutputKey)) {
                    [void]$script:cmbOutputModule.Items.Add($mappedOutputKey)
                }
            }

            if ($script:OutputModules.Contains($retroArchOutputKey) -and -not $script:cmbOutputModule.Items.Contains($retroArchOutputKey)) {
                [void]$script:cmbOutputModule.Items.Add($retroArchOutputKey)
            }
            $script:cmbOutputModule.Enabled = $true
        } else {
            if ($script:OutputModules.Contains($retroArchOutputKey)) {
                [void]$script:cmbOutputModule.Items.Add($retroArchOutputKey)
            }

            $mappedOutputKey = $script:ModuleOutputMap[$selectedInput]
            if ($null -ne $mappedOutputKey -and $script:OutputModules.Contains($mappedOutputKey) -and -not $script:cmbOutputModule.Items.Contains($mappedOutputKey)) {
                [void]$script:cmbOutputModule.Items.Add($mappedOutputKey)
            }

            $script:cmbOutputModule.Enabled = ($script:cmbOutputModule.Items.Count -gt 1)
            $script:lblTargetRegex.Visible = $false
            $script:cmbTargetRegex.Visible = $false
            $script:cmbTargetRegex.Enabled = $false
        }

        if ($script:cmbOutputModule.Items.Count -gt 0) {
            $script:cmbOutputModule.SelectedIndex = 0
        }
    } finally {
        $script:cmbOutputModule.EndUpdate()
    }
}

$script:cmbInputModule.Add_SelectedIndexChanged({ Update-OutputModuleChoices })
$script:cmbTargetRegex.Add_SelectedIndexChanged({ Update-OutputModuleChoices })

if ($script:cmbInputModule.Items.Count -gt 0) {
    $script:cmbInputModule.SelectedIndex = 0
}
Update-OutputModuleChoices

# ==============================================================================
# UI EVENT HANDLERS (Reworked for index-safe metadata lookup)
# ==============================================================================

$script:btnImport.Add_Click({
    if ($script:IsDirty) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes?", "Unsaved Progress", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }
    }

    $selectedModule = $script:cmbInputModule.SelectedItem.ToString()
    $module = $script:InputModules[$selectedModule]

    $ofd = [System.Windows.Forms.OpenFileDialog]::new()
    try {
        $ofd.Filter = $module.Filter
        if (-not [string]::IsNullOrEmpty($script:LastDirectory) -and (Test-Path $script:LastDirectory)) {
            $ofd.InitialDirectory = $script:LastDirectory
        }

        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:LastDirectory = [System.IO.Path]::GetDirectoryName($ofd.FileName)
            try {
                $script:CheatDatabase.Clear()
                $targetModName = if ($selectedModule -eq "RetroArch (Global)") { $script:cmbTargetRegex.SelectedItem.ToString() } else { $null }
                $parseFunc = if ($selectedModule -eq "RetroArch (Global)") {
                    { param($text) & $module.ParseFunc $text $targetModName }
                } else {
                    $module.ParseFunc
                }

                & $module.ImportFunc $ofd.FileName $parseFunc
                Refresh-CheatList
                $script:txtNewGroup.Clear()
                Write-Log("Import finished successfully!")
            } catch {
                Write-Log("Parsing error: $_", "ERROR")
            }
        }
    } finally {
        $ofd.Dispose()
    }
})

$script:btnExport.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        Write-Log("No cheats loaded to export.", "WARN")
        return
    }

    $selectedModule = $script:cmbOutputModule.SelectedItem.ToString()
    $module = $script:OutputModules[$selectedModule]

    $sfd = [System.Windows.Forms.SaveFileDialog]::new()
    try {
        $sfd.Filter = $module.Filter
        if (-not [string]::IsNullOrEmpty($script:LastDirectory) -and (Test-Path $script:LastDirectory)) {
            $sfd.InitialDirectory = $script:LastDirectory
        }

        if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:LastDirectory = [System.IO.Path]::GetDirectoryName($sfd.FileName)
            try {
                & $module.ExportFunc $sfd.FileName
                Write-Log("Export finished successfully!")
            } catch {
                Write-Log("Export error: $_", "ERROR")
            }
        }
    } finally {
        $sfd.Dispose()
    }
})

$script:ListSelectionHandler = {
    if ($script:lstCheats.SelectedIndex -eq $script:LastSelectedIndex) { return }

    if ($script:IsDirty -and $script:LastSelectedIndex -ge 0 -and $script:LastSelectedIndex -lt $script:lstCheats.Items.Count) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved group modifications?", "Unsaved Progress", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
            Disable-ListEvents
            $script:lstCheats.SelectedIndex = $script:LastSelectedIndex
            Enable-ListEvents
            return
        }
    }

    if ($script:lstCheats.SelectedIndex -ne -1) {
        $script:LastSelectedIndex = $script:lstCheats.SelectedIndex
        $dbKeys = @($script:CheatDatabase.Keys)
        $selectedKey = $dbKeys[$script:LastSelectedIndex]
        
        $script:SuppressEvents = $true
        $flattenedCodes = @($script:CheatDatabase[$selectedKey].Codes)
        
        # Wine Layout Update: Wrap to guarantee layout engine handles multiline operations without stuttering
        try {
            $script:txtEditor.SuspendLayout()
            $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $flattenedCodes)
        } finally {
            $script:txtEditor.ResumeLayout()
        }
        
        $script:IsDirty = $false
        $script:SuppressEvents = $false
    }
}
Enable-ListEvents

$script:btnSaveGroup.Add_Click({
    $idx = $script:lstCheats.SelectedIndex
    if ($idx -lt 0) { return }
    
    $dbKeys = @($script:CheatDatabase.Keys)
    $targetKey = $dbKeys[$idx]
    $entry = $script:CheatDatabase[$targetKey]

    $selectedInput = $script:cmbInputModule.SelectedItem.ToString()
    $sysName = if ($selectedInput -eq "RetroArch (Global)") { $script:cmbTargetRegex.SelectedItem.ToString() } else { $selectedInput }
    $systemKey = $script:SystemKeyMap[$sysName]

    $lines = $script:txtEditor.Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $updatedCodes = [System.Collections.Generic.List[string]]::new()
    $hasInvalidEntries = $false
    
    # DYNAMIC FORMAT LOCKING: Establish the target format from the FIRST valid line found in the editor.
    $lockedFormat = $null

    foreach ($line in $lines) {
        $cleanLine = $line.Trim().ToUpper()
        $parseResult = Invoke-SystemParser -SystemName $systemKey -RawLine $cleanLine
        
        if ($null -ne $parseResult) {
            # 1. Lock the entire block to the format of the very first valid code
            if ($null -eq $lockedFormat) {
                $lockedFormat = $parseResult.Format
            }
            
            # 2. Enforce isolation: Reject any code that doesn't match the newly locked format
            if ($parseResult.Format -eq $lockedFormat) {
                $updatedCodes.Add($parseResult.Code)
            } else {
                $hasInvalidEntries = $true
                Write-Log("Line '$line' rejected. Block is locked to format '$lockedFormat'. Cannot mix with '$($parseResult.Format)'.", "ERROR")
            }
        } else {
            $hasInvalidEntries = $true
            Write-Log("Line '$line' rejected. Does not match any valid patterns for profile '$sysName'.", "ERROR")
        }
    }

    # Fallback to the original metadata format if the user cleared the box entirely or all entries failed
    if ($null -eq $lockedFormat) {
        $lockedFormat = $entry.Format
    }

    # Safely update metadata and handle composite key migration to keep the database aligned
    $entry.Codes = $updatedCodes
    $entry.Format = $lockedFormat
    $newCompositeKey = "$($entry.BaseDesc):::$lockedFormat"

    if ($targetKey -ne $newCompositeKey) {
        $newDb = [ordered]@{ }
        foreach ($k in $script:CheatDatabase.Keys) {
            if ($k -eq $targetKey) {
                $newDb[$newCompositeKey] = $entry
            } else {
                $newDb[$k] = $script:CheatDatabase[$k]
            }
        }
        $script:CheatDatabase = $newDb
    } else {
        $script:CheatDatabase[$targetKey] = $entry
    }
    
    # Wine Consistency Layout Guard
    $script:SuppressEvents = $true
    try {
        $script:txtEditor.SuspendLayout()
        $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $updatedCodes)
    } finally {
        $script:txtEditor.ResumeLayout()
    }
    $script:SuppressEvents = $false
    $script:IsDirty = $false
    
    if ($hasInvalidEntries) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Mismatched or invalid codes were detected and removed. A single block cannot mix different formats (e.g., 62hex and 44hex).", 
            "Format Isolation Rule", 
            "OK", 
            "Warning"
        )
    } else {
        Write-Log("Group '$($entry.BaseDesc)' successfully updated as uniform '$lockedFormat' format.")
    }
})

$script:btnNewGroup.Add_Click({
    $newTitle = $script:txtNewGroup.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($newTitle)) { return }
    if (-not (Save-CurrentSelectionIfDirty)) { return }

    # 1. Evaluate the active UI dropdown selection
    $selectedInput = $script:cmbInputModule.SelectedItem.ToString()
    $sysName = if ($selectedInput -eq "RetroArch (Global)") { $script:cmbTargetRegex.SelectedItem.ToString() } else { $selectedInput }
    
    # 2. Resolve to shorthand system key
    $systemKey = $script:SystemKeyMap[$sysName]
    
    # 3. Explicitly map and inherit the primary target format metadata standard
    $inheritedFormat = "Unknown"
    if ($null -ne $systemKey -and $script:SystemCodePatterns.Contains($systemKey)) {
        foreach ($key in $script:SystemCodePatterns[$systemKey].Keys) {
            $inheritedFormat = $key
            break # Inherit the primary format standard (e.g., "MD" -> "64hex")
        }
    }

    # 4. Initialize the primary composite key immediately to preserve [ordered] dictionary layout index positions
    $compositeKey = "$newTitle:::$inheritedFormat"
    if (-not $script:CheatDatabase.Contains($compositeKey)) {
        $script:CheatDatabase[$compositeKey] = [PSCustomObject]@{
            BaseDesc = $newTitle
            Format   = $inheritedFormat
            Codes    = [System.Collections.Generic.List[string]]::new()
            Health   = 1.0
        }
    }

    $script:txtNewGroup.Clear()

    Disable-ListEvents
    $script:lstCheats.BeginUpdate()
    try {
        [void]$script:lstCheats.Items.Add($newTitle)
        $script:lstCheats.SelectedIndex = $script:lstCheats.Items.Count - 1
        $script:LastSelectedIndex = $script:lstCheats.SelectedIndex

        $script:SuppressEvents = $true
        $script:txtEditor.Clear()
        $script:IsDirty = $false
        $script:SuppressEvents = $false

        Update-UIState
    } finally {
        $script:lstCheats.EndUpdate()
        Enable-ListEvents
    }
    Write-Log("Added new group '$newTitle' with inherited format standard '$inheritedFormat'.")
})

$script:txtNewGroup.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        $script:btnNewGroup.PerformClick()
    }
})

$script:btnDeleteGroup.Add_Click({
    $idx = $script:lstCheats.SelectedIndex
    if ($idx -lt 0) { return }

    $dbKeys = @($script:CheatDatabase.Keys)
    $selectedKey = $dbKeys[$idx]
    $displayTitle = $script:CheatDatabase[$selectedKey].BaseDesc

    if ([System.Windows.Forms.MessageBox]::Show("Delete group '$displayTitle'?", "Confirm", "YesNo", "Warning") -eq "No") { return }

    $script:CheatDatabase.Remove($selectedKey)
    $script:IsDirty = $false

    Disable-ListEvents
    $script:lstCheats.BeginUpdate()
    try {
        $script:lstCheats.Items.RemoveAt($idx)
        if ($script:lstCheats.Items.Count -gt 0) {
            $newIdx = if ($idx -lt $script:lstCheats.Items.Count) { $idx } else { $script:lstCheats.Items.Count - 1 }
            $script:lstCheats.SelectedIndex = $newIdx
            $script:LastSelectedIndex = $newIdx
            
            $nextKeys = @($script:CheatDatabase.Keys)
            $nextKey = $nextKeys[$newIdx]
            
            $script:SuppressEvents = $true
            $flattenedCodes = @($script:CheatDatabase[$nextKey].Codes)
            try {
                $script:txtEditor.SuspendLayout()
                $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $flattenedCodes)
            } finally {
                $script:txtEditor.ResumeLayout()
            }
            $script:SuppressEvents = $false
        } else {
            $script:LastSelectedIndex = -1
            $script:SuppressEvents = $true
            $script:txtEditor.Clear()
            $script:SuppressEvents = $false
        }
        Update-UIState
    } finally {
        $script:lstCheats.EndUpdate()
        Enable-ListEvents
    }
    Write-Log("Deleted group '$displayTitle'.")
})

function Move-CheatGroup ([int]$direction) {
    $idx = $script:lstCheats.SelectedIndex
    if ($idx -lt 0) { return }
    $targetIdx = $idx + $direction
    if ($targetIdx -lt 0 -or $targetIdx -ge $script:lstCheats.Items.Count) { return }
    if (-not (Save-CurrentSelectionIfDirty)) { return }

    $keys = [System.Collections.Generic.List[string]]::new([string[]]$script:CheatDatabase.Keys)
    $temp = $keys[$idx]
    $keys[$idx] = $keys[$targetIdx]
    $keys[$targetIdx] = $temp

    $newDb = [ordered]@{ }
    foreach ($k in $keys) { $newDb[$k] = $script:CheatDatabase[$k] }
    $script:CheatDatabase = $newDb

    Disable-ListEvents
    $script:lstCheats.BeginUpdate()
    try {
        $script:lstCheats.Items.Clear()
        foreach ($k in $script:CheatDatabase.Keys) { [void]$script:lstCheats.Items.Add($script:CheatDatabase[$k].BaseDesc) }
        $script:lstCheats.SelectedIndex = $targetIdx
        $script:LastSelectedIndex = $targetIdx
        $script:IsDirty = $false
    } finally {
        $script:lstCheats.EndUpdate()
        Enable-ListEvents
    }
}

$script:btnMoveUp.Add_Click({ Move-CheatGroup -1 })
$script:btnMoveDown.Add_Click({ Move-CheatGroup 1 })

# ==============================================================================
# RUNTIME INITIALIZATION & GUI DISPLAY PIPELINE
# ==============================================================================

$script:form.ShowDialog()
try { $script:form.Dispose() } catch { }
