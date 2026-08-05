param(
    [switch]$Release
)

Set-Location $PSScriptRoot

$mode = if ($Release) { 'release' } else { 'debug' }
$targetPlatform = 'android-arm64'

& flutter build apk "--$mode" --target-platform $targetPlatform --no-pub

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$apkDir = Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk'
$apkPath = Join-Path $apkDir "app-$mode.apk"
if (Test-Path -LiteralPath $apkPath) {
    Get-Item -LiteralPath $apkPath | Select-Object FullName, Length, LastWriteTime
} else {
    Write-Host "APK not found at $apkPath"
}