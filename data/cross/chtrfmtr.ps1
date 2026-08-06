Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================================================================
# GLOBAL DATA & STATE
# ==============================================================================
$script:CheatDatabase = [ordered]@{ }  # Key: String (Desc/Tag), Value: PSCustomObject @{ BaseDesc, CodeType, Codes }
$script:IsDirty = $false
$script:LastSelectedIndex = -1

# Enforce UTF8 globally for standard I/O operations under Wine
$script:Utf8Encoding = New-Object System.Text.UTF8Encoding($false)

# Registries to hold input/output parser & writer functions
$script:InputModules  = [ordered]@{ }
$script:OutputModules = [ordered]@{ }

# Centralized Compiled Regex Patterns Registry
$script:RegexPatterns = [ordered]@{
    "AddressAndValue"   = [regex]::new('([0-9A-Fa-f]{8})\s+([0-9A-Fa-f]{4,8})', 'Compiled,IgnoreCase')                     # PSX, NDS, Saturn, GBA
    "TripleGroupHyphen" = [regex]::new('([0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}-[0-9A-Fa-f]{3})', 'Compiled,IgnoreCase')            # GBC, SMS, Sega MD
    "SnesCombined"      = [regex]::new('([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}|[0-9A-Fa-f]{6}=[0-9A-Fa-f]{2}|[0-9A-Fa-f]{8})', 'Compiled,IgnoreCase') # SNES GG / PAR
    "SmsMdExtended"     = [regex]::new('([0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}-[0-9A-Fa-f?Xx]{3}|[0-9A-Fa-f]{6}:[0-9A-Fa-f]{4}|[0-9A-Z]{4}-[0-9A-Z]{4})', 'Compiled,IgnoreCase')
    "GbcCombined"       = [regex]::new('([0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}-[0-9A-Fa-f]{3}|[0-9A-Fa-f]{8})', 'Compiled,IgnoreCase') # GBC GG / Raw
    "NesCombined"       = [regex]::new('([A-Na-nO-Zo-z0-9]{6,8}|[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2})?)', 'Compiled,IgnoreCase') # NES GG / RAM
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
# UNIVERSAL REGEX PARSING ENGINE & HELPER
# ==============================================================================

function Invoke-UniversalRegexParser {
    param(
        [string]$RawText,
        $PatternKey, # Accepts string key or compiled [regex] object
        [scriptblock]$Formatter = $null
    )
    
    if ([string]::IsNullOrWhiteSpace($RawText)) { return @() }

    # Resolve from registry or use directly if already a [regex] instance
    $regexInstance = if ($script:RegexPatterns.Contains($PatternKey)) { 
        $script:RegexPatterns[$PatternKey] 
    } else { 
        $PatternKey -as [regex] 
    }
    
    if ($null -eq $regexInstance) { return @() }

    $matches = $regexInstance.Matches($RawText)
    if ($matches.Count -eq 0) { return @() }

    $extractedCodes = [System.Collections.Generic.List[string]]::new()

    foreach ($m in $matches) {
        $parsedCode = if ($null -ne $Formatter) {
            & $Formatter $m
        } else {
            $m.Value.ToUpper().Trim()
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
        return "GG"
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
    Disable-ListEvents
    $script:lstCheats.BeginUpdate()
    try {
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
        try {
            [void]$script:txtStatusLog.Invoke($logAction)
        } catch {
            $logAction.Invoke()
        }
    } else {
        $logAction.Invoke()
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
            $updatedCodes = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
                $updatedCodes.AddRange([string[]]$cleanCodes)
            }
            
            $script:CheatDatabase[$selectedDesc].Codes = $updatedCodes
            if ($updatedCodes.Count -gt 0) {
                $script:CheatDatabase[$selectedDesc].CodeType = Get-CodeType $updatedCodes[0]
            }

            $script:SuppressEvents = $true
            $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $updatedCodes)
            $script:SuppressEvents = $false
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

        $cleanCodes = & $parseFunc $codeMap[$k]
        if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }

        $finalTitle = if ($mergeCategories) { "$categoryHeader - $descText" } else { $descText }
        $finalTitle = $finalTitle.Replace("'", "").Trim()
        if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

        Add-CheatToDatabase -Description $finalTitle -Codes $cleanCodes
    }
}

