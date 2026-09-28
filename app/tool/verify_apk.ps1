# Release gate for Android APKs. ASCII-only on purpose: PowerShell 5.1 mis-parses
# UTF-8 files without a BOM (see handover doc section 7), and this script must run
# from any editor.
#
# Checks, per real-device ABI (arm64-v8a, armeabi-v7a):
#   1. versionName in the APK == version in pubspec.yaml
#      (a stale flutter.versionName in android/local.properties silently overrides
#       pubspec -- that is how a release shipped with the wrong version string)
#   2. android.permission.INTERNET is in the built APK
#      (the Flutter template only puts it in the debug/profile manifests, so a
#       release APK built from the template has no network at all on device)
#   3. libsqlite3.so is packed for that ABI
#      (sqlite3 3.x + sqlite3_flutter_libs 0.6.0+eol ship NO native library; Android
#       refuses to dlopen the platform libsqlite3.so, so the app dies on "cannot open
#       local database". This is the check that catches it before anyone installs it.)
#
# Usage:  powershell -ExecutionPolicy Bypass -File app\tool\verify_apk.ps1
# Exit 0 = all good; exit 1 = at least one check failed.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # repo root (babyco/)
$app = Join-Path $root 'app'

# ★ -Encoding UTF8 is not cosmetic: PowerShell 5.1 defaults to the ANSI codepage, and
# reading this UTF-8 pubspec as GBK lets multi-byte Chinese sequences swallow the
# following newline — the "version:" line then stops being a line start and the regex
# silently finds nothing (same class of trap as the .ps1-must-have-BOM note in the
# handover doc section 7).
$pubspec = Get-Content (Join-Path $app 'pubspec.yaml') -Raw -Encoding UTF8
$verMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)')
if (-not $verMatch.Success) { Write-Host 'cannot read version from pubspec.yaml'; exit 1 }
$wantName = $verMatch.Groups[1].Value
$wantCode = [int]$verMatch.Groups[2].Value

$localProps = Get-Content (Join-Path $app 'android/local.properties') | Where-Object { $_ -match '=' }
$sdk = ($localProps | Where-Object { $_ -match '^sdk\.dir=' }) -replace '^sdk\.dir=', '' -replace '\\\\', '\'
$bt = Get-ChildItem (Join-Path $sdk 'build-tools') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$aapt = Join-Path $bt.FullName 'aapt.exe'
if (-not (Test-Path $aapt)) { Write-Host "aapt.exe not found under $sdk\build-tools"; exit 1 }
Write-Host "aapt: $aapt"
Write-Host "expect versionName=$wantName (pubspec build number $wantCode; note split-per-abi adds an ABI offset to versionCode)"

$fail = 0
$abis = @('arm64-v8a', 'armeabi-v7a')
foreach ($abi in $abis) {
  $apk = Join-Path $app "build/app/outputs/flutter-apk/app-$abi-release.apk"
  if (-not (Test-Path $apk)) { Write-Host "MISSING APK: $apk"; $fail = 1; continue }

  $badging = & $aapt dump badging $apk 2>$null
  $pkgLine = ($badging | Select-String -Pattern '^package:').Line
  $nameOk = $pkgLine -match "versionName='$wantName'"
  $codeOk = $pkgLine -match "versionCode='([1-9][0-9]*)$wantCode'"
  $netOk = [bool]($badging | Select-String -Pattern "uses-permission: name='android.permission.INTERNET'")
  $soList = & $aapt list $apk 2>$null | Select-String -Pattern "^lib/$abi/"
  $sqlOk = [bool]($soList | Select-String -Pattern 'libsqlite3\.so$')

  Write-Host ""
  Write-Host "== $abi  ($([math]::Round((Get-Item $apk).Length / 1MB, 2)) MB)"
  Write-Host ("   versionName   : " + $(if ($nameOk) { 'OK' } else { "FAIL  [$pkgLine]" }))
  Write-Host ("   versionCode   : " + $(if ($codeOk) { 'OK' } else { "FAIL  [$pkgLine]" }))
  Write-Host ("   INTERNET      : " + $(if ($netOk) { 'OK' } else { 'FAIL  (release build has no network permission)' }))
  Write-Host ("   libsqlite3.so : " + $(if ($sqlOk) { 'OK' } else { 'FAIL  (app cannot open its local database on device)' }))
  Write-Host ("   native libs   : " + (($soList | ForEach-Object { ($_.Line -split '/')[-1] }) -join ', '))

  if (-not ($nameOk -and $codeOk -and $netOk -and $sqlOk)) { $fail = 1 }
}

Write-Host ""
if ($fail) { Write-Host 'RESULT: FAIL - do not ship this build' -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: PASS - APKs are shippable' -ForegroundColor Green
