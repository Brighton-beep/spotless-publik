# Build the Android app and install it on a connected phone, in one go.
#
#   powershell -File android/dev.ps1 [-Release] [-NoUi] [-NoInstall] [-Device <ip:port>]
#
# Does what `tauri android build` does, minus its symlink into jniLibs (Windows refuses symlinks
# without Developer Mode): builds the UI, the Rust library for arm64, copies it next to libmpv
# (android/libmpv/fetch.ps1) stripped, then lets Gradle pack the APK. Expects the Android SDK, NDK
# and JDK 17 from docs/ANDROID.md.
param([switch]$Release, [switch]$NoUi, [switch]$NoInstall, [string]$Device)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')

# Toolchain environment (overridable from outside).
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$env:ANDROID_HOME = $sdk
if (-not $env:NDK_HOME) { $env:NDK_HOME = (Get-ChildItem "$sdk\ndk" -Directory | Sort-Object Name | Select-Object -Last 1).FullName }
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = (Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium" -Directory | Where-Object Name -like 'jdk-17*' | Select-Object -First 1).FullName }
$tc = "$env:NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64"
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:JAVA_HOME\bin;$sdk\platform-tools;$tc\bin;" + $env:Path
$env:CC_aarch64_linux_android = "$tc\bin\aarch64-linux-android24-clang.cmd"
$env:CXX_aarch64_linux_android = "$tc\bin\aarch64-linux-android24-clang++.cmd"
$env:AR_aarch64_linux_android = "$tc\bin\llvm-ar.exe"
$env:RANLIB_aarch64_linux_android = "$tc\bin\llvm-ranlib.exe"
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "$tc\bin\aarch64-linux-android24-clang.cmd"
# rquickjs-sys generates its Android bindings (src-tauri/Cargo.toml). Forward slashes: the
# argument parser eats backslashes.
$env:LIBCLANG_PATH = "$tc\bin"
$env:BINDGEN_EXTRA_CLANG_ARGS = "--target=aarch64-linux-android24 --sysroot=" + ($tc -replace '\\', '/') + "/sysroot"

$jni = "$root\src-tauri\gen\android\app\src\main\jniLibs\arm64-v8a"
if (-not (Test-Path "$jni\libmpv.so")) { & "$root\android\libmpv\fetch.ps1" }

if (-not $NoUi) {
    Push-Location "$root\ui"; pnpm build; if ($LASTEXITCODE) { throw 'UI build failed' }; Pop-Location
}

$profile = if ($Release) { 'release' } else { 'debug' }
# The Tauri CLI builds the Rust library and regenerates the Gradle wiring for the plugins
# (tauri.settings.gradle, app/tauri.build.gradle.kts). Its last step, symlinking the library into
# jniLibs, fails without Developer Mode; that one failure is expected and handled below.
$noBefore = Join-Path $env:TEMP 'spotless-nobefore.json'
Set-Content -Encoding ascii $noBefore '{"build":{"beforeBuildCommand":""}}'
$cliArgs = @('android', 'build', '--target', 'aarch64', '--apk', '--config', $noBefore)
if (-not $Release) { $cliArgs += '--debug' }
Push-Location $root
# The CLI logs to stderr, which Windows PowerShell turns into errors under 'Stop'.
$ErrorActionPreference = 'Continue'
$log = & "$root\ui\node_modules\.bin\tauri.cmd" @cliArgs 2>&1 | ForEach-Object { "$_" }
$rc = $LASTEXITCODE; Pop-Location
$ErrorActionPreference = 'Stop'
if ($rc -and -not ($log -match 'Failed to create a symbolic link')) { $log | Select-Object -Last 40 | Out-Host; throw 'tauri android build failed' }

Copy-Item "$root\target\aarch64-linux-android\$profile\libapp_lib.so" $jni -Force
Get-ChildItem $jni *.so | ForEach-Object { & "$tc\bin\llvm-strip.exe" --strip-unneeded $_.FullName }

$variant = if ($Release) { 'Release' } else { 'Debug' }
Push-Location "$root\src-tauri\gen\android"
# Gradle rewrites an existing APK in place and keeps the replaced entries' bytes: 146 MB of
# content grew to a 658 MB file. Start from nothing.
Remove-Item "app\build\outputs\apk", "app\build\intermediates\apk" -Recurse -Force -ErrorAction SilentlyContinue
& .\gradlew.bat "assembleArm64$variant" -x "rustBuildArm64$variant" -PabiList=arm64-v8a -PtargetList=aarch64 --console=plain -q
$rc = $LASTEXITCODE; Pop-Location
if ($rc) { throw 'gradle failed' }
$apk = Get-ChildItem "$root\src-tauri\gen\android\app\build\outputs\apk\arm64\$($profile)" -Filter *.apk | Select-Object -First 1
Write-Host ("APK: {0} ({1:N0} MB)" -f $apk.FullName, ($apk.Length / 1MB))

if (-not $NoInstall) {
    # Named explicitly: one phone often shows up twice (its Tailscale address and the one adb finds
    # on the local network), and a bare `adb install` refuses to pick.
    $sel = @()
    if ($Device) { adb connect $Device | Out-Host; $sel = @('-s', $Device) }
    adb @sel install -r $apk.FullName
    if ($LASTEXITCODE) { throw 'adb install failed' }
    adb @sel shell monkey -p app.spotless.android -c android.intent.category.LAUNCHER 1 | Out-Null
}
