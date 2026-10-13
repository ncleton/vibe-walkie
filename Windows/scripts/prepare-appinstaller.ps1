[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $AppInstallerUri,
    [Parameter(Mandatory = $true)] [string] $MsixUri,
    [Parameter(Mandatory = $true)] [string] $Publisher,
    [Parameter(Mandatory = $true)] [string] $Version,
    [string] $OutputPath = "VibeWalkie.appinstaller"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-HttpsUri([string] $Value, [string] $Name) {
    $uri = [Uri] $Value
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne "https") {
        throw "$Name must be an absolute HTTPS URI."
    }
    return $uri
}

$appInstaller = Require-HttpsUri $AppInstallerUri "AppInstallerUri"
$msix = Require-HttpsUri $MsixUri "MsixUri"
if ($Publisher -notmatch '^CN=') { throw "Publisher must be the certificate subject (for example CN=Vibe Walkie)." }
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "Version must use four numeric components." }

$root = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $root "VibeWalkie.Companion/Package.appxmanifest"
[xml] $manifest = Get-Content -Raw $manifestPath
if ($manifest.Package.Identity.Publisher -ne $Publisher) {
    throw "Publisher does not match Package.appxmanifest. Update the manifest only after the final certificate subject is known."
}

$templatePath = Join-Path $root "Packaging/VibeWalkie.appinstaller.template"
$document = Get-Content -Raw $templatePath
$document = $document.Replace("{{APPINSTALLER_URI}}", $appInstaller.AbsoluteUri)
$document = $document.Replace("{{MSIX_URI}}", $msix.AbsoluteUri)
$document = $document.Replace("{{PUBLISHER}}", [Security.SecurityElement]::Escape($Publisher))
$document = $document.Replace("{{VERSION}}", $Version)

[xml] $verified = $document
$outputDirectory = Split-Path -Parent $OutputPath
if ([string]::IsNullOrWhiteSpace($outputDirectory)) { $outputDirectory = (Get-Location).Path }
else { $outputDirectory = (Resolve-Path -LiteralPath $outputDirectory).Path }
$finalPath = Join-Path $outputDirectory (Split-Path -Leaf $OutputPath)
[IO.File]::WriteAllText($finalPath, $document, [Text.UTF8Encoding]::new($false))
Write-Host "Wrote validated App Installer manifest: $finalPath"
