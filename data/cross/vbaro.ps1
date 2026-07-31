# Explicitly load Windows Forms and Drawing assemblies
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Helper Functions for File Format Verification & Processing ---

function Get-ValidatedFormat {
    param ([string]$filePath)
    if (-not (Test-Path -Path $filePath -PathType Leaf)) {
        return $null
    }
    
    try {
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        if ($bytes.Length -ge 12) {
            # Check for gba.emu/VBA .clt header magic: 01 00 00 00
            if ($bytes[0] -eq 1 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
                if ($bytes[4] -eq 1) {
                    return "VBA84"
                }
                if ($bytes[4] -eq 0) {
                    return "VBA80"
                }
            }
        }
        
        # Read text content cleanly handling BOM, UTF-8/16 variations
        $text = [System.IO.File]::ReadAllText($filePath)
        if ($text -match 'cheat\d+_code\s*=') {
            return "RetroArch"
        }
    } catch {
        return $null
    }
    return $null
}

function Get-UniqueOutputPath {
    param ([string]$inPath, [string]$targetExt)
    $dir = Split-Path -Parent $inPath
    $base = Split-Path -Leaf $inPath
    $baseNoExt = $base -replace '((|_vba|_retro)\.(cht|clt))$', ''
    
    $suffix = if ($targetExt -eq ".cht") { "_retro" } else { "_vba" }
    $candidate = Join-Path $dir "$($baseNoExt)${suffix}${targetExt}"
    
    $counter = 1
    while (Test-Path -Path $candidate) {
        $candidate = Join-Path $dir "$($baseNoExt)${suffix}_$($counter)${targetExt}"
        $counter++
    }
    return $candidate
}

# --- Core Converters ---

