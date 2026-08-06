Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================================================================
# GLOBAL DATA & STATE
# ==============================================================================
$script:CheatDatabase = [ordered]@{ }  # Key: String (Desc/Tag), Value: PSCustomObject @{ BaseDesc, CodeType, Codes }
$script:IsDirty = $false
$script:LastSelectedIndex = -1

# Registries to hold input/output parser & writer functions
$script:InputModules  = [ordered]@{ }
$script:OutputModules = [ordered]@{ }

# Centralized Regex Patterns Registry (Duplicate patterns flattened and named)
$script:RegexPatterns = [ordered]@{
    "AddressAndValue"   = '([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4,8})'                     # PSX, NDS, Saturn, GBA (8-char addr + 4-8 char val)
    "TripleGroupHyphen" = '([0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}-[0-9A-Fa-f]{3})'            # GBC, SMS, Sega MD
    "SnesCombined"      = '([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}=[0-9A-Fa-f]{2}|[0-9A-Fa-f]{8})' # SNES Game Genie / PAR
    "SmsMdExtended"     = '([0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}|[0-9A-Fa-f]{6}:[0-9A-Fa-f]{4}|[0-9A-Z]{4}-[0-9A-Z]{4})' # SMS & Sega MD
    "GbcCombined"       = '([0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}|[0-9A-Fa-f]{8})' # GBC Game Genie / Raw
    "NesCombined"       = '([A-Na-nP-Zp-z0-9]{6,8}|[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2})?)' # NES Game Genie / RAM Address
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

# Local event handler definition
$script:TextChangeHandler = {
    $script:IsDirty = $true
}

# ==============================================================================
# UNIVERSAL REGEX PARSING ENGINE & HELPER
# ==============================================================================

function Get-ModuleRegexPattern {
    param([string]$PatternKey)
    if ($script:RegexPatterns.Contains($PatternKey)) {
        return $script:RegexPatterns[$PatternKey]
    }
    return $PatternKey # Fallback to raw pattern string if direct string passed
}

function Invoke-UniversalRegexParser {
    param(
        [string]$RawText,
        [string]$PatternKey,
        [scriptblock]$Formatter = $null
    )
    $resolvedPattern = Get-ModuleRegexPattern -PatternKey $PatternKey
    
    if ([string]::IsNullOrWhiteSpace($RawText) -or [string]::IsNullOrWhiteSpace($resolvedPattern)) {
        return @()
    }

    $matches = [regex]::Matches($RawText, $resolvedPattern)
    if ($matches.Count -eq 0) { return @() }

    $extractedCodes = New-Object System.Collections.Generic.List[string]

    foreach ($m in $matches) {
        $parsedCode = ""
        if ($null -ne $Formatter) {
            $parsedCode = & $Formatter $m
        } else {
            $parsedCode = $m.Value.ToUpper().Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($parsedCode)) {
            $extractedCodes.Add($parsedCode)
        }
    }

    return $extractedCodes.ToArray()
}

# ==============================================================================
# DEFERRED KEY STRATEGY & HELPER FUNCTIONS
# ==============================================================================

function Get-CodeType ([string]$code) {
    if ([string]::IsNullOrWhiteSpace($code)) { return "RAW" }
    
    if ($code.Contains("-")) {
        return "GG" # Game Genie
    }
    
    $cleanSplit = $code -split '\s+'
    if ($cleanSplit[-1].Length -eq 4) {
        return "SHORT"
    }
    
    return "RAW"
}

function Add-CheatToDatabase {
    param (
        [string]$Description,
        [string[]]$Codes,
        [string]$TypeOverride = $null
    )
    if ($null -eq $Codes -or $Codes.Count -eq 0) { return }

    $detectedType = if ([string]::IsNullOrEmpty($TypeOverride)) { Get-CodeType $Codes[0] } else { $TypeOverride }

    if (-not $script:CheatDatabase.Contains($Description)) {
        $script:CheatDatabase[$Description] = [PSCustomObject]@{
            BaseDesc = $Description
            CodeType = $detectedType
            Codes    = [System.Collections.Generic.List[string]]::new([string[]]$Codes)
        }
        return
    }

    $existingEntry = $script:CheatDatabase[$Description]

    if ($existingEntry.CodeType -eq $detectedType) {
        foreach ($c in $Codes) {
            if (-not $existingEntry.Codes.Contains($c)) {
                $existingEntry.Codes.Add($c)
            }
        }
        return
    }

    $typeKey = "$Description [$detectedType]"

    if (-not $script:CheatDatabase.Contains($typeKey)) {
        $script:CheatDatabase[$typeKey] = [PSCustomObject]@{
            BaseDesc = $typeKey
            CodeType = $detectedType
            Codes    = [System.Collections.Generic.List[string]]::new([string[]]$Codes)
        }
    } else {
        foreach ($c in $Codes) {
            if (-not $script:CheatDatabase[$typeKey].Codes.Contains($c)) {
                $script:CheatDatabase[$typeKey].Codes.Add($c)
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
    $script:lstCheats.UnregisterAllEventsOnIndexChange()
    $script:lstCheats.Items.Clear()
    foreach ($key in $script:CheatDatabase.Keys) {
        [void]$script:lstCheats.Items.Add($key)
    }
    $script:IsDirty = $false
    if ($script:lstCheats.Items.Count -gt 0) {
        $script:LastSelectedIndex = 0
        $script:lstCheats.SelectedIndex = 0
        $selectedDesc = $script:lstCheats.SelectedItem.ToString()

        $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $flattenedCodes = @($script:CheatDatabase[$selectedDesc].Codes)
        $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $flattenedCodes)
        $script:IsDirty = $false
        $script:txtEditor.Add_TextChanged($script:TextChangeHandler)
    } else {
        $script:LastSelectedIndex = -1
        $script:txtEditor.Clear()
    }
    Update-UIState
    $script:lstCheats.RegisterEventsOnIndexChange()
}

function Write-Log ([string]$message, [string]$level = "INFO") {
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = "[$timestamp] [$level] $message"
    
    if ($null -eq $script:txtStatusLog) { return }

    if ($script:txtStatusLog.InvokeRequired) {
        $script:txtStatusLog.Invoke([Action]{
            $script:txtStatusLog.AppendText($logEntry + [Environment]::NewLine)
        })
    } else {
        $script:txtStatusLog.AppendText($logEntry + [Environment]::NewLine)
    }
}

function Save-CurrentSelectionIfDirty {
    if ($script:IsDirty -and $script:LastSelectedIndex -ge 0 -and $script:LastSelectedIndex -lt $script:lstCheats.Items.Count) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Save changes to the current group before proceeding?", "Unsaved Progress", "YesNoCancel", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            $selectedDesc = $script:lstCheats.Items[$script:LastSelectedIndex].ToString()
            $selectedModule = $script:cmbInputModule.SelectedItem.ToString()
            $targetModName = if ($selectedModule -eq "RetroArch (Global)") { $script:cmbTargetRegex.SelectedItem.ToString() } else { $null }
            $module = $script:InputModules[$selectedModule]

            $parseFunc = if ($selectedModule -eq "RetroArch (Global)") {
                { param($text) & $module.ParseFunc $text $targetModName }
            } else {
                $module.ParseFunc
            }

            $cleanCodes = & $parseFunc $script:txtEditor.Text
            $updatedCodes = New-Object System.Collections.Generic.List[string]
            if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
                $updatedCodes.AddRange([string[]]$cleanCodes)
            }
            
            $script:CheatDatabase[$selectedDesc].Codes = $updatedCodes
            if ($updatedCodes.Count -gt 0) {
                $script:CheatDatabase[$selectedDesc].CodeType = Get-CodeType $updatedCodes[0]
            }

            $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
            $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $updatedCodes)
            $script:txtEditor.Add_TextChanged($script:TextChangeHandler)
        }
        $script:IsDirty = $false
    }
    return $true
}

