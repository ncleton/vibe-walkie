[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Publisher
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Use the same three-part release version as Mac.' }
$PackageVersion = [Version]"$Version.0"
if (@($PackageVersion.Major, $PackageVersion.Minor, $PackageVersion.Build) | Where-Object { $_ -gt 65535 }) {
    throw 'MSIX version components must not exceed 65535.'
}
if ([string]::IsNullOrWhiteSpace($Publisher)) { throw 'Specify the exact package publisher.' }
$null = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new($Publisher)
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Bundle = Join-Path $Root 'build/windows-native-validation'
$Stage = Join-Path $Root 'build/windows-msix-stage'
$Executable = Join-Path $Bundle 'VibeWalkie.Companion.exe'
if (-not (Test-Path -LiteralPath $Executable)) { throw 'Build the complete native Windows bundle before packaging it.' }
$FileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($Executable).FileVersion
if ($FileVersion -ne "$Version.0") { throw "The native executable version ($FileVersion) does not match the MSIX version ($Version.0)." }
foreach ($Required in @('Vision/VibeWalkieVision.exe', 'Vision/models/model-sha256.json', 'PostureCore/PostureCore.exe', 'PostureCore/swiftCore.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Bundle $Required))) { throw "The native bundle is incomplete: $Required" }
}
if (Get-ChildItem $Bundle -Recurse -File | Where-Object { $_.Extension -in '.pfx', '.p12', '.p8' -or $_.Name -eq '.env' }) {
    throw 'Private signing or configuration files must never enter the application package.'
}
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null
Get-ChildItem $Bundle | Where-Object { $_.Name -notin @('validation-manifest.json', 'native-window-evidence.json', 'msix-validation-evidence.json', 'AppxManifest.xml') } |
    Copy-Item -Destination $Stage -Recurse -Force
[xml]$Manifest = Get-Content -Raw -Encoding utf8 (Join-Path $Root 'Windows/VibeWalkie.Companion/Package.appxmanifest')
$Manifest.Package.Identity.Version = "$Version.0"
$Manifest.Package.Identity.Publisher = $Publisher
$Manifest.Package.Resources.Resource.Language = 'fr-FR'
$Manifest.Package.Applications.Application.Executable = 'VibeWalkie.Companion.exe'
$Manifest.Package.Applications.Application.EntryPoint = 'Windows.FullTrustApplication'
$Manifest.Package.Applications.Application.Extensions.Extension.Executable = 'VibeWalkie.Companion.exe'
if ($Manifest.OuterXml -match '\$target[^$]*\$|\{\{') { throw 'The final package manifest still contains unresolved build tokens.' }
$Manifest.Save((Join-Path $Stage 'AppxManifest.xml'))
Write-Output $Stage