function Convert-RetroArchToClt {
    param ([string]$inPath, [string]$outPath, [bool]$is80Byte)
    
    $text = [System.IO.File]::ReadAllText($inPath)
    # Sanitize content for line feeds and clean tokens
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    
    # Simple parser for .cht pairs
    $descs = @{}
    $codes = @{}
    
    $text -split "`n" | ForEach-Object {
        if ($_ -match 'cheat(\d+)_desc\s*=\s*"(.*)"') {
            $descs[$Matches[1]] = $Matches[2]
        }
        if ($_ -match 'cheat(\d+)_code\s*=\s*"(.*)"') {
            $codes[$Matches[1]] = $Matches[2]
        }
    }
    
    $records = @()
    # Mask translation tables
    $maskTable84 = @{ '0'=@(255,255,255,255); '1'=@(112,0,0,0); '2'=@(33,0,0,0); '3'=@(0,0,0,0); '4'=@(9,0,0,0); '5'=@(36,0,0,0); '6'=@(11,0,0,0); '7'=@(8,0,0,0); '8'=@(1,0,0,0); '9'=@(255,255,255,255); 'A'=@(10,0,0,0); 'B'=@(35,0,0,0); 'C'=@(34,0,0,0); 'D'=@(7,0,0,0); 'E'=@(32,0,0,0); 'F'=@(50,0,0,0) }
    $maskTable80 = @{ '0'=@(255,255,255,255); '1'=@(255,255,255,255); '2'=@(33,0,0,0); '3'=@(0,0,0,0); '4'=@(9,0,0,0); '5'=@(36,0,0,0); '6'=@(11,0,0,0); '7'=@(8,0,0,0); '8'=@(1,0,0,0); '9'=@(255,255,255,255); 'A'=@(10,0,0,0); 'B'=@(34,0,0,0); 'C'=@(35,0,0,0); 'D'=@(7,0,0,0); 'E'=@(32,0,0,0); 'F'=@(255,255,255,255) }
    
    $currentTable = $maskTable84
    if ($is80Byte) {
        $currentTable = $maskTable80
    }
    
    $overrideFlag = 0
    
    foreach ($key in ($codes.Keys | Sort-Object {[int]$_})) {
        $rawCodeLine = $codes[$key].ToUpper() -replace 'O', '0'
        $descStr = " "
        if ($descs.ContainsKey($key)) {
            $descStr = $descs[$key]
        }
        if ([string]::IsNullOrWhiteSpace($descStr)) {
            $descStr = " "
        }
        if ($descStr.Length -gt 31) {
            $descStr = $descStr.Substring(0, 31)
        }
        
        # Split concatenated subcodes
        $subCodes = $rawCodeLine -split '\+'
        foreach ($sub in $subCodes) {
            $sub = $sub.Trim()
            if ($sub -notmatch '^([0-9A-F?]{8})\s+([0-9A-F?]{4})$') {
                continue
            }
            $part1 = $Matches[1]
            $part2 = $Matches[2]
            
            $typeChar = $part1.Substring(0,1)
            $mask = $currentTable[$typeChar]
            if ($null -eq $mask) {
                $mask = @(255,255,255,255)
            }
            
            if ($overrideFlag -eq 1) {
                $mask = @(255,255,255,255)
            }
            
            # Formulate address bytes (Little Endian)
            $p1Bytes = @()
            for($i=6; $i -ge 0; $i-=2) {
                $p1Bytes += [Convert]::ToByte($part1.Substring($i,2), 16)
            }
            $p2Bytes = @()
            for($i=2; $i -ge 0; $i-=2) {
                $p2Bytes += [Convert]::ToByte($part2.Substring($i,2), 16)
            }
            
            $p1ZeroedBytes = @()
            $p1ZeroedStr = "0" + $part1.Substring(1)
            for($i=6; $i -ge 0; $i-=2) {
                $p1ZeroedBytes += [Convert]::ToByte($p1ZeroedStr.Substring($i,2), 16)
            }
            
            if ($mask[0] -eq 255 -and $mask[1] -eq 255) {
                $p1ZeroedBytes = $p1Bytes
            }
            
            # Compile payload bytes
            $recStream = [System.IO.MemoryStream]::new()
            
            # Block 1 (16 bytes metadata)
            $recStream.Write(@(0, 2, 0, 0), 0, 4)
            $recStream.Write($mask, 0, 4)
            $recStream.Write(@(0,0,0,0, 0,0,0,0), 0, 8) # Active flags and spacing
            
            # Block 2 (Internal translation logic spacing alignment differences)
            if (-not $is80Byte) {
                $recStream.Write($p1Bytes, 0, 4)
                $recStream.Write($p1ZeroedBytes, 0, 4)
                $recStream.Write($p2Bytes, 0, 2)
                $recStream.Write(@(0,0,0,0,0,0), 0, 6)
            } else {
                $recStream.Write($p1ZeroedBytes, 0, 4)
                $recStream.Write($p2Bytes, 0, 2)
                $recStream.Write(@(0,0,0,0,0,0,0,0,0,0), 0, 10)
            }
            
            # Block 3 (20 Bytes Raw Source Code Labeling)
            $asciiLabel = "$part1 $part2"
            $labelBytes = [System.Text.Encoding]::ASCII.GetBytes($asciiLabel)
            $labelBuffer = [byte[]]::new(20)
            [Array]::Copy($labelBytes, $labelBuffer, [Math]::Min($labelBytes.Length, 20))
            $recStream.Write($labelBuffer, 0, 20)
            
            # Block 4 (32 Bytes Description payload)
            $descBytes = [System.Text.Encoding]::ASCII.GetBytes($descStr)
            $descBuffer = [byte[]]::new(32)
            [Array]::Copy($descBytes, $descBuffer, [Math]::Min($descBytes.Length, 32))
            $recStream.Write($descBuffer, 0, 32)
            
            $records += ,$recStream.ToArray()
            $recStream.Dispose()
            
            # Multi-line chain evaluations safely chained structurally
            if ($typeChar -eq '5') {
                $overrideFlag = 2
            } elseif ($typeChar -eq '4' -and $overrideFlag -ne 2) {
                $overrideFlag = 1
            } elseif ($is80Byte -and "4BC".Contains($typeChar) -and $overrideFlag -ne 2) {
                $overrideFlag = 1
            } elseif ($overrideFlag -eq 1) {
                $overrideFlag = 0
            }
        }
    }
    
    # Write structural file header
    $fs = [System.IO.File]::Create($outPath)
    $magic2 = 1
    if ($is80Byte) {
        $magic2 = 0
    }
    $fs.Write(@(1,0,0,0, $magic2,0,0,0), 0, 8)
    
    $countBytes = [BitConverter]::GetBytes([int]$records.Count)
    $fs.Write($countBytes, 0, 4)
    
    foreach ($r in $records) {
        $fs.Write($r, 0, $r.Length)
    }
    $fs.Close()
}

