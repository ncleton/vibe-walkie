[CmdletBinding()]
param([string]$Version = '1.0.76')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Output = Join-Path $Root 'build/windows-msix-validation'
$Unpacked = Join-Path $Root 'build/windows-msix-roundtrip'
[xml]$Source = Get-Content -Raw -Encoding utf8 (Join-Path $Root 'Windows/VibeWalkie.Companion/Package.appxmanifest')
# A declared package identity is not a signing certificate. This check never
# creates trust, signs, installs, registers or publishes the unsigned package.
$Publisher = [string]$Source.Package.Identity.Publisher
$Stage = & (Join-Path $PSScriptRoot 'prepare-package.ps1') -Version $Version -Publisher $Publisher
$Sdk = Get-ChildItem 'C:/Program Files (x86)/Windows Kits/10/bin' -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'x64/makeappx.exe') } | Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $Sdk) { throw 'Install the Windows SDK containing MakeAppx.' }
$MakeAppx = Join-Path $Sdk.FullName 'x64/makeappx.exe'
New-Item -ItemType Directory -Force $Output | Out-Null
$Package = Join-Path $Output 'VibeWalkie-Windows-unsigned-validation.msix'
& $MakeAppx pack /d $Stage /p $Package /o
if ($LASTEXITCODE -ne 0) { throw 'The real Windows SDK rejected the MSIX package or its manifest.' }
if (Test-Path -LiteralPath $Unpacked) { Remove-Item -LiteralPath $Unpacked -Recurse -Force }
& $MakeAppx unpack /p $Package /d $Unpacked /o
if ($LASTEXITCODE -ne 0) { throw 'The real Windows SDK could not unpack the generated MSIX.' }
if (Test-Path (Join-Path $Unpacked 'AppxSignature.p7x')) { throw 'The validation package unexpectedly contains a signature.' }
$Compared = 0
foreach ($File in Get-ChildItem $Stage -Recurse -File) {
    $Relative = $File.FullName.Substring($Stage.Length + 1)
    $Other = Join-Path $Unpacked $Relative
    if (-not (Test-Path -LiteralPath $Other) -or (Get-FileHash $File.FullName -Algorithm SHA256).Hash -ne (Get-FileHash $Other -Algorithm SHA256).Hash) {
        throw "MSIX packaging altered or omitted a bundled file: $Relative"
    }
    $Compared++
}
[xml]$Manifest = Get-Content -Raw -Encoding utf8 (Join-Path $Unpacked 'AppxManifest.xml')
if ($Manifest.Package.Identity.Version -ne "$Version.0" -or $Manifest.Package.Identity.Publisher -ne $Publisher) {
    throw 'The packaged application identity or version does not match the prepared manifest.'
}
$Manager = [Xml.XmlNamespaceManager]::new($Manifest.NameTable)
$Manager.AddNamespace('d', 'http://schemas.microsoft.com/appx/manifest/desktop/windows10')
$Startup = $Manifest.SelectSingleNode('//d:Extension[@Category="windows.startupTask"]/d:StartupTask', $Manager)
if ($null -eq $Startup -or $Startup.GetAttribute('TaskId') -ne 'VibeWalkieStartup') { throw 'The real package has no valid desktop startup task.' }
@{ purpose = 'validation'; signed = $false; installed = $false; commit = $env:GITHUB_SHA;
    version = "$Version.0"; sdkValidation = $true; comparedFiles = $Compared;
    sha256 = (Get-FileHash $Package -Algorithm SHA256).Hash.ToLowerInvariant() } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Output 'msix-validation-evidence.json') -Encoding utf8
Write-Output "Windows SDK MSIX validation and $Compared file roundtrips passed. Trusted installation and updates still require real signing."
