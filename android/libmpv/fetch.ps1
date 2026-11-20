# Downloads the libmpv build the android-libmpv workflow published (release "libmpv-android") into
# the Android project's jniLibs, where Gradle packs it into the APK and src-tauri/build.rs links it.
# Usage (from anywhere): powershell -File android/libmpv/fetch.ps1 [-Repo owner/name]
param([string]$Repo)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if (-not $Repo) {
    $url = git -C $root remote get-url origin
    $Repo = ($url -replace '^.*github\.com[:/]', '' -replace '\.git$', '')
}
$zip = Join-Path $env:TEMP 'libmpv-android-arm64-v8a.zip'
$src = "https://github.com/$Repo/releases/download/libmpv-android/libmpv-android-arm64-v8a.zip"
Write-Host "Downloading $src"
Invoke-WebRequest $src -OutFile $zip -UseBasicParsing
$stage = Join-Path $env:TEMP 'libmpv-android-stage'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip $stage
$jni = Join-Path $root 'src-tauri\gen\android\app\src\main\jniLibs'
New-Item -ItemType Directory -Force $jni | Out-Null
Copy-Item (Join-Path $stage 'arm64-v8a') $jni -Recurse -Force
Get-ChildItem (Join-Path $jni 'arm64-v8a') | Format-Table Name, Length