# --- Shared Engines ---
function Import-RetroArchChtEngine ([string]$filePath, [scriptblock]$parseFunc) {
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
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
        [System.Windows.Forms.Application]::DoEvents()
        $descText = $descMap[$k]
        if (-not $codeMap.Contains($k)) {
            if ($mergeCategories) { $categoryHeader = $descText }
            continue
        }

        $cleanCodes = & $parseFunc $codeMap[$k]
        if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }

        $finalTitle = if ($mergeCategories) { "$categoryHeader - $descText" } else { $descText }
        $finalTitle = $finalTitle.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

        Add-CheatToDatabase -Description $finalTitle -Codes $cleanCodes
    }
}

function Import-VbaCltEngine ([string]$filePath, [scriptblock]$parseFunc) {
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
    # Group codes by description to prevent Add-CheatToDatabase from splitting or dropping lines
    $groupedCheats = [ordered]@{ }

    for ($i = 0; $i -lt $totalRecords; $i++) {
        if ($i % 50 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
        # Fixed boundary check: stop only if we don't have enough bytes left for a full record
        if (($offset + $stride) -gt $bytes.Length) { break }

        $codeStringOffset = if ($stride -eq 80) { $offset + 28 } else { $offset + 32 }
        $descStringOffset = if ($stride -eq 80) { $offset + 48 } else { $offset + 52 }

        $rawCode = [System.Text.Encoding]::ASCII.GetString($bytes, $codeStringOffset, 20).Split("`0")[0]
        $rawDesc = [System.Text.Encoding]::ASCII.GetString($bytes, $descStringOffset, 32).Split("`0")[0]

        $cleanDesc = $rawDesc.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($cleanDesc)) { $cleanDesc = "Unassigned Code Block" }

        $cleanCodes = & $parseFunc $rawCode
        if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
            if (-not $groupedCheats.Contains($cleanDesc)) {
                $groupedCheats[$cleanDesc] = New-Object System.Collections.Generic.List[string]
            }
            foreach ($c in $cleanCodes) {
                [void]$groupedCheats[$cleanDesc].Add($c)
            }
        }

        $offset += $stride
    }

    # Commit full aggregated code blocks into the cheat database
    foreach ($desc in $groupedCheats.Keys) {
        Add-CheatToDatabase -Description $desc -Codes $groupedCheats[$desc].ToArray()
    }
}

function Import-MyBoyChtEngine ([string]$filePath, [scriptblock]$parseFunc) {
    try {
        [xml]$xml = Get-Content $filePath -ErrorAction Stop
        if ($null -eq $xml.cheats -or $null -eq $xml.cheats.cheat) { return }

        $cbCheats = $xml.cheats.cheat | Where-Object { $_.type -eq 'cb' }

        foreach ($cheat in $cbCheats) {
            $cleanDesc = $cheat.name.Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($cleanDesc)) { $cleanDesc = "Unassigned Code Block" }
            if ($cleanDesc -eq "M") { $cleanDesc = "[M] Must Be On" }

            $rawCodeBlock = [string]::Join(" ", $cheat.code)
            $normalizedCodes = & $parseFunc $rawCodeBlock

            if ($null -eq $normalizedCodes -or $normalizedCodes.Count -eq 0) { continue }

            Add-CheatToDatabase -Description $cleanDesc -Codes $normalizedCodes
        }
    } catch {
        throw "Failed parsing MyBoy XML target: $_"
    }
}

function Import-KronosYctEngine ([string]$filePath, [scriptblock]$parseFunc) {
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($bytes.Length -lt 8) { return }

    $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
    if ($magic -ne "YCHT") { return }

    $totalRecords = [int]$bytes[7]
    $offset = 8

    $intermediateList = New-Object System.Collections.Generic.List[PSCustomObject]

    for ($i = 0; $i -lt $totalRecords; $i++) {
        if ($offset + 13 -gt $bytes.Length) { break }

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
        $nameLength = [Math]::Max(1, [int]$nameLengthByte - 1)

        $descOffset = $offset + 13
        if ($descOffset + $nameLength + 5 -gt $bytes.Length) { break }

        $rawDesc = [System.Text.Encoding]::ASCII.GetString($bytes, $descOffset, $nameLength).Split("`0")[0]

        $intermediateList.Add([PSCustomObject]@{
            RawDesc = $rawDesc
            RawCode = $rawCodeString
        })

        $offset += 12 + 1 + $nameLength + 5
    }

    foreach ($item in $intermediateList) {
        $cleanCodes = & $parseFunc $item.RawCode
        if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }

        $finalTitle = $item.RawDesc.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

        Add-CheatToDatabase -Description $finalTitle -Codes $cleanCodes
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
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}' -replace '[:\+]', ' '
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "AddressAndValue" -Formatter {
        param($m) "$($m.Groups[1].Value.ToUpper()) $($m.Groups[2].Value.ToUpper())"
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $sniffLines = ""
    if (Test-Path $filePath) {
        $sniffLines = [System.IO.File]::ReadLines($filePath, [System.Text.Encoding]::UTF8) | Select-Object -First 3
        $sniffLines = [string]::Join(" ", $sniffLines).Trim()
    }

    if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
        Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
    } else {
        Import-KronosYctEngine -filePath $filePath -parseFunc $parseFunc
    }
}