function Convert-CltToRetroArch {
    param ([string]$inPath, [string]$outPath, $sourceFormat)
    
    $bytes = [System.IO.File]::ReadAllBytes($inPath)
    $totalRecords = [BitConverter]::ToInt32($bytes, 8)
    
    $recordSize = 84
    if ($sourceFormat -eq "VBA80") {
        $recordSize = 80
    }
    
    $aggregatedCheats = @()
    $currentDesc = $null
    $currentCode = ""
    
    $offset = 12
    for ($i = 0; $i -lt $totalRecords; $i++) {
        if (($offset + $recordSize) -gt $bytes.Length) {
            break
        }
        
        # Calculate description and string offsets depending on alignment block layout
        $calcSpacing = 16
        if ($recordSize -eq 80) {
            $calcSpacing = 12
        }
        $strOffset = $offset + 16 + $calcSpacing
        $descOffset = $strOffset + 20
        
        $rawCodeStr = [System.Text.Encoding]::ASCII.GetString($bytes, $strOffset, 20).Split("`0")[0].Trim()
        $rawDescStr = [System.Text.Encoding]::ASCII.GetString($bytes, $descOffset, 32).Split("`0")[0].Trim()
        
        # Check and handle look-ahead sequential code combination rules
        if ($null -eq $currentDesc) {
            $currentDesc = $rawDescStr
            $currentCode = $rawCodeStr
        } elseif ($rawDescStr -eq $currentDesc -and -not [string]::IsNullOrEmpty($rawDescStr) -and $rawDescStr -ne " ") {
            $currentCode = $currentCode + "+" + $rawCodeStr
        } else {
            $aggregatedCheats += ,[PSCustomObject]@{ Desc = $currentDesc; Code = $currentCode }
            $currentDesc = $rawDescStr
            $currentCode = $rawCodeStr
        }
        
        $offset += $recordSize
    }
    
    # Flush remaining tracked cache allocation frame cleanly
    if ($null -ne $currentDesc) {
        $aggregatedCheats += ,[PSCustomObject]@{ Desc = $currentDesc; Code = $currentCode }
    }
    
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("cheats = $($aggregatedCheats.Count)`n")
    
    for ($i = 0; $i -lt $aggregatedCheats.Count; $i++) {
        $c = $aggregatedCheats[$i]
        [void]$sb.AppendLine("cheat${i}_desc = `"$($c.Desc)`"")
        [void]$sb.AppendLine("cheat${i}_code = `"$($c.Code)`"")
        [void]$sb.AppendLine("cheat${i}_enable = `"false`"`n")
    }
    
    [System.IO.File]::WriteAllText($outPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

# --- WinForms View Engine Initialization ---

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Universal GBA Cheat Transformer Core"
$Form.Size = New-Object System.Drawing.Size(620, 520)
$Form.StartPosition = "CenterScreen"
$Form.FormBorderStyle = "FixedDialog"
$Form.MaximizeBox = $false

# Universal Control Metrics
$currentTop = 15
$margin = 12
$controlWidth = 575

# --- Group/Input Elements ---
$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text = "Source Cheat Target (Input Path):"
$lblInput.SetBounds($margin, $currentTop, $controlWidth, 18)
$Form.Controls.Add($lblInput)

$currentTop += 20
$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.SetBounds($margin, $currentTop, 470, 23)
$Form.Controls.Add($txtInput)

$btnBrowseInput = New-Object System.Windows.Forms.Button
$btnBrowseInput.Text = "Browse..."
$btnBrowseInput.SetBounds($margin + 480, $currentTop - 1, 95, 25)
$Form.Controls.Add($btnBrowseInput)

# --- Group/Output Elements ---
$currentTop += 38
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = "Destination File Target (Output Base Directory):"
$lblOutput.SetBounds($margin, $currentTop, $controlWidth, 18)
$Form.Controls.Add($lblOutput)

$currentTop += 20
$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.SetBounds($margin, $currentTop, 470, 23)
$Form.Controls.Add($txtOutput)

$btnBrowseOutput = New-Object System.Windows.Forms.Button
$btnBrowseOutput.Text = "Set Folder..."
$btnBrowseOutput.SetBounds($margin + 480, $currentTop - 1, 95, 25)
$Form.Controls.Add($btnBrowseOutput)

# --- Transformation Formats Block ---
$currentTop += 38
$lblFormat = New-Object System.Windows.Forms.Label
$lblFormat.Text = "Operational Transformation Schema:"
$lblFormat.SetBounds($margin, $currentTop, $controlWidth, 18)
$Form.Controls.Add($lblFormat)

$currentTop += 20
$cmbFormat = New-Object System.Windows.Forms.ComboBox
$cmbFormat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbFormat.SetBounds($margin, $currentTop, 360, 23)
$Form.Controls.Add($cmbFormat)

$btnConvert = New-Object System.Windows.Forms.Button
$btnConvert.Text = "Execute Transform"
$btnConvert.Font = New-Object System.Drawing.Font($Form.Font, [System.Drawing.FontStyle]::Bold)
$btnConvert.SetBounds($margin + 375, $currentTop - 1, 200, 26)
$Form.Controls.Add($btnConvert)

# --- Operational Feedback Monitor Area ---
$currentTop += 42
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Diagnostic Logging Operations Feed Monitor:"
$lblStatus.SetBounds($margin, $currentTop, $controlWidth, 18)
$Form.Controls.Add($lblStatus)

$currentTop += 20
$txtStatus = New-Object System.Windows.Forms.TextBox
$txtStatus.Multiline = $true
$txtStatus.ReadOnly = $true
$txtStatus.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtStatus.BackColor = [System.Drawing.Color]::FromName("ControlLight")
$txtStatus.SetBounds($margin, $currentTop, $controlWidth, 230)
$Form.Controls.Add($txtStatus)

# --- Application UI State Controllers ---

function Write-Log {
    param([string]$msg, [string]$level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logLine = "[" + $timestamp + "] " + $level + ": " + $msg + "`r`n"
    $txtStatus.AppendText($logLine)
}

function Reset-LockedState {
    $btnBrowseOutput.Enabled = $false
    $txtOutput.Enabled = $false
    $cmbFormat.Enabled = $false
    $btnConvert.Enabled = $false
    $cmbFormat.Items.Clear()
}

# Enforce Initial Locking State cleanly after functions are declared
Reset-LockedState
Write-Log "System initialized. Waiting for valid source input file authorization."

# Global operational schema payload mapping tracker
$script:DetectedFormat = $null

# --- Form Interaction Event Logic Hooks ---

$txtInput.Add_TextChanged({
    Reset-LockedState
    $path = $txtInput.Text.Trim()
    
    if (Test-Path -Path $path -PathType Leaf) {
        $fmt = Get-ValidatedFormat $path
        if ($null -ne $fmt) {
            $script:DetectedFormat = $fmt
            Write-Log "File format validation passed: [$fmt]"
            
            # Populate contextual opposite formats inside selection schema drop-down
            if ($fmt -eq "RetroArch") {
                [void]$cmbFormat.Items.Add("VBA 84 Byte (.clt)")
                [void]$cmbFormat.Items.Add("VBA 80 Byte (.clt)")
                [void]$cmbFormat.Items.Add("RetroArch (.cht) [Normalization Mode]")
                $cmbFormat.SelectedIndex = 0
            } elseif ($fmt -eq "VBA84") {
                [void]$cmbFormat.Items.Add("RetroArch (.cht)")
                [void]$cmbFormat.Items.Add("VBA 80 Byte (.clt)")
                [void]$cmbFormat.Items.Add("VBA 84 Byte (.clt) [No Conversion]")
                $cmbFormat.SelectedIndex = 0
            } elseif ($fmt -eq "VBA80") {
                [void]$cmbFormat.Items.Add("RetroArch (.cht)")
                [void]$cmbFormat.Items.Add("VBA 84 Byte (.clt)")
                [void]$cmbFormat.Items.Add("VBA 80 Byte (.clt) [No Conversion]")
                $cmbFormat.SelectedIndex = 0
            }
            
            # Unlock subcomponents safely
            $btnBrowseOutput.Enabled = $true
            $txtOutput.Enabled = $true
            $cmbFormat.Enabled = $true
            $btnConvert.Enabled = $true
            
            # Resolve default unique paths automatically
            $targetExt = ".clt"
            if ($fmt -match "VBA") {
                $targetExt = ".cht"
            }
            $txtOutput.Text = Get-UniqueOutputPath $path $targetExt
        } else {
            Write-Log "Invalid File Structure. Header verification match failed." "WARN"
        }
    }
})

$btnBrowseInput.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Supported Formats (*.cht;*.clt)|*.cht;*.clt|RetroArch Cheats (*.cht)|*.cht|VBA Binary Cheats (*.clt)|*.clt"
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtInput.Text = $ofd.FileName
    }
})

$btnBrowseOutput.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $targetExt = ".clt"
        if ($cmbFormat.Text -match "RetroArch") {
            $targetExt = ".cht"
        }
        $txtOutput.Text = Get-UniqueOutputPath (Join-Path $fbd.SelectedPath (Split-Path -Leaf $txtInput.Text)) $targetExt
    }
})

