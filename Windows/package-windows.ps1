$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $PSScriptRoot "GamePulse.Windows\GamePulse.Windows.csproj"
$output = Join-Path $root "dist\windows-x64"
$zip = Join-Path $root "dist\GamePulse-Windows-x64.zip"

if (Test-Path $output) { Remove-Item $output -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }

dotnet publish $project -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -o $output

Copy-Item (Join-Path $PSScriptRoot "WINDOWS-使用说明.txt") $output
Compress-Archive -Path (Join-Path $output "*") -DestinationPath $zip
Write-Host "已生成：$zip"