Register-OutputModule -Name "Kronos (.yct)" -Filter "Kronos Cheat Files (*.yct)|*.yct" -ExportFunc {
    param([string]$filePath)
    $stream = $null
    $writer = $null
    try {
        if (Test-Path $filePath) { Remove-Item $filePath -Force }

        $stream = [System.IO.File]::Create($filePath)
        $writer = New-Object System.IO.BinaryWriter($stream)

        $writer.Write([byte]0x59); $writer.Write([byte]0x43); $writer.Write([byte]0x48); $writer.Write([byte]0x54)
        $writer.Write([byte]0x00); $writer.Write([byte]0x00); $writer.Write([byte]0x00)

        $totalFlattenedCheats = 0
        foreach ($key in $script:CheatDatabase.Keys) {
            foreach ($codeItem in $script:CheatDatabase[$key].Codes) {
                if ($codeItem -match '^[Dd13][0-9A-Fa-f]{7}') { $totalFlattenedCheats++ }
            }
        }
        $writer.Write([byte]$totalFlattenedCheats)

        foreach ($desc in $script:CheatDatabase.Keys) {
            $cnam = [System.Text.RegularExpressions.Regex]::Replace($desc, '[^\x20-\x7E]', '')
            if ($cnam.Length -gt 255) { $cnam = $cnam.Substring(0, 255) }
            
            $chdgCount = [byte]($cnam.Length + 1)
            $cnamBytes = [System.Text.Encoding]::ASCII.GetBytes($cnam)

            foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
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
    } finally {
        if ($null -ne $writer) { $writer.Close(); $writer.Dispose() }
        if ($null -ne $stream) { $stream.Close(); $stream.Dispose() }
    }
}

# --- GAME BOY ADVANCE MODULES ---
Register-InputModule -Name "Game Boy Advance / GBA" -Filter "GBA Cheat Files (*.cht;*.clt)|*.cht;*.clt" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}' -replace '[:\+]', ' '
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "AddressAndValue" -Formatter {
        param($m) "$($m.Groups[1].Value.ToUpper()) $($m.Groups[2].Value.ToUpper())"
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $sniffLines = ""
    if (Test-Path $filePath) {
        $sniffLines = [System.IO.File]::ReadLines($filePath, [System.Text.Encoding]::UTF8) | Select-Object -First 3
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
            if ($null -ne $stream) { $stream.Close(); $stream.Dispose() }
        }

        if ($bytesRead -ge 12) {
            $hexSignature = [string]::Join(" ", ($buffer | ForEach-Object { "{0:X2}" -f $_ })).Trim()
            if ($hexSignature -imatch '^01 00 00 00 (01|00) 00 00 00 [0-9A-Fa-f]{2} 00 00 00') {
                Import-VbaCltEngine -filePath $filePath -parseFunc $parseFunc
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
        $writer = New-Object System.IO.BinaryWriter($stream)

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

        foreach ($desc in $script:CheatDatabase.Keys) {
            $safeDesc = [System.Text.RegularExpressions.Regex]::Replace($desc, '[^\x20-\x7E]', '')
            $descBytes = [System.Text.Encoding]::ASCII.GetBytes($safeDesc.PadRight(32, "`0"))
            if ($descBytes.Length -gt 32) { $descBytes = $descBytes[0..31] }

            $dataLinesRemaining = 0
            $isSlideNextLine = $false

            foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
                $parts = $codeItem -split '\s+'
                if ($parts.Count -lt 2) { continue }
                
                $part1 = $parts[0].ToUpper().PadRight(8, '0').Substring(0,8)
                $part2 = $parts[1].ToUpper().PadRight(4, '0').Substring(0,4)
                $ctyp = $part1.Substring(0, 1)

                $cd8Bytes = New-Object byte[] 4
                for($i=0; $i -lt 4; $i++) { $cd8Bytes[$i] = [System.Convert]::ToByte($part1.Substring((6 - $i*2), 2), 16) }

                $part1Zeroed = "0" + $part1.Substring(1)
                $cd8zBytes = New-Object byte[] 4
                for($i=0; $i -lt 4; $i++) { $cd8zBytes[$i] = [System.Convert]::ToByte($part1Zeroed.Substring((6 - $i*2), 2), 16) }

                $cd4Bytes = New-Object byte[] 2
                for($i=0; $i -lt 2; $i++) { $cd4Bytes[$i] = [System.Convert]::ToByte($part2.Substring((2 - $i*2), 2), 16) }

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
        if ($null -ne $writer) { $writer.Close(); $writer.Dispose() }
        if ($null -ne $stream) { $stream.Close(); $stream.Dispose() }
    }
}

# --- SNES MODULES ---
Register-InputModule -Name "Super Nintendo / SNES" -Filter "SNES Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock)
    Invoke-UniversalRegexParser -RawText $inputBlock -PatternKey "SnesCombined" -Formatter {
        param($m) $m.Value.ToUpper().Replace("=", "")
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
    $rawCheats = New-Object System.Collections.Generic.List[PSCustomObject]
    $currentBlock = $null

    foreach ($line in $lines) {
        if ($line -match '^\s*name:\s*(.*)') {
            $rawDesc = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($rawDesc)) { $rawDesc = "Unassigned Code Block" }
            $currentBlock = [PSCustomObject]@{ Desc = $rawDesc; CodeLines = New-Object System.Collections.Generic.List[string] }
            $rawCheats.Add($currentBlock)
        }
        elseif ($line -match '^\s*code:\s*(.*)') {
            if ($null -ne $currentBlock) {
                $currentBlock.CodeLines.Add($Matches[1].Trim())
            }
        }
    }

    foreach ($block in $rawCheats) {
        if ($block.CodeLines.Count -eq 0) { continue }

        $parsedBlockCodes = New-Object System.Collections.Generic.List[string]
        $isBlockCorrupt = $false

        foreach ($line in $block.CodeLines) {
            $cleanLine = & $parseFunc $line
            if ($null -eq $cleanLine -or $cleanLine.Count -eq 0) {
                $isBlockCorrupt = $true
                break
            }
            $parsedBlockCodes.AddRange([string[]]$cleanLine)
        }

        if (-not $isBlockCorrupt -and $parsedBlockCodes.Count -eq $block.CodeLines.Count) {
            Add-CheatToDatabase -Description $block.Desc -Codes $parsedBlockCodes.ToArray()
        } else {
            Write-Log("SNES Import: Discarded block '$($block.Desc)' due to corrupted code line.", "WARN")
        }
    }
}

Register-OutputModule -Name "Snes9x (.cht)" -Filter "Snes9x Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    foreach ($desc in $script:CheatDatabase.Keys) {
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            $outputCode = $codeItem
            if ($outputCode.Length -eq 8 -and -not $outputCode.Contains("-")) {
                $outputCode = $outputCode.Substring(0, 6) + "=" + $outputCode.Substring(6, 2)
            }
            [void]$sb.AppendLine("cheat`n  name: $desc`n  code: $outputCode`n")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# --- MASTER SYSTEM MODULES ---
Register-InputModule -Name "Sega Master System / SMS" -Filter "Master System Cheats (*.pat)|*.pat" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}'
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "SmsMdExtended"
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^([0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3})\s+(.*)') {
            $rawCode = $Matches[1].Trim()
            $desc = $Matches[2].Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($desc)) { $desc = "Unassigned Code Block" }

            $cleanCodes = & $parseFunc $rawCode
            if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }

            Add-CheatToDatabase -Description $desc -Codes $cleanCodes
        }
    }
}