$cmbFormat.Add_SelectedIndexChanged({
    if ([string]::IsNullOrEmpty($txtInput.Text)) {
        return
    }
    if ($cmbFormat.Text -match "80 Byte") {
        Write-Log "Legacy VBA 80-byte format selected. Note: This profile is deprecated and not recommended." "WARN"
    }
    
    # Dynamically match file box name schema when drop down shifts target type properties
    $targetExt = ".clt"
    if ($cmbFormat.Text -match "RetroArch") {
        $targetExt = ".cht"
    }
    $txtOutput.Text = Get-UniqueOutputPath $txtInput.Text $targetExt
})

$btnConvert.Add_Click({
    $in = $txtInput.Text.Trim()
    $out = $txtOutput.Text.Trim()
    $selectedScheme = $cmbFormat.Text
    
    if (-not (Test-Path -Path $in -PathType Leaf)) {
        Write-Log "Processing aborted. Source input missing." "ERROR"
        return
    }
    
    try {
        Write-Log "Starting process engine routine loop..."
        
        if ($script:DetectedFormat -eq "RetroArch") {
            if ($selectedScheme -match "84 Byte") {
                Convert-RetroArchToClt $in $out $false
            } elseif ($selectedScheme -match "80 Byte") {
                Convert-RetroArchToClt $in $out $true
            } else {
                # Normalization passthrough
                Copy-Item $in $out
            }
        } else {
            # Source file is a binary CLT format profile variant
            if ($selectedScheme -match "RetroArch") {
                Convert-CltToRetroArch $in $out $script:DetectedFormat
            } elseif ($selectedScheme -match "84 Byte" -and $script:DetectedFormat -eq "VBA80") {
                # Transcompile 80 to 84 byte
                $tempCht = [System.IO.Path]::GetTempFileName()
                Convert-CltToRetroArch $in $tempCht "VBA80"
                Convert-RetroArchToClt $tempCht $out $false
                if (Test-Path $tempCht) {
                    Remove-Item $tempCht
                }
            } elseif ($selectedScheme -match "80 Byte" -and $script:DetectedFormat -eq "VBA84") {
                # Transcompile 84 to 80 byte
                $tempCht = [System.IO.Path]::GetTempFileName()
                Convert-CltToRetroArch $in $tempCht "VBA84"
                Convert-RetroArchToClt $tempCht $out $true
                if (Test-Path $tempCht) {
                    Remove-Item $tempCht
                }
            } else {
                Copy-Item $in $out
            }
        }
        
        Write-Log "Successfully written output compilation asset to target location:" "SUCCESS"
        Write-Log "-> $out"
        
        # Fresh safety increment for next execution iteration
        $targetExt = [System.IO.Path]::GetExtension($out)
        $txtOutput.Text = Get-UniqueOutputPath $in $targetExt
        
    } catch {
        Write-Log "An unexpected system fault stopped the processing routine: $($_.Exception.Message)" "CRITICAL"
    }
})

# Display Window Layout Canvas Frame Object
$Form.ShowDialog()
