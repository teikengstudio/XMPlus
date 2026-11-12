#requires -Version 5.1
<#
Builds directly in the workspace; refuses to replace a running project client.
Requires a verified source-built native supply, including in private candidate mode.
Use -RuntimeOnly in CI: validates source provenance without copying source/relink
materials. Full local mode retains separate development materials, never in the ZIP.
-ReplaceLocalCandidate preserves the previous private bundle/ZIP as unique backups.
#>
[CmdletBinding()]
param(
    [switch]$LocalCandidate,
    [switch]$ReplaceLocalCandidate,
    [switch]$RuntimeOnly,
    [string]$NugetPath,
    [string]$NativeSupply = 'build/windows-native',
    [string]$OutputDirectory = 'dist',
    [string]$DevelopmentDirectory = 'build\corresponding-source',
    [string]$SdkRoot = $env:FLUTTER_ROOT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $SdkRoot) { $SdkRoot = Split-Path (Split-Path (Get-Command flutter.bat -ErrorAction Stop).Source) }
$Flutter = Join-Path $SdkRoot 'bin\flutter.bat'
$Dart = Join-Path $SdkRoot 'bin\dart.bat'
$UploadSentrySymbols = $env:SENTRY_UPLOAD_SYMBOLS -ceq 'true'
if ($UploadSentrySymbols) {
    foreach ($name in @('SENTRY_DSN', 'SENTRY_AUTH_TOKEN')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            throw "SENTRY_UPLOAD_SYMBOLS=true requires process environment $name before building."
        }
    }
}
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Read-Json([string]$Path) {
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 100), $Utf8)
}
function Field($Object, [string]$Name) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $null
}
function Ensure-Directory([string]$Path) {
    [void][IO.Directory]::CreateDirectory($Path)
}
function Assert-PlainPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are not allowed in packaging inputs: $Path"
    }
}
function Child-Path([string]$Base, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative)) {
        throw "Expected a relative packaging path: $Relative"
    }
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Base $Relative))
    if (-not $full.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Packaging path escapes its root: $Relative"
    }
    return $full
}
function Relative-Path([string]$Base, [string]$Path) {
    $prefix = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "File is outside the packaging root: $Path"
    }
    return $full.Substring($prefix.Length).Replace('\', '/')
}
function File-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-Hash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$') { throw "Missing SHA-256 for $Path" }
    Assert-PlainPath $Path
    if ((File-Hash $Path) -ne $Expected.ToLowerInvariant()) { throw "SHA-256 mismatch: $Path" }
}
function Copy-File([string]$From, [string]$To) {
    Assert-PlainPath $From
    if ((Split-Path -Leaf $From) -match '(?i)^readme') {
        throw "Standalone README files must not be copied: $From"
    }
    Ensure-Directory (Split-Path -Parent $To)
    [IO.File]::Copy($From, $To, $false)
}
function Copy-Tree([string]$From, [string]$To, [string]$Mode) {
    Assert-PlainPath $From
    Ensure-Directory $To
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        if ($item.Name -match '(?i)^readme') { continue }
        if ($item.Name -in @('.git', '.dart_tool', '.plugin_symlinks', 'ephemeral', 'build', 'dist')) { continue }
        if ($Mode -eq 'windows' -and $item.Name -like 'generated_*') { continue }
        Assert-PlainPath $item.FullName
        $destination = Join-Path $To $item.Name
        if ($item.PSIsContainer) {
            Copy-Tree $item.FullName $destination $Mode
        } else {
            $allowed = $true
            if ($Mode -eq 'dart') { $allowed = $item.Extension -eq '.dart' }
            if ($Mode -eq 'assets') { $allowed = $item.Extension -in @('.png', '.jpg', '.jpeg', '.webp', '.svg', '.ico', '.ttf', '.otf', '.json') }
            if ($Mode -eq 'windows') {
                $allowed = $item.Name -in @('CMakeLists.txt', 'LICENSE.PiliPlus', '.gitignore') -or
                    $item.Extension -in @('.cpp', '.cc', '.h', '.rc', '.manifest', '.ico', '.png')
            }
            if ($allowed) { Copy-File $item.FullName $destination }
        }
    }
}
function Assert-MicrosoftSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw "NuGet must have a valid Microsoft Authenticode signature: $Path"
    }
}
function Download-File([string]$Url, [string]$Path) {
    # ServicePointManager and PATH changes below are process-local, restored on exit.
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -TimeoutSec 180
}
function Invoke-Flutter([string[]]$Arguments) {
    $savedCredential = [Environment]::GetEnvironmentVariable('XMLY_TEST_CREDENTIALS_JSON', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('XMLY_TEST_CREDENTIALS_JSON', $null, 'Process')
        & $Flutter --suppress-analytics @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Flutter exited with code $LASTEXITCODE ($($Arguments[0]))." }
    } finally {
        [Environment]::SetEnvironmentVariable('XMLY_TEST_CREDENTIALS_JSON', $savedCredential, 'Process')
    }
}
function Tool-Identity([string]$Executable, [string]$Argument) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = $Argument
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    [void]$info.EnvironmentVariables.Remove('XMLY_TEST_CREDENTIALS_JSON')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Metadata command failed: $Executable $Argument" }
        return $text
    } finally { $process.Dispose() }
}
function Assert-ProjectClientsStopped {
    $prefix = $ProjectRoot.TrimEnd('\') + '\'
    foreach ($item in Get-CimInstance -ClassName Win32_Process -Filter "Name='XMPlus.exe' OR Name='xmly_flutter.exe'") {
        $path = [string]$item.ExecutablePath
        if (-not $path) { throw "Cannot identify the application at PID $($item.ProcessId)." }
        if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Close the project client at PID $($item.ProcessId) before building; it was not stopped automatically."
        }
    }
}
function Assert-Replacement([string]$Target, [string]$Zip, [string]$NoFFmpegZip, [string]$SourceDirectory) {
    $hasTarget = Test-Path -LiteralPath $Target
    $hasZip = Test-Path -LiteralPath $Zip
    $hasNoFFmpegZip = Test-Path -LiteralPath $NoFFmpegZip
    if (Test-Path -LiteralPath $SourceDirectory) { throw "Existing development sources must be preserved: $SourceDirectory" }
    if (-not $hasTarget -and -not $hasZip -and -not $hasNoFFmpegZip) { return }
    if (-not $LocalCandidate -or -not $ReplaceLocalCandidate -or -not $hasTarget) {
        throw 'Output exists; only -LocalCandidate -ReplaceLocalCandidate may replace a recognized private candidate.'
    }
    Assert-PlainPath $Target
    $statusPath = Join-Path $Target 'RELEASE-STATUS.json'
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw 'Existing output has no ownership status.' }
    $status = Read-Json $statusPath
    if ((Field $status 'application') -ne 'XMPlus' -or (Field $status 'package') -ne $PackageName -or
        (Field $status 'status') -ne 'local-verification-only' -or
        (Field $status 'redistributionReady') -ne $false) {
        throw 'Existing output is not a matching XMPlus private candidate.'
    }
    if ($hasZip) { Assert-PlainPath $Zip }
    if ($hasNoFFmpegZip) { Assert-PlainPath $NoFFmpegZip }
}
function File-Inventory([string]$Root) {
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName) {
        Assert-PlainPath $file.FullName
        [pscustomobject]@{ path = (Relative-Path $Root $file.FullName); bytes = $file.Length; sha256 = (File-Hash $file.FullName) }
    }
}
function New-VerifiedZip([string]$Directory, [string]$ZipPath, [switch]$ExcludeFFmpeg) {
    # Stream the runtime payload and use standard compact compression for bundled tools.
    $files = @(File-Inventory $Directory | Where-Object { -not $ExcludeFFmpeg -or $_.path -notlike 'tools/ffmpeg/*' })
    foreach ($file in $files) {
        if ($file.path -match '(?i)\.(?:tar(?:\.[a-z0-9]+)?|zip|7z|nupkg|jks|keystore|pdb|obj|o|a|c|cc|cpp|h|hpp|py|ps1|sh)$' -or
            $file.path -match '(?i)(^|/)(?:BUILD-MANIFEST|BUILD-RECEIPT|RELEASE-STATUS|IMPORTS)\.json$') {
            throw "Development material must not enter the runtime ZIP: $($file.path)"
        }
    }
    $prefix = (Split-Path -Leaf $Directory) + '/'
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,
                (Child-Path $Directory $file.path), ($prefix + $file.path), [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($zip.Entries.Count -ne $files.Count) { throw 'ZIP entry count mismatch.' }
        foreach ($file in $files) {
            $entry = $zip.GetEntry($prefix + $file.path)
            if ($null -eq $entry -or $entry.Length -ne $file.bytes) { throw "ZIP entry mismatch: $($file.path)" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($hash -ne $file.sha256) { throw "ZIP verification failed: $($file.path)" }
        }
    } finally { $zip.Dispose() }
}

$nativeManifest = Read-Json (Join-Path $ProjectRoot 'tool\native_sources.json')
if (-not [IO.Path]::IsPathRooted($NativeSupply)) { $NativeSupply = Join-Path $ProjectRoot $NativeSupply }
$NativeSupply = [IO.Path]::GetFullPath($NativeSupply)
if (-not (Test-Path -LiteralPath (Join-Path $NativeSupply 'BUILD-RECEIPT.json') -PathType Leaf)) {
    throw 'Build the hash-locked native supply first: bash tool/windows-native-build.sh build/windows-native'
}
$supplyReceipt = Read-Json (Join-Path $NativeSupply 'BUILD-RECEIPT.json')
if ($supplyReceipt.schemaVersion -ne 1 -or $supplyReceipt.target -ne 'windows-x64' -or
    $supplyReceipt.producer -ne 'tool/windows_native_build.py' -or
    (Field $supplyReceipt 'supplyMode') -ne $(if ($RuntimeOnly) { 'runtime-only' } else { 'complete' }) -or
    $supplyReceipt.sourceComplete -ne (-not [bool]$RuntimeOnly)) {
    throw 'Unsupported Windows native supply receipt or packaging mode mismatch.'
}
foreach ($file in $supplyReceipt.files) { Assert-Hash (Child-Path $NativeSupply $file.path) $file.sha256 }
$supplySources = Read-Json (Join-Path $NativeSupply 'sources\SOURCES.json')
$expectedSources = @((Read-Json (Join-Path $ProjectRoot 'tool\media_sources.json')).components) +
    @((Read-Json (Join-Path $ProjectRoot 'tool\windows_native_sources.json')).components)
if (@($supplySources.components).Count -ne $expectedSources.Count -or @($supplySources.patches).Count -ne 0) {
    throw 'Native source closure differs from the admitted source locks.'
}
foreach ($expected in $expectedSources) {
    $actual = @($supplySources.components | Where-Object { $_.name -eq $expected.name })
    if ($actual.Count -ne 1 -or $actual[0].sha256 -ne $expected.sha256 -or $actual[0].url -ne $expected.url) {
        throw "Native source lock mismatch: $($expected.name)"
    }
    if (-not $RuntimeOnly) {
        Assert-Hash (Join-Path $NativeSupply ('sources\' + (Split-Path -Leaf $expected.file))) $expected.sha256
    }
}
$recipes = @('windows_native_build.py', 'windows-native-build.sh', 'windows_native_sources.json', 'media_sources.json')
if (@($supplySources.recipes).Count -ne $recipes.Count) { throw 'Native build recipe closure mismatch.' }
foreach ($name in $recipes) {
    $recipe = @($supplySources.recipes | Where-Object { $_.path -eq $name })
    $expectedHash = File-Hash (Join-Path $PSScriptRoot $name)
    if ($recipe.Count -ne 1 -or $recipe[0].sha256 -ne $expectedHash) { throw "Native build recipe mismatch: $name" }
    if (-not $RuntimeOnly) { Assert-Hash (Join-Path $NativeSupply ('sources\' + $name)) $expectedHash }
}
$toolchain = @($expectedSources | Where-Object { $_.name -eq 'llvm-mingw-toolchain' })[0]
if ($supplyReceipt.toolchainSha256 -ne $toolchain.sha256) { throw 'Native toolchain mismatch.' }
$requiredMembers = @('runtime/libmpv-2.dll', 'runtime/tools/ffmpeg/ffmpeg.exe', 'runtime/tools/ffmpeg/ffprobe.exe',
    'sources/SOURCES.json', 'licenses/THIRD-PARTY-NOTICES.txt', 'licenses/WINDOWS-PREREQUISITES.txt', 'IMPORTS.json')
if (-not $RuntimeOnly) { $requiredMembers += 'sources/BUILD-OBJECTS.tar.gz' }
foreach ($required in $requiredMembers) {
    if (@($supplyReceipt.files | Where-Object { $_.path -eq $required }).Count -ne 1) {
        throw "Native supply omits a required hashed member: $required"
    }
}
if ($RuntimeOnly -and (@($supplyReceipt.files).Count -ne $requiredMembers.Count -or
    @($supplyReceipt.files | Where-Object { $_.path -notin $requiredMembers }).Count -ne 0)) {
    throw 'Runtime-only supply contains development material or unexpected members.'
}
$nativeFFmpegHash = File-Hash (Join-Path $NativeSupply 'runtime\tools\ffmpeg\ffmpeg.exe')
$blockers = New-Object 'System.Collections.Generic.List[string]'
# Historical Gyan/2023-mpv gaps are not waived: those binaries are no longer packaged.
# Admission binds runtime hashes to exact source locks and build recipe; relink objects are local-only.
if ($ReplaceLocalCandidate -and -not $LocalCandidate) { throw '-ReplaceLocalCandidate requires -LocalCandidate.' }
$sdk = Read-Json (Join-Path $SdkRoot 'bin\cache\flutter.version.json')
if ($sdk.frameworkVersion -ne '3.47.9' -or $sdk.dartSdkVersion -ne '3.13.7') {
    throw 'Required SDK: Flutter 3.47.9 / Dart 3.13.7. Update the selected SDK before packaging.'
}
$pubspec = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'pubspec.yaml'), [Text.Encoding]::UTF8)
$versionMatch = [regex]::Match($pubspec, '(?m)^version:[ \t]*(?<version>(?<release>[0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+)[ \t]*\r?$')
if ($pubspec -notmatch '(?m)^name:\s*xmly_flutter\s*$' -or -not $versionMatch.Success) {
    throw 'This packaging script requires xmly_flutter with a stable pubspec version X.Y.Z+N.'
}
$PackageVersion = $versionMatch.Groups['version'].Value
$ReleaseVersion = $versionMatch.Groups['release'].Value
$PackageName = "XMPlus-$ReleaseVersion-windows-x64"
$SourceName = "XMPlus-$ReleaseVersion-source"
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory = Join-Path $ProjectRoot $OutputDirectory }
$dist = [IO.Path]::GetFullPath($OutputDirectory)
$target = Join-Path $dist $PackageName
$targetZip = $target + '.zip'
$targetNoFFmpegZip = $target + '-no-ffmpeg.zip'
if (-not [IO.Path]::IsPathRooted($DevelopmentDirectory)) { $DevelopmentDirectory = Join-Path $ProjectRoot $DevelopmentDirectory }
$development = [IO.Path]::GetFullPath($DevelopmentDirectory)
if ($development.Equals($dist, [StringComparison]::OrdinalIgnoreCase) -or
    $development.StartsWith($dist.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Development sources/evidence must be outside the application output directory.'
}
$targetSources = Join-Path $development $SourceName
$targetEvidence = Join-Path $development ($PackageName + '-evidence')
if (Test-Path -LiteralPath $targetEvidence) { throw "Existing development evidence must be preserved: $targetEvidence" }
Assert-ProjectClientsStopped
Assert-Replacement $target $targetZip $targetNoFFmpegZip $targetSources

$stage = Join-Path $ProjectRoot ('build\xmplus-package-' + [Guid]::NewGuid().ToString('N'))
$source = $ProjectRoot
$bundle = Join-Path $stage $PackageName
Ensure-Directory $bundle
$oldPath = $env:PATH
$oldTls = [Net.ServicePointManager]::SecurityProtocol
$oldNativeSupply = [Environment]::GetEnvironmentVariable('XMPLUS_NATIVE_SUPPLY', 'Process')
$oldSentryRelease = [Environment]::GetEnvironmentVariable('SENTRY_RELEASE', 'Process')
$oldSentryDist = [Environment]::GetEnvironmentVariable('SENTRY_DIST', 'Process')
$oldLocation = Get-Location
try {
    [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $lockHash = File-Hash (Join-Path $source 'pubspec.lock')

    if ($NugetPath) {
        $NugetPath = (Resolve-Path -LiteralPath $NugetPath).Path
        Assert-MicrosoftSignature $NugetPath
    } else {
        $pinnedNuget = 'C:\Users\Nahida\AppData\Local\Temp\xmly-build-tools-9yvSEa\nuget.exe'
        if (Test-Path -LiteralPath $pinnedNuget -PathType Leaf) {
            Assert-MicrosoftSignature $pinnedNuget
            $NugetPath = $pinnedNuget
        } else {
            $NugetPath = Join-Path $stage 'nuget-download.exe'
            Download-File 'https://dist.nuget.org/win-x86-commandline/v6.14.0/nuget.exe' $NugetPath
            Assert-MicrosoftSignature $NugetPath
        }
    }
    # A private nuget.exe always wins PATH; no global install or PATH update.
    $buildTools = Join-Path $stage 'build-tools'
    Ensure-Directory $buildTools
    Copy-File $NugetPath (Join-Path $buildTools 'nuget.exe')
    Assert-MicrosoftSignature (Join-Path $buildTools 'nuget.exe')
    $env:PATH = $buildTools + ';' + $oldPath
    [Environment]::SetEnvironmentVariable('XMPLUS_NATIVE_SUPPLY', $NativeSupply, 'Process')
    Set-Location -LiteralPath $source
    Invoke-Flutter -Arguments @('pub', 'get', '--enforce-lockfile')
    Assert-Hash (Join-Path $source 'pubspec.lock') $lockHash
    # Discard only the obsolete pre-branding CMake cache, not user data or SDK files.
    $cache = Join-Path $ProjectRoot 'build\windows\x64\CMakeCache.txt'
    if ((Test-Path -LiteralPath $cache) -and
        [IO.File]::ReadAllText($cache).Contains('CMAKE_INSTALL_PREFIX:PATH=$<TARGET_FILE_DIR:xmly_flutter>')) {
        Remove-Item -LiteralPath $cache
    }
    foreach ($name in @('xmly_flutter.exe', 'cnativeapi.dll')) {
        $obsolete = Join-Path $ProjectRoot ('build\windows\x64\runner\Release\' + $name)
        if (Test-Path -LiteralPath $obsolete -PathType Leaf) { Remove-Item -LiteralPath $obsolete }
    }
    $buildArguments = @('build', 'windows', '--release', '--no-pub')
    foreach ($name in @('SENTRY_DSN', 'SENTRY_ENVIRONMENT')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) { $buildArguments += "--dart-define=$name=$value" }
    }
    Invoke-Flutter -Arguments $buildArguments
    Assert-Hash (Join-Path $source 'pubspec.lock') $lockHash

    $release = Join-Path $source 'build\windows\x64\runner\Release'
    Copy-File (Join-Path $release 'XMPlus.exe') (Join-Path $bundle 'XMPlus.exe')
    Copy-Tree (Join-Path $release 'data') (Join-Path $bundle 'data') 'runtime'
    foreach ($dll in Get-ChildItem -LiteralPath $release -Filter '*.dll' -File) {
        if ($dll.Name -match '^(?i:msvcp140.*|vcruntime140.*|concrt140)\.dll$') { continue }
        Copy-File $dll.FullName (Join-Path $bundle $dll.Name)
    }
    foreach ($required in @('data\app.so', 'data\icudtl.dat', 'data\flutter_assets', 'flutter_windows.dll',
        'libmpv-2.dll', 'flutter_inappwebview_windows_plugin.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bundle $required))) { throw "Incomplete runner bundle: $required" }
    }
    $enginePath = Join-Path $SdkRoot 'bin\cache\artifacts\engine\windows-x64-release\flutter_windows.dll'
    $engineHash = File-Hash $enginePath
    Assert-Hash (Join-Path $bundle 'flutter_windows.dll') $engineHash
    $mpvFile = @($supplyReceipt.files | Where-Object { $_.path -eq 'runtime/libmpv-2.dll' })[0]
    Assert-Hash (Join-Path $bundle 'libmpv-2.dll') $mpvFile.sha256
    Copy-Tree (Join-Path $NativeSupply 'runtime\tools') (Join-Path $bundle 'tools') 'runtime'
    Copy-Tree (Join-Path $NativeSupply 'licenses') (Join-Path $bundle 'licenses\native\source-build') 'runtime'
    Copy-File (Join-Path $NativeSupply 'licenses\WINDOWS-PREREQUISITES.txt') (Join-Path $bundle 'WINDOWS-PREREQUISITES.txt')
    $identities = @()
    foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
        $executable = Join-Path $bundle ('tools\ffmpeg\' + $name)
        $versionText = Tool-Identity $executable '-version'
        if ($versionText -notmatch 'version 9\.0\.2') { throw "Unexpected FFmpeg version: $name" }
        $buildConf = (($versionText -split '\r?\n' | Where-Object { $_ -match '^configuration:' }) -join "`r`n")
        if (-not $buildConf -or $buildConf -notmatch '--enable-libmp3lame' -or $buildConf -notmatch '--enable-zlib') {
            throw "Missing required FFmpeg build configuration: $name"
        }
        $identities += [pscustomobject]@{ name = $name; sha256 = (File-Hash $executable); version = $versionText; buildConfiguration = $buildConf }
    }
    Write-Json (Join-Path $bundle 'tools\ffmpeg\version-identity.json') ([ordered]@{ sourceBuild = $true; tools = $identities })

    Copy-File (Join-Path $ProjectRoot 'LICENSE') (Join-Path $bundle 'LICENSE')
    Copy-File (Join-Path $ProjectRoot 'NOTICE') (Join-Path $bundle 'NOTICE')
    Copy-File (Join-Path $ProjectRoot 'windows\LICENSE.PiliPlus') (Join-Path $bundle 'LICENSE.PiliPlus')
    # Runtime payload: licenses and notices only, not source archives or build evidence.
    $nativeLicenses = @($nativeManifest.artifacts | Where-Object {
        $_.path -like 'licenses/native/licenses/*' -and
            ($_.path -like '*.LICENSE' -or $_.path -like '*/Flutter-*' -or $_.path -like '*/PiliPlus-GPL-*' -or
             $_.path -like '*/Microsoft.Web.WebView2-*' -or $_.path -like '*/Microsoft.Windows.ImplementationLibrary-*' -or
             $_.path -like '*/nlohmann-*')
    })
    foreach ($artifact in $nativeLicenses) {
        Assert-Hash (Child-Path $ProjectRoot $artifact.path) $artifact.sha256
        $destination = Child-Path $bundle $artifact.path
        Copy-File (Child-Path $ProjectRoot $artifact.path) $destination
        Assert-Hash $destination $artifact.sha256
    }
    $engineLicense = Join-Path $SdkRoot 'bin\cache\artifacts\engine\windows-x64-release\license.windows_flutter.md'
    $engineLicenseHash = File-Hash $engineLicense
    $bundledEngineLicense = Join-Path $bundle 'licenses\native\licenses\Flutter-windows-binary-license.txt'
    Copy-File $engineLicense $bundledEngineLicense
    Assert-Hash $bundledEngineLicense $engineLicenseHash
    # Gyan license/configuration files describe retired binaries, not this source build.
    $nativeSdk = @($nativeManifest.components | Where-Object { $_.name -eq 'WebView2Loader, WIL, nlohmann.json' })[0]
    $origins = [ordered]@{
        schemaVersion = 1
        application = "XMPlus $PackageVersion"
        notice = 'Hash-locked source-built Windows media payload. Source provenance is retained; source archives and relink objects are not bundled with the runtime or transferred by CI. Microsoft CRT DLLs are not redistributed.'
        flutter = [ordered]@{ version = $sdk.frameworkVersion; frameworkCommit = $sdk.frameworkRevision; engineCommit = $sdk.engineRevision; url = 'https://github.com/flutter/flutter' }
        upstreamEntries = $nativeManifest.aboutSourceEntry.upstreamEntries
        packages = @($nativeManifest.packages | Select-Object name, version, url, archiveSha256)
        nativeSdk = @($nativeSdk.packages | ForEach-Object {
            [ordered]@{ name = $_.name; version = $_.version; url = $_.artifact.source; sha256 = $_.artifact.sha256 }
        })
        libmpv = [ordered]@{ binarySha256 = $mpvFile.sha256; sourceCommit = (Read-Json (Join-Path $PSScriptRoot 'windows_native_sources.json')).mpvCommit; license = 'LGPL-2.1-or-later; linked dependency licenses in native/source-build/THIRD-PARTY-NOTICES.txt' }
        sourcePins = $supplySources.components
        ffmpeg = [ordered]@{ version = '9.0.2'; sourceBuild = $true; license = 'LGPL-2.1-or-later; LAME LGPL-2.0-or-later'; tools = $identities }
    }
    Write-Json (Join-Path $bundle 'licenses\SOURCES.json') $origins
    $private = [bool]$LocalCandidate
    $statusValue = 'redistribution-material-gates-cleared'
    if ($private) { $statusValue = 'local-verification-only' }
    if ($RuntimeOnly -and -not $private) { $statusValue = 'runtime-provenance-verified' }
    $status = [ordered]@{
        sourceMaterialsComplete = (-not [bool]$RuntimeOnly)
        redistributionReady = $false
        distributionRequirement = 'Provide applicable corresponding-source access separately before public binary distribution; it is not bundled with this runtime package.'
        schemaVersion = 1; application = 'XMPlus'; version = $PackageVersion; package = $PackageName
        status = $statusValue
        generatedAtUtc = [DateTime]::UtcNow.ToString('o'); blockers = @($blockers.ToArray())
        ffmpegReleaseCompliance = [ordered]@{ completeCorrespondingSource = (-not [bool]$RuntimeOnly); sourceBuild = $true }
        nativeDistributionReady = (-not [bool]$RuntimeOnly)
        functionalValidation = 'Packaging verifies tool identities/hashes, not playback. Real Windows media_kit playback and all media processing formats/remux/cover/hash require parent acceptance.'
        sourceMaterials = $null
    }
    if ($private) {
        [IO.File]::WriteAllText((Join-Path $bundle 'SOURCE-MATERIALS-INCOMPLETE.txt'),
            "PRIVATE LOCAL VERIFICATION ONLY - NOT FOR REDISTRIBUTION.`r`n" +
            "Corresponding-source and functional-validation gates are not asserted by this build.`r`n" +
            ($blockers -join "`r`n") + "`r`nSee licenses/SOURCES.json for version and origin references; source materials are maintained separately.`r`n", $Utf8)
    }

    $stagedSources = $null
    if (-not $private -and -not $RuntimeOnly) {
        # App sources plus explicitly admitted third-party sources; never account data.
        $appSource = Join-Path $stage $SourceName
        Ensure-Directory $appSource
        foreach ($tree in @('lib', 'windows', 'assets')) {
            $mode = $tree
            if ($tree -eq 'lib') { $mode = 'dart' }
            Copy-Tree (Join-Path $source $tree) (Join-Path $appSource $tree) $mode
        }
        foreach ($name in @('pubspec.yaml', 'pubspec.lock')) { Copy-File (Join-Path $source $name) (Join-Path $appSource $name) }
        foreach ($name in @('LICENSE', 'NOTICE', 'CHANGELOG.md')) { Copy-File (Join-Path $ProjectRoot $name) (Join-Path $appSource $name) }
        foreach ($name in @('build_windows.ps1', 'ffmpeg_sources.json', 'native_sources.json', 'windows-native-build.sh',
            'windows_native_build.py', 'windows_native_sources.json', 'media_sources.json')) {
            Copy-File (Join-Path $ProjectRoot ('tool\' + $name)) (Join-Path $appSource ('tool\' + $name))
        }
        foreach ($relative in @('licenses/android/THIRD-PARTY-NOTICES.txt', 'licenses/media/THIRD-PARTY-NOTICES.txt')) {
            Copy-File (Child-Path $ProjectRoot $relative) (Child-Path $appSource $relative)
        }
        Copy-File $engineLicense (Join-Path $appSource 'licenses\native\licenses\Flutter-windows-binary-license.txt')
        Assert-Hash (Join-Path $appSource 'licenses\native\licenses\Flutter-windows-binary-license.txt') $engineLicenseHash
        foreach ($artifact in $nativeLicenses) {
            Copy-File (Child-Path $ProjectRoot $artifact.path) (Child-Path $appSource $artifact.path)
        }
        # Keep native lock-relative paths; Flutter dependencies still resolve via pubspec.lock.
        foreach ($expected in $expectedSources) {
            Copy-File (Join-Path $NativeSupply ('sources\' + (Split-Path -Leaf $expected.file))) (Child-Path $appSource $expected.file)
        }
        foreach ($package in $nativeManifest.packages) {
            Assert-Hash (Child-Path $ProjectRoot $package.artifact) $package.archiveSha256
            Copy-File (Child-Path $ProjectRoot $package.artifact) (Child-Path $appSource $package.artifact)
        }
        foreach ($package in $nativeSdk.packages) {
            Assert-Hash (Child-Path $ProjectRoot $package.artifact.path) $package.artifact.sha256
            Copy-File (Child-Path $ProjectRoot $package.artifact.path) (Child-Path $appSource $package.artifact.path)
        }
        foreach ($name in @('SOURCES.json', 'BUILD-OBJECTS.tar.gz')) {
            Copy-File (Join-Path $NativeSupply ('sources\' + $name)) (Join-Path $appSource ('native-sources\' + $name))
        }
        Copy-Tree (Join-Path $NativeSupply 'licenses') (Join-Path $appSource 'native-sources\licenses') 'runtime'
        Copy-File (Join-Path $NativeSupply 'BUILD-RECEIPT.json') (Join-Path $appSource 'native-sources\BUILD-RECEIPT.json')
        Copy-File (Join-Path $NativeSupply 'IMPORTS.json') (Join-Path $appSource 'native-sources\IMPORTS.json')
        $stagedSources = $appSource
        $status.sourceMaterials = [ordered]@{ directory = $SourceName; location = 'separate development directory'; includedInRuntime = $false }
    }
    $evidence = Join-Path $stage 'package-evidence'
    Ensure-Directory $evidence
    Write-Json (Join-Path $evidence 'RELEASE-STATUS.json') $status
    $manifest = [ordered]@{
        schemaVersion = 1; application = 'XMPlus'; version = $PackageVersion; buildMode = 'release'; target = 'windows-x64'
        flutterVersion = $sdk.frameworkVersion; dartVersion = $sdk.dartSdkVersion
        frameworkRevision = $sdk.frameworkRevision; engineRevision = $sdk.engineRevision
        engineSha256 = $engineHash; pubspecLockSha256 = $lockHash; ffmpegExecutableSha256 = $nativeFFmpegHash
        nativeBuildReceiptSha256 = File-Hash (Join-Path $NativeSupply 'BUILD-RECEIPT.json')
        fileHashScope = 'Every runtime payload file; the manifest itself stays in the separate development directory.'
        files = @(File-Inventory $bundle)
    }
    Write-Json (Join-Path $evidence 'BUILD-MANIFEST.json') $manifest
    $stagedZip = Join-Path $stage ($PackageName + '.zip')
    New-VerifiedZip $bundle $stagedZip
    $zipHash = File-Hash $stagedZip
    $stagedNoFFmpegZip = Join-Path $stage ($PackageName + '-no-ffmpeg.zip')
    New-VerifiedZip $bundle $stagedNoFFmpegZip -ExcludeFFmpeg

    # Verify the runtime ZIP before installing it; development material is separate.
    Ensure-Directory $dist
    Ensure-Directory $development
    Assert-ProjectClientsStopped
    Assert-Replacement $target $targetZip $targetNoFFmpegZip $targetSources
    $moves = @(@{ from = $bundle; to = $target }, @{ from = $stagedZip; to = $targetZip },
        @{ from = $stagedNoFFmpegZip; to = $targetNoFFmpegZip }, @{ from = $evidence; to = $targetEvidence })
    if ($stagedSources) {
        # Source watchers may hold directory handles; copy verified developer files
        # instead of renaming the tree. This never enters the application output.
        foreach ($file in File-Inventory $stagedSources) {
            Copy-File (Child-Path $stagedSources $file.path) (Child-Path $targetSources $file.path)
            Assert-Hash (Child-Path $targetSources $file.path) $file.sha256
        }
    }
    $backups = @()
    $installed = @()
    try {
        foreach ($destination in @($target, $targetZip, $targetNoFFmpegZip)) {
            if (Test-Path -LiteralPath $destination) {
                $backup = $destination + '.backup-' + [Guid]::NewGuid().ToString('N')
                Move-Item -LiteralPath $destination -Destination $backup
                $backups += @{ from = $backup; to = $destination }
            }
        }
        foreach ($move in $moves) {
            Move-Item -LiteralPath $move.from -Destination $move.to
            $installed += $move
        }
    } catch {
        for ($i = $installed.Count - 1; $i -ge 0; $i--) {
            Move-Item -LiteralPath $installed[$i].to -Destination $installed[$i].from
        }
        for ($i = $backups.Count - 1; $i -ge 0; $i--) {
            Move-Item -LiteralPath $backups[$i].from -Destination $backups[$i].to
        }
        throw
    }
    if ($UploadSentrySymbols) {
        $env:SENTRY_RELEASE = "xmplus@$PackageVersion"
        $env:SENTRY_DIST = $PackageVersion.Split('+')[1]
        $symbolArguments = @('--disable-dart-dev', '--packages=.dart_tool/package_config.json', 'tool/upload_sentry_symbols.dart', '--sentry-define=symbols_path=build/windows',
            "--sentry-define=release=$env:SENTRY_RELEASE", "--sentry-define=dist=$env:SENTRY_DIST",
            '--sentry-define=commits=false')
        foreach ($name in @('SENTRY_ORG', 'SENTRY_PROJECT')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $key = $name.Substring('SENTRY_'.Length).ToLowerInvariant()
                $symbolArguments += "--sentry-define=$key=$value"
            }
        }
        & $Dart @symbolArguments
        if ($LASTEXITCODE -ne 0) { throw "Sentry symbol upload failed with code $LASTEXITCODE." }
    }
    Write-Host "Bundle: $target"
    Write-Host "ZIP: $targetZip"
    Write-Host "ZIP SHA-256: $zipHash"
    Write-Host "ZIP without FFmpeg (libmpv retained): $targetNoFFmpegZip"
    Write-Host "Development materials (not runtime): $development"
    Write-Host "Status: $statusValue"
    Write-Host "Workspace build: $release"
    Write-Host "Packaging staging retained: $stage"
} finally {
    $env:PATH = $oldPath
    [Environment]::SetEnvironmentVariable('XMPLUS_NATIVE_SUPPLY', $oldNativeSupply, 'Process')
    [Environment]::SetEnvironmentVariable('SENTRY_RELEASE', $oldSentryRelease, 'Process')
    [Environment]::SetEnvironmentVariable('SENTRY_DIST', $oldSentryDist, 'Process')
    [Net.ServicePointManager]::SecurityProtocol = $oldTls
    Set-Location -LiteralPath $oldLocation.Path
}