Register-OutputModule -Name "md.emu SMS (.pat)" -Filter "md.emu Cheat Files (*.pat)|*.pat" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    foreach ($desc in $script:CheatDatabase.Keys) {
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine("$codeItem`t$desc")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# --- PLAYSTATION / PSX MODULES ---
Register-InputModule -Name "Sony PlayStation / PSX (PCSXR)" -Filter "PCSXR Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}' -replace '[:\+]', ' '
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "AddressAndValue" -Formatter {
        param($m) "$($m.Groups[1].Value.ToUpper()) $($m.Groups[2].Value.ToUpper())"
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
    $blocks = New-Object System.Collections.Generic.List[psobject]
    $currentHeader = "Unassigned Code Block"
    $currentCodes = New-Object System.Collections.Generic.List[string]
    $hasOrphans = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^\[(.*)\]') {
            if ($currentCodes.Count -eq 0 -and $currentHeader -ne "Unassigned Code Block") { $hasOrphans = $true }
            if ($currentCodes.Count -gt 0) {
                $blocks.Add([PSCustomObject]@{ Header = $currentHeader; Codes = $currentCodes.ToArray() })
                $currentCodes = New-Object System.Collections.Generic.List[string]
            }
            $extracted = $Matches[1].Replace("\", ", ").Replace("'", "").Trim() -replace '^\*\s*', ''
            $currentHeader = if ([string]::IsNullOrWhiteSpace($extracted)) { "Unassigned Code Block" } else { $extracted.Trim() }
        } else {
            $currentCodes.Add($trimmed)
        }
    }
    if ($currentCodes.Count -gt 0) {
        $blocks.Add([PSCustomObject]@{ Header = $currentHeader; Codes = $currentCodes.ToArray() })
    } elseif ($currentHeader -ne "Unassigned Code Block") { $hasOrphans = $true }

    $mergeCategories = $false
    if ($hasOrphans) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Cheat descriptions found without matching codes.`n`nTreat empty labels as parent categories and group subsequent blocks?", "Category Layout Detected", "YesNo", "Question")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { $mergeCategories = $true }
    }

    $categoryHeader = "Unassigned Code Block"
    foreach ($block in $blocks) {
        $rawHeader = $block.Header
        $rawCodes  = $block.Codes

        if ($mergeCategories -and $rawCodes.Count -eq 0) { 
            $categoryHeader = $rawHeader
            continue 
        }

        $validatedCodes = New-Object System.Collections.Generic.List[string]
        $hasCorruptLine = $false

        foreach ($codeLine in $rawCodes) {
            $clean = & $parseFunc $codeLine
            if ($null -eq $clean -or $clean.Count -eq 0) {
                $hasCorruptLine = $true
                break
            }
            $validatedCodes.AddRange([string[]]$clean)
        }

        if ($hasCorruptLine) {
            Write-Log("PSX Import: Dropped block '$rawHeader' due to incomplete/corrupt code line.", "WARN")
            continue
        }

        $finalTitle = if ($mergeCategories -and $categoryHeader -ne "Unassigned Code Block") { 
            "$categoryHeader - $rawHeader" 
        } else { 
            $rawHeader 
        }
        
        Add-CheatToDatabase -Description $finalTitle -Codes $validatedCodes.ToArray()
    }
}

Register-InputModule -Name "Sony PlayStation / PSX (ePSXe)" -Filter "ePSXe Cheat Files (*.txt)|*.txt" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}' -replace '[:\+]', ' '
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "AddressAndValue" -Formatter {
        param($m) "$($m.Groups[1].Value.ToUpper()) $($m.Groups[2].Value.ToUpper())"
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
    $blocks = New-Object System.Collections.Generic.List[psobject]
    $currentHeader = "Unassigned Code Block"
    $currentCodes = New-Object System.Collections.Generic.List[string]
    $hasOrphans = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^#(.*)') {
            if ($currentCodes.Count -eq 0 -and $currentHeader -ne "Unassigned Code Block") { $hasOrphans = $true }
            if ($currentCodes.Count -gt 0) {
                $blocks.Add([PSCustomObject]@{ Header = $currentHeader; Codes = $currentCodes.ToArray() })
                $currentCodes = New-Object System.Collections.Generic.List[string]
            }
            $currentHeader = $Matches[1].Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($currentHeader)) { $currentHeader = "Unassigned Code Block" }
        } else {
            $currentCodes.Add($trimmed)
        }
    }
    if ($currentCodes.Count -gt 0) {
        $blocks.Add([PSCustomObject]@{ Header = $currentHeader; Codes = $currentCodes.ToArray() })
    } elseif ($currentHeader -ne "Unassigned Code Block") { $hasOrphans = $true }

    $mergeCategories = $false
    if ($hasOrphans) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Cheat descriptions found without matching codes.`n`nTreat empty labels as parent categories and group subsequent blocks?", "Category Layout Detected", "YesNo", "Question")
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { $mergeCategories = $true }
    }

    $categoryHeader = "Unassigned Code Block"
    foreach ($block in $blocks) {
        $rawHeader = $block.Header
        $rawCodes  = $block.Codes

        if ($mergeCategories -and $rawCodes.Count -eq 0) { 
            $categoryHeader = $rawHeader
            continue 
        }

        $validatedCodes = New-Object System.Collections.Generic.List[string]
        $hasCorruptLine = $false

        foreach ($codeLine in $rawCodes) {
            $clean = & $parseFunc $codeLine
            if ($null -eq $clean -or $clean.Count -eq 0) {
                $hasCorruptLine = $true
                break
            }
            $validatedCodes.AddRange([string[]]$clean)
        }

        if ($hasCorruptLine) {
            Write-Log("PSX Import: Dropped block '$rawHeader' due to incomplete/corrupt code line.", "WARN")
            continue
        }

        $finalTitle = if ($mergeCategories -and $categoryHeader -ne "Unassigned Code Block") { 
            "$categoryHeader - $rawHeader" 
        } else { 
            $rawHeader 
        }
        
        Add-CheatToDatabase -Description $finalTitle -Codes $validatedCodes.ToArray()
    }
}

Register-OutputModule -Name "PCSXR (.cht)" -Filter "PCSXR Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    foreach ($desc in $script:CheatDatabase.Keys) {
        if ($script:CheatDatabase[$desc].Codes.Count -eq 0) { continue }
        [void]$sb.AppendLine("[$desc]")
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

