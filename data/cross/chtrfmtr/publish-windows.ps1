param(
    [ValidateSet("win-x64","win-arm64")]
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"

dotnet restore
dotnet publish .\ChtrFmtr.Avalonia.csproj `
    -c Release `
    -r $Runtime `
    --self-contained true

Write-Host ""
Write-Host "Published to:"
Write-Host "bin\Release\net10.0\$Runtime\publish\"