function Import-VbaCltEngine ([string]$filePath, [scriptblock]$parseFunc) {
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::OpenRead($filePath)
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

        $groupedCheats = [ordered]@{ }

        for ($i = 0; $i -lt $totalRecords; $i++) {
            $recordStart = 12 + ($i * $stride)
            if (($recordStart + $stride) -gt $stream.Length) { break }

            $codeOffset = if ($stride -eq 80) { $recordStart + 28 } else { $recordStart + 32 }
            $descOffset = if ($stride -eq 80) { $recordStart + 48 } else { $recordStart + 52 }

            $stream.Position = $codeOffset
            $rawCode = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(20)).Split("`0")[0]

            $stream.Position = $descOffset
            $rawDesc = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(32)).Split("`0")[0]

            $cleanDesc = $rawDesc.Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($cleanDesc)) { $cleanDesc = "Unassigned Code Block" }

            $cleanCodes = & $parseFunc $rawCode
            if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
                if (-not $groupedCheats.Contains($cleanDesc)) {
                    $groupedCheats[$cleanDesc] = [System.Collections.Generic.List[string]]::new()
                }
                foreach ($c in $cleanCodes) {
                    [void]$groupedCheats[$cleanDesc].Add($c)
                }
            }
        }

        foreach ($desc in $groupedCheats.Keys) {
            Add-CheatToDatabase -Description $desc -Codes $groupedCheats[$desc].ToArray()
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Import-MyBoyChtEngine ([string]$filePath, [scriptblock]$parseFunc) {
    $reader = $null
    try {
        $settings = [System.Xml.XmlReaderSettings]::new()
        $settings.IgnoreComments = $true
        $settings.IgnoreWhitespace = $true
        
        $reader = [System.Xml.XmlReader]::Create($filePath, $settings)
        $xml = [xml]::new()
        $xml.Load($reader)

        if ($null -eq $xml.cheats -or $null -eq $xml.cheats.cheat) { return }

        $cbCheats = $xml.cheats.cheat | Where-Object { $null -ne $_ -and $_.type -eq 'cb' }

        foreach ($cheat in $cbCheats) {
            if ($null -eq $cheat.name) { continue }
            $cleanDesc = $cheat.name.Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($cleanDesc)) { $cleanDesc = "Unassigned Code Block" }

            $rawCodeBlock = [string]::Join(" ", $cheat.code)
            $normalizedCodes = & $parseFunc $rawCodeBlock

            if ($null -eq $normalizedCodes -or $normalizedCodes.Count -eq 0) { continue }

            Add-CheatToDatabase -Description $cleanDesc -Codes $normalizedCodes
        }
    } catch {
        throw "Failed parsing MyBoy XML target: $_"
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
}

function Import-KronosYctEngine ([string]$filePath, [scriptblock]$parseFunc) {
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::OpenRead($filePath)
        $reader = [System.IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 8) { return }

        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne "YCHT") { return }

        $stream.Position = 7
        $totalRecords = [int]$reader.ReadByte()

        $intermediateList = [System.Collections.Generic.List[PSCustomObject]]::new()

        for ($i = 0; $i -lt $totalRecords; $i++) {
            if ($stream.Position + 13 -gt $stream.Length) { break }

            $recordStart = $stream.Position
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

            $rawDesc = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes($nameLength)).Split("`0")[0]
            $reader.ReadBytes(5) | Out-Null

            $intermediateList.Add([PSCustomObject]@{
                RawDesc = $rawDesc
                RawCode = $rawCodeString
            })
        }

        foreach ($item in $intermediateList) {
            $cleanCodes = & $parseFunc $item.RawCode
            if ($null -eq $cleanCodes -or $cleanCodes.Count -eq 0) { continue }

            $finalTitle = $item.RawDesc.Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }

            Add-CheatToDatabase -Description $finalTitle -Codes $cleanCodes
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
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
        $sniffLines = [System.IO.File]::ReadLines($filePath, $script:Utf8Encoding) | Select-Object -First 3
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
        $writer = [System.IO.BinaryWriter]::new($stream)

        $writer.Write([byte[]]@(0x59, 0x43, 0x48, 0x54, 0x00, 0x00, 0x00))

        $totalFlattenedCheats = 0
        foreach ($key in $script:CheatDatabase.Keys) {
            foreach ($codeItem in $script:CheatDatabase[$key].Codes) {
                if ($codeItem -match '^[Dd13][0-9A-Fa-f]{7}') { $totalFlattenedCheats++ }
            }
        }
        $writer.Write([byte]$totalFlattenedCheats)

        foreach ($desc in $script:CheatDatabase.Keys) {
            $cnam = [regex]::Replace($desc, '[^\x20-\x7E]', '')
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
        if ($null -ne $stream) { $stream.Dispose() }
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

        foreach ($desc in $script:CheatDatabase.Keys) {
            $safeDesc = [regex]::Replace($desc, '[^\x20-\x7E]', '')
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
        if ($null -ne $stream) { $stream.Dispose() }
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
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
    $rawCheats = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currentBlock = $null

    foreach ($line in $lines) {
        if ($line -match '^\s*name:\s*(.*)') {
            $rawDesc = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($rawDesc)) { $rawDesc = "Unassigned Code Block" }
            $currentBlock = [PSCustomObject]@{ Desc = $rawDesc; CodeLines = [System.Collections.Generic.List[string]]::new() }
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

        $parsedBlockCodes = [System.Collections.Generic.List[string]]::new()
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
    $sb = [System.Text.StringBuilder]::new()
    foreach ($desc in $script:CheatDatabase.Keys) {
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            $outputCode = $codeItem
            if ($outputCode.Length -eq 8 -and -not $outputCode.Contains("-")) {
                $outputCode = $outputCode.Substring(0, 6) + "=" + $outputCode.Substring(6, 2)
            }
            [void]$sb.AppendLine("cheat`n  name: $desc`n  code: $outputCode`n")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# --- MASTER SYSTEM MODULES ---
Register-InputModule -Name "Sega Master System / SMS" -Filter "Master System Cheats (*.pat)|*.pat" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}'
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "TripleGroupHyphen"
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
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
    $sb = [System.Text.StringBuilder]::new()
    foreach ($desc in $script:CheatDatabase.Keys) {
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine("$codeItem`t$desc")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
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
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
    $blocks = [System.Collections.Generic.List[psobject]]::new()
    $currentHeader = "Unassigned Code Block"
    $currentCodes = [System.Collections.Generic.List[string]]::new()
    $hasOrphans = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^\[(.*)\]') {
            if ($currentCodes.Count -eq 0 -and $currentHeader -ne "Unassigned Code Block") { $hasOrphans = $true }
            if ($currentCodes.Count -gt 0) {
                $blocks.Add([PSCustomObject]@{ Header = $currentHeader; Codes = $currentCodes.ToArray() })
                $currentCodes = [System.Collections.Generic.List[string]]::new()
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

        $validatedCodes = [System.Collections.Generic.List[string]]::new()
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
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
    $blocks = [System.Collections.Generic.List[psobject]]::new()
    $currentHeader = "Unassigned Code Block"
    $currentCodes = [System.Collections.Generic.List[string]]::new()
    $hasOrphans = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^#(.*)') {
            if ($currentCodes.Count -eq 0 -and $currentHeader -ne "Unassigned Code Block") { $hasOrphans = $true }
            if ($currentCodes.Count -gt 0) {
                $blocks.Add([PSCustomObject]@{ Header = $currentHeader; Codes = $currentCodes.ToArray() })
                $currentCodes = [System.Collections.Generic.List[string]]::new()
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

        $validatedCodes = [System.Collections.Generic.List[string]]::new()
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
    $sb = [System.Text.StringBuilder]::new()
    foreach ($desc in $script:CheatDatabase.Keys) {
        if ($script:CheatDatabase[$desc].Codes.Count -eq 0) { continue }
        [void]$sb.AppendLine("[$desc]")
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

Register-OutputModule -Name "ePSXe (.txt)" -Filter "ePSXe Cheat Files (*.txt)|*.txt" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($desc in $script:CheatDatabase.Keys) {
        if ($script:CheatDatabase[$desc].Codes.Count -eq 0) { continue }
        [void]$sb.AppendLine("#$desc")
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine($codeItem)
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# --- GBC MODULES ---
Register-InputModule -Name "Game Boy / GBC" -Filter "GBC Cheat Files (*.gbcht)|*.gbcht" -ParseFunc {
    param([string]$inputBlock)
    Invoke-UniversalRegexParser -RawText $inputBlock -PatternKey "GbcCombined"
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::OpenRead($filePath)
        $reader = [System.IO.BinaryReader]::new($stream)

        if ($stream.Length -ge 4) {
            $stream.Position = 1
            $totalRecords = $reader.ReadByte()
            $stream.Position = 3

            for ($i = 0; $i -lt $totalRecords; $i++) {
                if ($stream.Position + 3 -gt $stream.Length) { break }
                $status = $reader.ReadByte()
                $descLen = $reader.ReadByte()
                $nullSep = $reader.ReadByte()

                if ($stream.Position + $descLen -gt $stream.Length) { break }
                $rawDesc = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes($descLen))

                if ($stream.Position + 1 -gt $stream.Length) { break }
                $prefixByte = $reader.ReadByte()
                $codeLen = if ($prefixByte -eq 0x0b) { 11 } else { 8 }

                if ($stream.Position + $codeLen -gt $stream.Length) { break }
                $rawCode = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes($codeLen))

                $clean = & $parseFunc $rawCode
                if ($null -ne $clean -and $clean.Count -gt 0) {
                    $finalTitle = $rawDesc.Replace("'", "").Trim()
                    if ([string]::IsNullOrWhiteSpace($finalTitle)) { $finalTitle = "Unassigned Code Block" }
                    
                    Add-CheatToDatabase -Description $finalTitle -Codes $clean
                }
            }
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
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
    } finally { 
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

# --- MEGA DRIVE / MD MODULES ---
Register-InputModule -Name "Sega Mega Drive / MD" -Filter "MD Cheats (*.pat)|*.pat" -ParseFunc {
    param([string]$inputBlock)
    $cleanInput = $inputBlock -replace '(?i)\b([0-9A-F]*)(O)([0-9A-F]*)\b', '${1}0${3}'
    Invoke-UniversalRegexParser -RawText $cleanInput -PatternKey "SmsMdExtended"
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        if ($trimmed -match '^(?<code>(?:[0-9A-Fa-f]{6}:[0-9A-Fa-f]{4})|(?:[0-9A-Z]{4}-[0-9A-Z]{4}))\s+(?<desc>.*)') {
            $rawCode = $Matches['code'].Trim()
            $desc = $Matches['desc'].Replace("'", "").Trim()
            if ([string]::IsNullOrWhiteSpace($desc)) { $desc = "Unassigned Code Block" }

            $clean = & $parseFunc $rawCode
            if ($null -ne $clean -and $clean.Count -gt 0) {
                Add-CheatToDatabase -Description $desc -Codes $clean
            }
        }
    }
}

Register-OutputModule -Name "md.emu MD (.pat)" -Filter "md.emu Cheat Files (*.pat)|*.pat" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($desc in $script:CheatDatabase.Keys) {
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            [void]$sb.AppendLine("$codeItem`t$desc")
        }
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
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
    $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
    $currentDesc = "Unassigned Code Block"
    $currentLines = [System.Collections.Generic.List[string]]::new()

    function Commit-DSBlock {
        param($desc, $lines, $parseFunc)
        if ($lines.Count -eq 0) { return }

        $validCodes = [System.Collections.Generic.List[string]]::new()
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
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("CAT Cheats")
    foreach ($desc in $script:CheatDatabase.Keys) {
        [void]$sb.AppendLine("CODE 0 $desc")
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
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

# --- NES MODULES ---
Register-InputModule -Name "Nintendo NES" -Filter "NES Cheat Files (*.cht)|*.cht" -ParseFunc {
    param([string]$inputBlock)
    # Parse with the fixed registry engine pattern
    Invoke-UniversalRegexParser -RawText $inputBlock -PatternKey "NesCombined" -Formatter {
        param($m)
        $rawCode = $m.Value.ToUpper()
        
        # Dual Scan Check: If it matches a standard RAW structure (e.g., 8000:01)
        if ($rawCode -match '^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$') {
            $hexAddress = [System.Convert]::ToInt32($Matches[1], 16)
            
            # ONLY encode to Game Genie if it falls in ROM space (>= 0x8000)
            if ($hexAddress -ge 0x8000) {
                $encoded = Invoke-GameGenieEncodeNES $rawCode
                if ($null -ne $encoded) { return $encoded }
            }
        }
        return $rawCode
    }
} -ImportFunc {
    param([string]$filePath, [scriptblock]$parseFunc)
    
    $sniffLines = ""
    if (Test-Path $filePath) {
        $sniffLines = [System.IO.File]::ReadLines($filePath, $script:Utf8Encoding) | Select-Object -First 3
        $sniffLines = [string]::Join(" ", $sniffLines).Trim()
    }

    # Format architecture selector
    if ($sniffLines -match '^cheats\s*=' -or $sniffLines -match '^cheat\d+_') {
        Import-RetroArchChtEngine -filePath $filePath -parseFunc $parseFunc
    }
    else {
        $lines = [System.IO.File]::ReadAllLines($filePath, $script:Utf8Encoding)
        foreach ($line in $lines) {
            $line = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            # Safe tokenization by description delimiter
            $tokens = $line.Split(':', [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($tokens.Length -ge 2) {
                # Trailing element is always the descriptive tag
                $desc = $tokens[-1].Replace("'", "").Trim()
                if ([string]::IsNullOrWhiteSpace($desc)) { $desc = "Unassigned Code Block" }
                
                # Strip legacy emulator flag prefixes (SC:, C:, S:) while maintaining pure segments
                $codeParts = @()
                for ($i = 0; $i -lt ($tokens.Length - 1); $i++) {
                    $tokenClean = $tokens[$i].Trim().ToUpper()
                    if ($tokenClean -match '^(SC|C|S)$') { continue }
                    $codeParts += $tokenClean
                }
                
                $codeStr = [string]::Join(":", $codeParts)
                
                if (-not [string]::IsNullOrEmpty($codeStr)) {
                    $processedCodes = & $parseFunc $codeStr
                    if ($null -ne $processedCodes -and $processedCodes.Count -gt 0) {
                        Add-CheatToDatabase -Description $desc -Codes $processedCodes
                    }
                }
            }
        }
    }
}

Register-OutputModule -Name "nes.emu (.cht)" -Filter "nes.emu Cheat Files (*.cht)|*.cht" -ExportFunc {
    param([string]$filePath)
    $sb = [System.Text.StringBuilder]::new()
    
    foreach ($desc in $script:CheatDatabase.Keys) {
        # Clean up description text (strip out any trailing non-breaking spaces or whitespace)
        $cleanDesc = $desc.Trim()
        
        foreach ($codeItem in $script:CheatDatabase[$desc].Codes) {
            # Split apart compound codes chained by "+" symbols
            $subCodes = $codeItem.Split('+', [System.StringSplitOptions]::RemoveEmptyEntries)
            
            foreach ($subCode in $subCodes) {
                $rawCode = $subCode.Trim().TrimStart(':')
                
                # Fix for 9-char entries containing artifact prefixes (e.g. "OUNLAZGA" -> "UNLAZGA")
                if ($rawCode.Length -eq 9 -and $rawCode -match '^[A-Z]{9}$') {
                    $rawCode = $rawCode.Substring(1)
                }
                
                # 1. Decode Game Genie alpha codes (6 or 8 characters)
                if ($rawCode -match '^[A-Z]{6}$|^[A-Z]{8}$') {
                    $decoded = Invoke-GameGenieDecodeNES $rawCode
                    if ($null -ne $decoded) {
                        $rawCode = $decoded
                    }
                }
                
                # 2. Match and split standard RAW structures (ADDR:VAL or ADDR:VAL:CMP)
                if ($rawCode -match '^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2})(?::([0-9A-Fa-f]{2}))?$') {
                    $addrStr = $Matches[1]
                    $valStr  = $Matches[2]
                    $cmpStr  = $Matches[3]
                    
                    $addrInt = [Convert]::ToInt32($addrStr, 16)
                    $isHighAddress = $addrInt -ge 0x8000
                    $hasCompare = -not [string]::IsNullOrEmpty($cmpStr)
                    
                    # Prefix mapping rules for strict nes.emu compliance
                    if ($isHighAddress) {
                        $prefix = if ($hasCompare) { "SC:" } else { "S:" }
                    } else {
                        $prefix = if ($hasCompare) { "C:" } else { ":" }
                    }
                    
                    $bodyStr = if ($hasCompare) { "${addrStr}:${valStr}:${cmpStr}" } else { "${addrStr}:${valStr}" }
                    [void]$sb.AppendLine("${prefix}${bodyStr}:${cleanDesc}")
                } else {
                    # 3. Fallback structure ensuring a leading colon is strictly present
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
    $parseFunc = $script:InputModules[$targetModule].ParseFunc
    return & $parseFunc $inputBlock
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
    foreach ($desc in $script:CheatDatabase.Keys) {
        $joinedCodes = [string]::Join("+", $script:CheatDatabase[$desc].Codes)
        [void]$sb.AppendLine("cheat${idx}_desc = `"$desc`"")
        [void]$sb.AppendLine("cheat${idx}_code = `"$joinedCodes`"")
        [void]$sb.AppendLine("cheat${idx}_enable = false")
        [void]$sb.AppendLine("")
        $idx++
    }
    [System.IO.File]::WriteAllText($filePath, $sb.ToString(), $script:Utf8Encoding)
}

# ==============================================================================
# MAIN GUI FORM & CONTROLS
# ==============================================================================

$script:form = [System.Windows.Forms.Form]::new()
$script:form.Text = "Multi-Emulator Cheat Reformatter"
$script:form.Size = [System.Drawing.Size]::new(715, 625)
$script:form.StartPosition = "CenterScreen"

# --- Import Section ---
$script:lblInput = [System.Windows.Forms.Label]::new()
$script:lblInput.Text = "Input Module:"
$script:lblInput.Location = [System.Drawing.Point]::new(20, 16)
$script:lblInput.Size = [System.Drawing.Size]::new(80, 20)
$script:form.Controls.Add($script:lblInput)

$script:cmbInputModule = [System.Windows.Forms.ComboBox]::new()
$script:cmbInputModule.DropDownStyle = "DropDownList"
$script:cmbInputModule.Location = [System.Drawing.Point]::new(105, 13)
$script:cmbInputModule.Size = [System.Drawing.Size]::new(150, 25)
foreach ($key in $script:InputModules.Keys) { [void]$script:cmbInputModule.Items.Add($key) }
$script:form.Controls.Add($script:cmbInputModule)

# --- Dynamic Target Regex Dropdown ---
$script:lblTargetRegex = [System.Windows.Forms.Label]::new()
$script:lblTargetRegex.Text = "Target System Regex:"
$script:lblTargetRegex.Location = [System.Drawing.Point]::new(385, 16)
$script:lblTargetRegex.Size = [System.Drawing.Size]::new(125, 20)
$script:lblTargetRegex.Visible = $false
$script:form.Controls.Add($script:lblTargetRegex)

$script:cmbTargetRegex = [System.Windows.Forms.ComboBox]::new()
$script:cmbTargetRegex.DropDownStyle = "DropDownList"
$script:cmbTargetRegex.Location = [System.Drawing.Point]::new(515, 13)
$script:cmbTargetRegex.Size = [System.Drawing.Size]::new(155, 25)
foreach ($key in $script:InputModules.Keys) {
    if ($key -ne "RetroArch (Global)") { [void]$script:cmbTargetRegex.Items.Add($key) }
}
if ($script:cmbTargetRegex.Items.Count -gt 0) { $script:cmbTargetRegex.SelectedIndex = 0 }
$script:cmbTargetRegex.Visible = $false
$script:form.Controls.Add($script:cmbTargetRegex)

$script:btnImport = [System.Windows.Forms.Button]::new()
$script:btnImport.Text = "Import File"
$script:btnImport.Location = [System.Drawing.Point]::new(265, 12)
$script:btnImport.Size = [System.Drawing.Size]::new(100, 26)
$script:form.Controls.Add($script:btnImport)

# --- Left-Side Controls ---
$script:lblList = [System.Windows.Forms.Label]::new()
$script:lblList.Text = "Grouped Cheat Descriptions:"
$script:lblList.Location = [System.Drawing.Point]::new(20, 50)
$script:lblList.Size = [System.Drawing.Size]::new(200, 20)
$script:form.Controls.Add($script:lblList)

$script:lstCheats = [System.Windows.Forms.ListBox]::new()
$script:lstCheats.Location = [System.Drawing.Point]::new(20, 70)
$script:lstCheats.Size = [System.Drawing.Size]::new(260, 350)
$script:form.Controls.Add($script:lstCheats)

$script:txtNewGroup = [System.Windows.Forms.TextBox]::new()
$script:txtNewGroup.Location = [System.Drawing.Point]::new(20, 430)
$script:txtNewGroup.Size = [System.Drawing.Size]::new(100, 25)
$script:form.Controls.Add($script:txtNewGroup)

$script:btnNewGroup = [System.Windows.Forms.Button]::new()
$script:btnNewGroup.Text = "Add"
$script:btnNewGroup.Location = [System.Drawing.Point]::new(125, 429)
$script:btnNewGroup.Size = [System.Drawing.Size]::new(40, 26)
$script:form.Controls.Add($script:btnNewGroup)

$script:btnMoveUp = [System.Windows.Forms.Button]::new()
$script:btnMoveUp.Text = "▲"
$script:btnMoveUp.Location = [System.Drawing.Point]::new(170, 429)
$script:btnMoveUp.Size = [System.Drawing.Size]::new(35, 26)
$script:btnMoveUp.Enabled = $false
$script:form.Controls.Add($script:btnMoveUp)

$script:btnMoveDown = [System.Windows.Forms.Button]::new()
$script:btnMoveDown.Text = "▼"
$script:btnMoveDown.Location = [System.Drawing.Point]::new(210, 429)
$script:btnMoveDown.Size = [System.Drawing.Size]::new(35, 26)
$script:btnMoveDown.Enabled = $false
$script:form.Controls.Add($script:btnMoveDown)

$script:btnDeleteGroup = [System.Windows.Forms.Button]::new()
$script:btnDeleteGroup.Text = "❌"
$script:btnDeleteGroup.Location = [System.Drawing.Point]::new(250, 429)
$script:btnDeleteGroup.Size = [System.Drawing.Size]::new(30, 26)
$script:btnDeleteGroup.Enabled = $false
$script:form.Controls.Add($script:btnDeleteGroup)

# --- Right-Side Controls ---
$script:lblEditor = [System.Windows.Forms.Label]::new()
$script:lblEditor.Text = "Codes in Selected Group (One per line):"
$script:lblEditor.Location = [System.Drawing.Point]::new(300, 50)
$script:lblEditor.Size = [System.Drawing.Size]::new(310, 20)
$script:form.Controls.Add($script:lblEditor)

$script:txtEditor = [System.Windows.Forms.TextBox]::new()
$script:txtEditor.Multiline = $true
$script:txtEditor.ScrollBars = "Vertical"
$script:txtEditor.Font = [System.Drawing.Font]::new([System.Drawing.FontFamily]::GenericMonospace, 10)
$script:txtEditor.Location = [System.Drawing.Point]::new(300, 70)
$script:txtEditor.Size = [System.Drawing.Size]::new(370, 350)
$script:txtEditor.Add_TextChanged($script:TextChangeHandler)
$script:form.Controls.Add($script:txtEditor)

$script:btnSaveGroup = [System.Windows.Forms.Button]::new()
$script:btnSaveGroup.Text = "Update Current Group Modifications"
$script:btnSaveGroup.Location = [System.Drawing.Point]::new(300, 429)
$script:btnSaveGroup.Size = [System.Drawing.Size]::new(370, 26)
$script:btnSaveGroup.Enabled = $false
$script:form.Controls.Add($script:btnSaveGroup)

# --- Export Section ---
$script:lblOutput = [System.Windows.Forms.Label]::new()
$script:lblOutput.Text = "Export To:"
$script:lblOutput.Location = [System.Drawing.Point]::new(20, 473)
$script:lblOutput.Size = [System.Drawing.Size]::new(65, 20)
$script:form.Controls.Add($script:lblOutput)

$script:cmbOutputModule = [System.Windows.Forms.ComboBox]::new()
$script:cmbOutputModule.DropDownStyle = "DropDownList"
$script:cmbOutputModule.Location = [System.Drawing.Point]::new(85, 470)
$script:cmbOutputModule.Size = [System.Drawing.Size]::new(185, 25)
$script:form.Controls.Add($script:cmbOutputModule)

$script:btnExport = [System.Windows.Forms.Button]::new()
$script:btnExport.Text = "Export File"
$script:btnExport.Location = [System.Drawing.Point]::new(280, 469)
$script:btnExport.Size = [System.Drawing.Size]::new(100, 26)
$script:form.Controls.Add($script:btnExport)

# --- Bottom Status Log ---
$script:lblStatus = [System.Windows.Forms.Label]::new()
$script:lblStatus.Text = "System Activity Log:"
$script:lblStatus.Location = [System.Drawing.Point]::new(20, 507)
$script:lblStatus.Size = [System.Drawing.Size]::new(150, 15)
$script:form.Controls.Add($script:lblStatus)

$script:txtStatusLog = [System.Windows.Forms.TextBox]::new()
$script:txtStatusLog.Multiline = $true
$script:txtStatusLog.ReadOnly = $true
$script:txtStatusLog.ScrollBars = "Vertical"
$script:txtStatusLog.Font = New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericMonospace, 8.5)
$script:txtStatusLog.BackColor = [System.Drawing.Color]::White
$script:txtStatusLog.ForeColor = [System.Drawing.Color]::Black
$script:txtStatusLog.Location = [System.Drawing.Point]::new(20, 525)
$script:txtStatusLog.Size = [System.Drawing.Size]::new(650, 50)
$script:form.Controls.Add($script:txtStatusLog)

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
                
                # Promoted: Target System Output added FIRST so it becomes default
                if ($null -ne $mappedOutputKey -and $script:OutputModules.Contains($mappedOutputKey)) {
                    [void]$script:cmbOutputModule.Items.Add($mappedOutputKey)
                }
            }

            # RetroArch global output added SECOND as fallback option
            if ($script:OutputModules.Contains($retroArchOutputKey) -and -not $script:cmbOutputModule.Items.Contains($retroArchOutputKey)) {
                [void]$script:cmbOutputModule.Items.Add($retroArchOutputKey)
            }

            $script:cmbOutputModule.Enabled = $true
        } 
        else {
            # Promoted: RetroArch (.cht) added FIRST so it becomes default for system-specific inputs
            if ($script:OutputModules.Contains($retroArchOutputKey)) {
                [void]$script:cmbOutputModule.Items.Add($retroArchOutputKey)
            }

            # Original system output format added SECOND
            $mappedOutputKey = $script:ModuleOutputMap[$selectedInput]
            if ($null -ne $mappedOutputKey -and $script:OutputModules.Contains($mappedOutputKey) -and -not $script:cmbOutputModule.Items.Contains($mappedOutputKey)) {
                [void]$script:cmbOutputModule.Items.Add($mappedOutputKey)
            }

            $script:cmbOutputModule.Enabled = ($script:cmbOutputModule.Items.Count -gt 1)

            $script:lblTargetRegex.Visible = $false
            $script:cmbTargetRegex.Visible = $false
            $script:cmbTargetRegex.Enabled = $false
        }

        # Auto-select index 0 (the newly promoted default)
        if ($script:cmbOutputModule.Items.Count -gt 0) {
            $script:cmbOutputModule.SelectedIndex = 0
        }
    } finally {
        $script:cmbOutputModule.EndUpdate()
    }
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

    $ofd = [System.Windows.Forms.OpenFileDialog]::new()
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

    $sfd = [System.Windows.Forms.SaveFileDialog]::new()
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
            Disable-ListEvents
            $script:lstCheats.SelectedIndex = $script:LastSelectedIndex
            Enable-ListEvents
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
Enable-ListEvents

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
    $updatedCodes = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $cleanCodes -and $cleanCodes.Count -gt 0) {
        $updatedCodes.AddRange([string[]]$cleanCodes)
    }
    
    $script:CheatDatabase[$selectedDesc].Codes = $updatedCodes
    if ($updatedCodes.Count -gt 0) {
        $script:CheatDatabase[$selectedDesc].CodeType = Get-CodeType $updatedCodes[0]
    }
    
    $script:SuppressEvents = $true
    $script:txtEditor.Text = [string]::Join([Environment]::NewLine, $updatedCodes)
    $script:SuppressEvents = $false
    
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

    Disable-ListEvents
    $script:lstCheats.BeginUpdate()
    try {
        [void]$script:lstCheats.Items.Add($newTitle)
        $script:lstCheats.SelectedIndex = $script:lstCheats.Items.Count - 1
        $script:LastSelectedIndex = $script:lstCheats.SelectedIndex

        $script:txtEditor.Remove_TextChanged($script:TextChangeHandler)
        $script:txtEditor.Clear()
        $script:IsDirty = $false
        $script:txtEditor.Add_TextChanged($script:TextChangeHandler)

        Update-UIState
    } finally {
        $script:lstCheats.EndUpdate()
        Enable-ListEvents
    }
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

    Disable-ListEvents
    $script:lstCheats.BeginUpdate()
    try {
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
    } finally {
        $script:lstCheats.EndUpdate()
        Enable-ListEvents
    }
    Write-Log("Deleted group '$selectedDesc'.")
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
        foreach ($k in $script:CheatDatabase.Keys) { [void]$script:lstCheats.Items.Add($k) }

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

# Launch GUI Form Context
$script:form.ShowDialog()