Register-OutputModule -Name "ePSXe (.txt)" -Filter "ePSXe Cheat Files (*.txt)|*.txt" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    foreach ($desc in $script:CheatDatabase.Keys) {
        if ($script:CheatDatabase[$desc].Codes.Count -eq 0) { continue }
        [void]$sb.AppendLine("#$desc")
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# --- GBC MODULES ---
Register-InputModule -Name "Game Boy / GBC" -Filter "GBC Cheat Files (*.gbcht)|*.gbcht" -ParseFunc {
    param([string]$inputBlock)
    Invoke-UniversalRegexParser -RawText $inputBlock -PatternKey "GbcCombined"
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $rawBytes = [System.IO.File]::ReadAllBytes($filePath)
    if ($rawBytes.Length -ge 4) {
        $totalRecords = $rawBytes[1]
        $offset = 3
        for ($i = 0; $i -lt $totalRecords; $i++) {
            if ($offset + 3 -gt $rawBytes.Length) { break }
            $status = $rawBytes[$offset]; $offset += 1
            $descLen = $rawBytes[$offset]; $offset += 1
            $nullSep = $rawBytes[$offset]; $offset += 1

            if ($offset + $descLen -gt $rawBytes.Length) { break }
            $rawDesc = [System.Text.Encoding]::ASCII.GetString($rawBytes, $offset, $descLen)
            $offset += $descLen

            if ($offset + 1 -gt $rawBytes.Length) { break }
            $prefixByte = $rawBytes[$offset]; $offset += 1
            $codeLen = if ($prefixByte -eq 0x0b) { 11 } else { 8 }

            if ($offset + $codeLen -gt $rawBytes.Length) { break }
            $rawCode = [System.Text.Encoding]::ASCII.GetString($rawBytes, $offset, $codeLen)
            $offset += $codeLen

            $clean = & $parseFunc $rawCode
            if ($null -ne $clean -and $clean.Count -gt 0) {
                $finalTitle = $rawDesc.Replace("'", "").Trim()
                if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }
                
                Add-CheatToDatabase -Description $finalTitle -Codes $clean
            }
        }
    }
}

Register-OutputModule -Name "GBC.emu (.gbcht)" -Filter "GBC Cheat Files (*.gbcht)|*.gbcht" -ExportFunc {
    param([string]$filePath)
    $stream = [System.IO.File]::Create($filePath)
    $writer = New-Object System.IO.BinaryWriter($stream)
    try {
        $total = 0
        foreach ($d in $script:CheatDatabase.Keys) { $total += $script:CheatDatabase[$d].Codes.Count }
        $writer.Write([byte]0x00)
        $writer.Write([byte][Math]::Min($total, 255))
        $writer.Write([byte]0x00)

        $processed = 0
        foreach ($desc in $script:CheatDatabase.Keys) {
            if ($processed -ge 255) { break }
            $safeDesc = [regex]::Replace($desc, '[^\x20-\x7E]', '')
            $descBytes = [System.Text.Encoding]::ASCII.GetBytes($safeDesc)
            foreach ($code in $script:CheatDatabase[$desc].Codes) {
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
    } finally { $writer.Close(); $stream.Close() }
}

# --- MEGA DRIVE / MD MODULES ---
Register-InputModule -Name "Sega Mega Drive / MD" -Filter "MD Cheats (*.pat)|*.pat" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}'
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "SmsMdExtended"
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
    foreach ($line in $lines) {
        if ($line -match '^(([0-9A-Fa-f]{6}:[0-9A-Fa-f]{4})|([0-9A-Z]{4}-[0-9A-Z]{4}))\s+(.*)') {
            $clean = & $parseFunc $Matches[1]
            $desc = $Matches[4].Trim().Replace("'", "")
            if ([string]::IsNullOrWhiteSpace($desc)) { $desc = "Unassigned Code Block" }
            if ($null -ne $clean) {
                Add-CheatToDatabase -Description $desc -Codes $clean
            }
        }
    }
}

Register-OutputModule -Name "md.emu MD (.pat)" -Filter "md.emu Cheat Files (*.pat)|*.pat" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    foreach ($desc in $script:CheatDatabase.Keys) {
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine("$codeItem`t$desc")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# --- NINTENDO DS MODULES ---
Register-InputModule -Name "Nintendo DS" -Filter "NDS Cheat Files (*.mch)|*.mch" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}' -replace '[:\+]', ' '
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "AddressAndValue" -Formatter {
        param($m) "$($m.Groups[1].Value.ToUpper()) $($m.Groups[2].Value.ToUpper())"
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
    $currentDesc = "Unassigned Code Block"
    $currentLines = New-Object System.Collections.Generic.List[string]

    function Commit-DSBlock {
        param($desc, $lines, $parseFunc)
        if ($lines.Count -eq 0) { return }

        $validCodes = New-Object System.Collections.Generic.List[string]
        foreach ($l in $lines) {
            $res = & $parseFunc $l
            if ($null -eq $res -or $res.Count -eq 0) {
                Write-Log("NDS Import: Corrupted line in '$desc'. Dropping entire block.", "WARN")
                return
            }
            $validCodes.AddRange([string[]]$res)
        }

        Add-CheatToDatabase -Description $desc -Codes $validCodes.ToArray()
    }

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^CODE\s+\d+\s*(.*)') {
            Commit-DSBlock -desc $currentDesc -lines $currentLines -parseFunc $parseFunc
            $currentDesc = $Matches[1].Trim()
            $currentLines.Clear()
            continue
        }

        if ($trimmed -notmatch '^CAT\s+') {
            $currentLines.Add($trimmed)
        }
    }
    Commit-DSBlock -desc $currentDesc -lines $currentLines -parseFunc $parseFunc
}

Register-OutputModule -Name "melonDS (.mch)" -Filter "melonDS Cheat Files (*.mch)|*.mch" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("CAT Cheats")
    foreach ($desc in $script:CheatDatabase.Keys) {
        [void]$sb.AppendLine("CODE 0 $desc")
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# --- NES MODULES ---
Register-InputModule -Name "Nintendo NES" -Filter "NES Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock)
    Invoke-UniversalRegexParser -RawText $inputBlock -PatternKey "NesCombined"
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    
    $sniffLines = ""
    if (Test-Path $filePath) {
        $sniffLines = [System.IO.File]::ReadLines($filePath, [System.Text.Encoding]::UTF8) | Select-Object -First 3
        $sniffLines = [string]::Join(" ", $sniffLines).Trim()
    }

    if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
        Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
    }
    else {
        $lines = [System.IO.File]::ReadAllLines($filePath, [System.Text.Encoding]::UTF8)
        foreach ($line in $lines) {
            if ($line -match '^(?:SC|C|S)?:?([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?:(.*)$') {
                $codeStr = "$($Matches[1]):$($Matches[2])" + $(if ($Matches[3]) { ":$($Matches[3])" } else { "" })
                $clean = & $parseFunc $codeStr
                $desc = $Matches[4].Replace("'", "").Trim()
                if ([string]::IsNullOrWhiteSpace($desc)) { $desc = "Unassigned Code Block" }
                if ($null -ne $clean) {
                    Add-CheatToDatabase -Description $desc -Codes $clean
                }
            }
        }
    }
}

