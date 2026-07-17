# ============================================================
# WinAppSDK Cleanup Script (Unified Version - Corrected Loop)
# Elevation + ExecutionPolicy Bypass + Logging + Dependency Cleanup
# ============================================================

# --- Elevation Check and Auto-Relaunch ---
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Host "Elevation required. Relaunching as Administrator..." -ForegroundColor Yellow

    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$MyInvocation.MyCommand.Path`""
    return
}

Write-Host "Running with elevated privileges." -ForegroundColor Green

# --- Temporary Execution Policy Bypass ---
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Write-Host "Execution policy bypass enabled for this session." -ForegroundColor Green

# --- Logging Setup ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "WinAppSDK_Cleanup.log"

function Log($message) {
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "[$timestamp] $message"
}

Log "=== Script started ==="

Write-Host "Scanning installed apps for WinAppSDK dependencies..." -ForegroundColor Cyan
Log "Scanning installed apps for dependencies."

# --- Dependency Scan ---
$apps = Get-AppxPackage
$dependencyMap = @()
$requiredFamilies = @()

foreach ($app in $apps) {
    $manifestPath = Join-Path $app.InstallLocation "AppxManifest.xml"

    if (Test-Path $manifestPath) {
        try {
            $xml = [xml](Get-Content $manifestPath)

            $deps    = $xml.Package.Dependencies.PackageDependency
            $extDeps = $xml.Package.Extensions.Extension.Dependencies.PackageDependency

            $allDeps = @()
            if ($deps)    { $allDeps += $deps }
            if ($extDeps) { $allDeps += $extDeps }

            foreach ($dep in $allDeps) {
                if ($dep.Name -like "Microsoft.WindowsAppRuntime*") {

                    $dependencyMap += [pscustomobject]@{
                        AppName   = $app.Name
                        WinAppSDK = $dep.Name
                    }

                    $requiredFamilies += $dep.Name
                    Log "Dependency found: $($dep.Name) for app $($app.Name)"
                }
            }
        }
        catch {
            Write-Host "Failed to parse manifest for $($app.Name)" -ForegroundColor Red
            Log "Failed to parse manifest for $($app.Name)"
        }
    }
}

$requiredFamilies = $requiredFamilies | Sort-Object -Unique

# --- Dependency Report ---
Write-Host "`n=== WinAppSDK Dependencies (AppName ? WinAppSDK) ===" -ForegroundColor Green
if ($dependencyMap.Count -eq 0) {
    Write-Host "No applications declare WinAppSDK dependencies." -ForegroundColor Yellow
    Log "No dependencies found."
} else {
    $dependencyMap | Sort-Object AppName | Format-Table -AutoSize
}

Write-Host "`n=== Required WinAppSDK Families ===" -ForegroundColor Green
foreach ($fam in $requiredFamilies) {
    Write-Host "  $fam"
    Log "Required family: $fam"
}

# --- Installed Redistributables ---
$installed = Get-AppxPackage Microsoft.WindowsAppRuntime.* |
    Where-Object {
        $_.PackageFamilyName -notlike "*CBS*" -and
        $_.PackageFamilyName -notlike "MicrosoftCorporationII*"
    }

Write-Host "`n=== Installed Redistributable WinAppSDK Versions ===" -ForegroundColor Green
$installed | Select-Object PackageFullName, Version | Format-Table -AutoSize

foreach ($pkg in $installed) {
    Log "Installed redistributable: $($pkg.PackageFullName)"
}

# --- Correct Removal Logic ---
function Get-FamilyName($pkg) {
    return $pkg.PackageFamilyName.Split("_")[0]
}

$eligibleForRemoval = $installed | Where-Object {
    $family = Get-FamilyName $_
    $requiredFamilies -notcontains $family
}

Write-Host "`n=== Redistributables Eligible for Removal (Corrected) ===" -ForegroundColor Magenta
if ($eligibleForRemoval.Count -eq 0) {
    Write-Host "No redistributables are eligible for removal." -ForegroundColor Yellow
    Log "No redistributables eligible for removal."
} else {
    $eligibleForRemoval | Select-Object PackageFullName, Version | Format-Table -AutoSize
    foreach ($pkg in $eligibleForRemoval) {
        Log "Eligible for removal: $($pkg.PackageFullName)"
    }
}

# --- Interactive Removal ---
if ($eligibleForRemoval.Count -eq 0) {
    Write-Host "`nNo removal necessary - all installed redistributables are required." -ForegroundColor Cyan
    Log "No removal necessary. Exiting."
    Write-Host "`nIf the Microsoft Store shows stuck WinAppSDK updates, run: wsreset -i" -ForegroundColor Cyan
    Log "wsreset reminder printed."
    Log "=== Script finished ==="
    return
}

Write-Host "`nInteractive removal begins..." -ForegroundColor Cyan
Log "Interactive removal started."

:RemovalLoop foreach ($pkg in $eligibleForRemoval) {

    Write-Host "`nRemove: $($pkg.PackageFullName)" -ForegroundColor Yellow
    $response = Read-Host "[Y]es / [N]o / [A]ll / [E]xit"

    switch ($response.ToUpper()) {

        "Y" {
            Write-Host "Removing $($pkg.PackageFullName)..." -ForegroundColor Red
            Log "Removed: $($pkg.PackageFullName)"
            Remove-AppxPackage -Package $pkg.PackageFullName
        }

        "N" {
            Write-Host "Skipping $($pkg.PackageFullName)" -ForegroundColor Gray
            Log "Skipped: $($pkg.PackageFullName)"
        }

        "A" {
            Write-Host "Removing ALL eligible redistributables..." -ForegroundColor Red
            Log "User selected ALL removal."
            foreach ($p in $eligibleForRemoval) {
                Log "Removed: $($p.PackageFullName)"
                Remove-AppxPackage -Package $p.PackageFullName
            }
            break RemovalLoop
        }

        "E" {
            Write-Host "Exiting without further removals." -ForegroundColor Cyan
            Log "User exited early."
            break RemovalLoop
        }

        default {
            Write-Host "Invalid choice - skipping." -ForegroundColor Gray
            Log "Invalid choice for $($pkg.PackageFullName)"
        }
    }
}

Write-Host "`nCleanup complete." -ForegroundColor Green
Log "Cleanup complete."

Write-Host "`nIf the Microsoft Store shows stuck WinAppSDK updates, run: wsreset -i" -ForegroundColor Cyan
Log "wsreset reminder printed."

Log "=== Script finished ==="