Register-OutputModule -Name "nes.emu (.cht)" -Filter "nes.emu Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    foreach ($desc in $script:CheatDatabase.Keys) {
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine(":$codeItem`:$desc")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# --- GLOBAL RETROARCH MODULES ---
Register-InputModule -Name "RetroArch (Global)" -Filter "RetroArch Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock, [string]$targetModule)
    if ([string]::IsNullOrEmpty($targetModule)) { return $null }
    $parseFunc = $script:InputModules[$targetModule].ParseFunc
    return & $parseFunc $inputBlock
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
}

Register-OutputModule -Name "RetroArch (.cht)" -Filter "RetroArch Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("cheats = $($script:CheatDatabase.Count)")
    [void]$sb.AppendLine("")
    $idx = 0
    foreach ($desc in $script:CheatDatabase.Keys) {
        $joinedCodes = [string]::Join("+", $script:CheatDatabase[$desc].Codes)
        [void]$sb.AppendLine("cheat${idx}_desc = `"$desc`"")
        [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
        [void]$sb.AppendLine("cheat${idx}_enable = false")
        [void]$sb.AppendLine("")
        $idx++
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# ==============================================================================
# MAIN GUI FORM & CONTROLS
# ==============================================================================

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "Universal Multi-Platform Cheat Manager"
$script:form.Size = New-Object System.Drawing.Size(700, 620)
$script:form.StartPosition = "CenterScreen"

# --- Import Section ---
$script:lblInput = New-Object System.Windows.Forms.Label
$script:lblInput.Text = "Input Module:"
$script:lblInput.Location = New-Object System.Drawing.Point(20, 15)
$script:lblInput.Size = New-Object System.Drawing.Size(80, 20)
$script:form.Controls.Add($script:lblInput)

$script:cmbInputModule = New-Object System.Windows.Forms.ComboBox
$script:cmbInputModule.DropDownStyle = "DropDownList"
$script:cmbInputModule.Location = New-Object System.Drawing.Point(105, 12)
$script:cmbInputModule.Size = New-Object System.Drawing.Size(150, 25)
foreach ($key in $script:InputModules.Keys) { [void]$script:cmbInputModule.Items.Add($key) }
$script:form.Controls.Add($script:cmbInputModule)

# --- Dynamic Target Regex Dropdown ---
$script:lblTargetRegex = New-Object System.Windows.Forms.Label
$script:lblTargetRegex.Text = "Target System Regex:"
$script:lblTargetRegex.Location = New-Object System.Drawing.Point(385, 15)
$script:lblTargetRegex.Size = New-Object System.Drawing.Size(115, 20)
$script:lblTargetRegex.Visible = $false
$script:form.Controls.Add($script:lblTargetRegex)

$script:cmbTargetRegex = New-Object System.Windows.Forms.ComboBox
$script:cmbTargetRegex.DropDownStyle = "DropDownList"
$script:cmbTargetRegex.Location = New-Object System.Drawing.Point(520, 12)
$script:cmbTargetRegex.Size = New-Object System.Drawing.Size(150, 25)
foreach ($key in $script:InputModules.Keys) {
    if ($key -ne "RetroArch (Global)") { [void]$script:cmbTargetRegex.Items.Add($key) }
}
if ($script:cmbTargetRegex.Items.Count -gt 0) { $script:cmbTargetRegex.SelectedIndex = 0 }
$script:cmbTargetRegex.Visible = $false
$script:form.Controls.Add($script:cmbTargetRegex)

$script:btnImport = New-Object System.Windows.Forms.Button
$script:btnImport.Text = "Import File"
$script:btnImport.Location = New-Object System.Drawing.Point(265, 10)
$script:btnImport.Size = New-Object System.Drawing.Size(100, 28)
$script:form.Controls.Add($script:btnImport)

# --- Left-Side Controls ---
$script:lblList = New-Object System.Windows.Forms.Label
$script:lblList.Text = "Grouped Cheat Descriptions:"
$script:lblList.Location = New-Object System.Drawing.Point(20, 55)
$script:lblList.Size = New-Object System.Drawing.Size(200, 20)
$script:form.Controls.Add($script:lblList)

$script:lstCheats = New-Object System.Windows.Forms.ListBox
$script:lstCheats.Location = New-Object System.Drawing.Point(20, 75)
$script:lstCheats.Size = New-Object System.Drawing.Size(260, 350)
$script:form.Controls.Add($script:lstCheats)

$script:lstCheats | Add-Member -MemberType ScriptMethod -Name "UnregisterAllEventsOnIndexChange" -Value {
    $this.Remove_SelectedIndexChanged($script:ListSelectionHandler)
} -Force
$script:lstCheats | Add-Member -MemberType ScriptMethod -Name "RegisterEventsOnIndexChange" -Value {
    $this.Add_SelectedIndexChanged($script:ListSelectionHandler)
} -Force

$script:txtNewGroup = New-Object System.Windows.Forms.TextBox
$script:txtNewGroup.Location = New-Object System.Drawing.Point(20, 420)
$script:txtNewGroup.Size = New-Object System.Drawing.Size(100, 25)
$script:form.Controls.Add($script:txtNewGroup)

$script:btnNewGroup = New-Object System.Windows.Forms.Button
$script:btnNewGroup.Text = "Add"
$script:btnNewGroup.Location = New-Object System.Drawing.Point(125, 420)
$script:btnNewGroup.Size = New-Object System.Drawing.Size(40, 26)
$script:form.Controls.Add($script:btnNewGroup)

$script:btnMoveUp = New-Object System.Windows.Forms.Button
$script:btnMoveUp.Text = "▲"
$script:btnMoveUp.Location = New-Object System.Drawing.Point(170, 420)
$script:btnMoveUp.Size = New-Object System.Drawing.Size(35, 26)
$script:btnMoveUp.Enabled = $false
$script:form.Controls.Add($script:btnMoveUp)

$script:btnMoveDown = New-Object System.Windows.Forms.Button
$script:btnMoveDown.Text = "▼"
$script:btnMoveDown.Location = New-Object System.Drawing.Point(210, 420)
$script:btnMoveDown.Size = New-Object System.Drawing.Size(35, 26)
$script:btnMoveDown.Enabled = $false
$script:form.Controls.Add($script:btnMoveDown)

$script:btnDeleteGroup = New-Object System.Windows.Forms.Button
$script:btnDeleteGroup.Text = "❌"
$script:btnDeleteGroup.Location = New-Object System.Drawing.Point(250, 420)
$script:btnDeleteGroup.Size = New-Object System.Drawing.Size(30, 26)
$script:btnDeleteGroup.Enabled = $false
$script:form.Controls.Add($script:btnDeleteGroup)

# --- Right-Side Controls ---
$script:lblEditor = New-Object System.Windows.Forms.Label
$script:lblEditor.Text = "Codes in Selected Group (One per line):"
$script:lblEditor.Location = New-Object System.Drawing.Point(300, 55)
$script:lblEditor.Size = New-Object System.Drawing.Size(310, 20)
$script:form.Controls.Add($script:lblEditor)

$script:txtEditor = New-Object System.Windows.Forms.TextBox
$script:txtEditor.Multiline = $true
$script:txtEditor.ScrollBars = "Vertical"
$script:txtEditor.Font = New-Object System.Drawing.Font("Consolas", 10)
$script:txtEditor.Location = New-Object System.Drawing.Point(300, 75)
$script:txtEditor.Size = New-Object System.Drawing.Size(370, 370)
$script:txtEditor.Add_TextChanged($script:TextChangeHandler)
$script:form.Controls.Add($script:txtEditor)

$script:btnSaveGroup = New-Object System.Windows.Forms.Button
$script:btnSaveGroup.Text = "Update Current Group Modifications"
$script:btnSaveGroup.Location = New-Object System.Drawing.Point(400, 456)
$script:btnSaveGroup.Size = New-Object System.Drawing.Size(270, 30)
$script:btnSaveGroup.Enabled = $false
$script:form.Controls.Add($script:btnSaveGroup)

# --- Export Section ---
$script:lblOutput = New-Object System.Windows.Forms.Label
$script:lblOutput.Text = "Export To:"
$script:lblOutput.Location = New-Object System.Drawing.Point(20, 463)
$script:lblOutput.Size = New-Object System.Drawing.Size(65, 20)
$script:form.Controls.Add($script:lblOutput)

$script:cmbOutputModule = New-Object System.Windows.Forms.ComboBox
$script:cmbOutputModule.DropDownStyle = "DropDownList"
$script:cmbOutputModule.Location = New-Object System.Drawing.Point(85, 460)
$script:cmbOutputModule.Size = New-Object System.Drawing.Size(185, 25)
$script:form.Controls.Add($script:cmbOutputModule)

$script:btnExport = New-Object System.Windows.Forms.Button
$script:btnExport.Text = "Export File"
$script:btnExport.Location = New-Object System.Drawing.Point(280, 458)
$script:btnExport.Size = New-Object System.Drawing.Size(100, 28)
$script:form.Controls.Add($script:btnExport)

# --- Bottom Status Log ---
$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Text = "System Activity Log:"
$script:lblStatus.Location = New-Object System.Drawing.Point(20, 495)
$script:lblStatus.Size = New-Object System.Drawing.Size(150, 15)
$script:form.Controls.Add($script:lblStatus)

$script:txtStatusLog = New-Object System.Windows.Forms.TextBox
$script:txtStatusLog.Multiline = $true
$script:txtStatusLog.ReadOnly = $true
$script:txtStatusLog.ScrollBars = "Vertical"
$script:txtStatusLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$script:txtStatusLog.BackColor = [System.Drawing.Color]::White
$script:txtStatusLog.ForeColor = [System.Drawing.Color]::Black
$script:txtStatusLog.Location = New-Object System.Drawing.Point(20, 512)
$script:txtStatusLog.Size = New-Object System.Drawing.Size(650, 60)
$script:form.Controls.Add($script:txtStatusLog)

# ==============================================================================
# DYNAMIC INPUT/OUTPUT MODULE RELATIONSHIP LOGIC
# ==============================================================================

function Update-OutputModuleChoices {
    if ($null -eq $script:cmbInputModule -or $null -eq $script:cmbOutputModule) { return }
    if ($null -eq $script:cmbInputModule.SelectedItem) { return }

    $selectedInput = $script:cmbInputModule.SelectedItem.ToString()

    $script:cmbOutputModule.BeginUpdate()
    $script:cmbOutputModule.Items.Clear()

    if ($selectedInput -eq "RetroArch (Global)") {
        $script:lblTargetRegex.Visible = $true
        $script:cmbTargetRegex.Visible = $true
        $script:cmbTargetRegex.Enabled = $true

        $retroArchOutputKey = "RetroArch (.cht)"
        if ($script:OutputModules.Contains($retroArchOutputKey)) {
            [void]$script:cmbOutputModule.Items.Add($retroArchOutputKey)
        }

        if ($null -ne $script:cmbTargetRegex.SelectedItem) {
            $targetSys = $script:cmbTargetRegex.SelectedItem.ToString()
            $mappedOutputKey = $script:ModuleOutputMap[$targetSys]
            
            if ($null -ne $mappedOutputKey -and $script:OutputModules.Contains($mappedOutputKey)) {
                if (-not $script:cmbOutputModule.Items.Contains($mappedOutputKey)) {
                    [void]$script:cmbOutputModule.Items.Add($mappedOutputKey)
                }
            }
        }
        $script:cmbOutputModule.Enabled = $true
    } 
    else {
        $mappedOutputKey = $script:ModuleOutputMap[$selectedInput]
        
        if ($null -ne $mappedOutputKey -and $script:OutputModules.Contains($mappedOutputKey)) {
            [void]$script:cmbOutputModule.Items.Add($mappedOutputKey)
        }

        $retroArchOutputKey = "RetroArch (.cht)"
        if ($script:OutputModules.Contains($retroArchOutputKey) -and -not $script:cmbOutputModule.Items.Contains($retroArchOutputKey)) {
            [void]$script:cmbOutputModule.Items.Add($retroArchOutputKey)
        }

        if ($script:cmbOutputModule.Items.Count -gt 1) {
            $script:cmbOutputModule.Enabled = $true
        } else {
            $script:cmbOutputModule.Enabled = $false
        }

        $script:lblTargetRegex.Visible = $false
        $script:cmbTargetRegex.Visible = $false
        $script:cmbTargetRegex.Enabled = $false
    }

    if ($script:cmbOutputModule.Items.Count -gt 0 -and $script:cmbOutputModule.SelectedIndex -lt 0) {
        $script:cmbOutputModule.SelectedIndex = 0
    }
    $script:cmbOutputModule.EndUpdate()
}

$script:cmbInputModule.Add_SelectedIndexChanged({
    Update-OutputModuleChoices
})

$script:cmbTargetRegex.Add_SelectedIndexChanged({
    Update-OutputModuleChoices
})

if ($script:cmbInputModule.Items.Count -gt 0) {
    $script:cmbInputModule.SelectedIndex = 0
}

Update-OutputModuleChoices

# ==============================================================================
# EVENT HANDLERS
# ==============================================================================

$script:btnImport.Add_Click({
    if ($script:IsDirty) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved changes?", "Unsaved Progress", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) { return }
    }

    $selectedModule = $script:cmbInputModule.SelectedItem.ToString()
    $module = $script:InputModules[$selectedModule]

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = $module.Filter

    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
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
})

$script:btnExport.Add_Click({
    if ($script:CheatDatabase.Count -eq 0) {
        Write-Log("No cheats loaded to export.", "WARN")
        return
    }

    $selectedModule = $script:cmbOutputModule.SelectedItem.ToString()
    $module = $script:OutputModules[$selectedModule]

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = $module.Filter

    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            & $module.ExportFunc $sfd.FileName
            Write-Log("Export finished successfully!")
        } catch {
            Write-Log("Export error: $_", "ERROR")
        }
    }
})

$script:ListSelectionHandler = {
    if ($script:lstCheats.SelectedIndex -eq $script:LastSelectedIndex) { return }

    if ($script:IsDirty -and $script:LastSelectedIndex -ge 0 -and $script:LastSelectedIndex -lt $script:lstCheats.Items.Count) {
        $choice = [System.Windows.Forms.MessageBox]::Show("Discard unsaved group modifications?", "Unsaved Progress", "YesNo", "Warning")
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
            $script:lstCheats.UnregisterAllEventsOnIndexChange()
            $script:lstCheats.SelectedIndex = $script:LastSelectedIndex
            $script:lstCheats.RegisterEventsOnIndexChange()
            return
        }
    }

    if ($script:lstCheats.SelectedItem -ne $null) {
        $script:LastSelectedIndex = $script:lstCheats.SelectedIndex
        $selectedDesc = $script:lstCheats.SelectedItem.ToString()
        $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $flattenedCodes = @($script:CheatDatabase[$selectedDesc].Codes)
        $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $flattenedCodes)
        $script:IsDirty = $false
        $script:txtEditor.Add_TextChanged($script:TextChangeHandler)
    }
}
$script:lstCheats.RegisterEventsOnIndexChange()

$script:btnSaveGroup.Add_Click({
    if ($script:lstCheats.SelectedItem -eq $null) { return }
    $selectedDesc = $script:lstCheats.SelectedItem.ToString()

    $selectedModule = $script:cmbInputModule.SelectedItem.ToString()
    $targetModName = if ($selectedModule -eq "RetroArch (Global)") { $script:cmbTargetRegex.SelectedItem.ToString() } else { $null }
    $module = $script:InputModules[$selectedModule]

    $parseFunc = if ($selectedModule -eq "RetroArch (Global)") {
        { param($text) & $module.ParseFunc $text $targetModName }
    } else {
        $module.ParseFunc
    }

    $cleanCodes = & $parseFunc $script:txtEditor.Text
    $updatedCodes = New-Object System.Collections.Generic.List[string]
    if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
        $updatedCodes.AddRange([string[]]$cleanCodes)
    }
    
    $script:CheatDatabase[$selectedDesc].Codes = $updatedCodes
    if ($updatedCodes.Count -gt 0) {
        $script:CheatDatabase[$selectedDesc].CodeType = Get-CodeType $updatedCodes[0]
    }
    
    $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
    $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $updatedCodes)
    $script:txtEditor.Add_TextChanged($script:TextChangeHandler)
    
    $script:IsDirty = $false
    Write-Log("Group '$selectedDesc' data updated.")
})

$script:btnNewGroup.Add_Click({
    $newTitle = $script:txtNewGroup.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($newTitle)) { return }
    if ($script:CheatDatabase.Contains($newTitle)) {
        Write-Log("Group name '$newTitle' already exists.", "WARN")
        return
    }
    if (-not (Save-CurrentSelectionIfDirty)) { return }

    Add-CheatToDatabase -Description $newTitle -Codes @()
    $script:txtNewGroup.Clear()

    $script:lstCheats.UnregisterAllEventsOnIndexChange()
    [void]$script:lstCheats.Items.Add($newTitle)
    $script:lstCheats.SelectedIndex = $script:lstCheats.Items.Count - 1
    $script:LastSelectedIndex = $script:lstCheats.SelectedIndex

    $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
    $script:txtEditor.Clear()
    $script:IsDirty = $false
    $script:txtEditor.Add_TextChanged($script:TextChangeHandler)

    Update-UIState
    $script:lstCheats.RegisterEventsOnIndexChange()
    Write-Log("Added new group '$newTitle'.")
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
    $selectedDesc = $script:lstCheats.SelectedItem.ToString()

    if ([System.Windows.Forms.MessageBox]::Show("Delete group '$selectedDesc'?", "Confirm", "YesNo", "Warning") -eq "No") { return }

    $script:CheatDatabase.Remove($selectedDesc)
    $script:IsDirty = $false
    $script:lstCheats.UnregisterAllEventsOnIndexChange()
    $script:lstCheats.Items.RemoveAt($idx)

    if ($script:lstCheats.Items.Count -gt 0) {
        $newIdx = if ($idx -lt $script:lstCheats.Items.Count) { $idx } else { $script:lstCheats.Items.Count - 1 }
        $script:lstCheats.SelectedIndex = $newIdx
        $script:LastSelectedIndex = $newIdx
        $nextDesc = $script:lstCheats.SelectedItem.ToString()
        $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $flattenedCodes = @($script:CheatDatabase[$nextDesc].Codes)
        $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $flattenedCodes)
        $script:txtEditor.Add_TextChanged($script:TextChangeHandler)
    } else {
        $script:LastSelectedIndex = -1
        $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $script:txtEditor.Clear()
    }
    Update-UIState
    $script:lstCheats.RegisterEventsOnIndexChange()
    Write-Log("Deleted group '$selectedDesc'.")
})

function Move-CheatGroup ([int]$direction) {
    $idx = $script:lstCheats.SelectedIndex
    if ($idx -lt 0) { return }
    $targetIdx = $idx + $direction
    if ($targetIdx -lt 0 -or $targetIdx -ge $script:lstCheats.Items.Count) { return }

    if (-not (Save-CurrentSelectionIfDirty)) { return }

    $keys = New-Object System.Collections.Generic.List[string] ($script:CheatDatabase.Keys)
    $temp = $keys[$idx]
    $keys[$idx] = $keys[$targetIdx]
    $keys[$targetIdx] = $temp

    $newDb = [ordered]@{ }
    foreach ($k in $keys) { $newDb[$k] = $script:CheatDatabase[$k] }
    $script:CheatDatabase = $newDb

    $script:lstCheats.UnregisterAllEventsOnIndexChange()
    $script:lstCheats.Items.Clear()
    foreach ($k in $script:CheatDatabase.Keys) { [void]$script:lstCheats.Items.Add($k) }

    $script:lstCheats.SelectedIndex = $targetIdx
    $script:LastSelectedIndex = $targetIdx
    $script:IsDirty = $false
    $script:lstCheats.RegisterEventsOnIndexChange()
}

$script:btnMoveUp.Add_Click({ Move-CheatGroup -1 })
$script:btnMoveDown.Add_Click({ Move-CheatGroup 1 })

# Launch GUI Form Context
$script:form.ShowDialog()
