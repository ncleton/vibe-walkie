[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Use the same three-part release version as Mac.' }
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Output = Join-Path $Root 'build/windows-release'
$Stage = Join-Path $Root 'build/windows-native-validation'
$Sdk = Get-ChildItem 'C:/Program Files (x86)/Windows Kits/10/bin' -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'x64/makeappx.exe') } | Sort-Object Name -Descending | Select-Object -First 1
if ($null -eq $Sdk) { throw 'Install the Windows SDK containing MakeAppx and SignTool.' }
$PfxPath = Join-Path $env:RUNNER_TEMP 'vibewalkie-windows-signing.pfx'
$Certificate = $null
try {
    if ([string]::IsNullOrWhiteSpace($env:WINDOWS_SIGNING_PFX_BASE64) -or [string]::IsNullOrWhiteSpace($env:WINDOWS_SIGNING_PUBLISHER)) {
        throw 'The trusted Windows code-signing certificate and publisher are not configured.'
    }
    [IO.File]::WriteAllBytes($PfxPath, [Convert]::FromBase64String($env:WINDOWS_SIGNING_PFX_BASE64))
    $Password = ConvertTo-SecureString $env:WINDOWS_SIGNING_PASSWORD -AsPlainText -Force
    $Certificate = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:/CurrentUser/My -Password $Password
    if ($Certificate.Subject -ne $env:WINDOWS_SIGNING_PUBLISHER -or -not $Certificate.HasPrivateKey) {
        throw 'The certificate does not match the configured publisher or has no private signing key.'
    }
    if ($Certificate.NotAfter -le (Get-Date) -or ($Certificate.EnhancedKeyUsageList.ObjectId.Value -notcontains '1.3.6.1.5.5.7.3.3')) {
        throw 'The Windows certificate is expired or is not a code-signing certificate.'
    }
    New-Item -ItemType Directory -Force $Output | Out-Null
    [xml]$Manifest = Get-Content -Raw (Join-Path $Root 'Windows/VibeWalkie.Companion/Package.appxmanifest')
    $Manifest.Package.Identity.Version = "$Version.0"
    $Manifest.Package.Identity.Publisher = $Certificate.Subject
    $Manifest.Package.Applications.Application.Executable = 'VibeWalkie.Companion.exe'
    $Manifest.Package.Applications.Application.EntryPoint = 'Windows.FullTrustApplication'
    $Manifest.Package.Applications.Application.Extensions.Extension.Executable = 'VibeWalkie.Companion.exe'
    $Manifest.Save((Join-Path $Stage 'AppxManifest.xml'))
    $Msix = Join-Path $Output "VibeWalkie-Windows-$Version.msix"
    & (Join-Path $Sdk.FullName 'x64/makeappx.exe') pack /d $Stage /p $Msix /o
    if ($LASTEXITCODE -ne 0) { throw 'MSIX packaging failed; inspect the manifest and packaged assets.' }
    & (Join-Path $Sdk.FullName 'x64/signtool.exe') sign /sha1 $Certificate.Thumbprint /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 $Msix
    if ($LASTEXITCODE -ne 0) { throw 'Trusted MSIX signing failed.' }
    & (Join-Path $Sdk.FullName 'x64/signtool.exe') verify /pa /v $Msix
    if ($LASTEXITCODE -ne 0) { throw 'The MSIX signature is not trusted by Windows. Repair the certificate chain before publishing.' }
    # Generate against the exact final manifest, not a template publisher.
    $BaseUri = "https://github.com/$($env:GITHUB_REPOSITORY)/releases/download/$($env:GITHUB_REF_NAME)"
    $AppInstaller = [IO.File]::ReadAllText((Join-Path $Root 'Windows/Packaging/VibeWalkie.appinstaller.template'))
    $AppInstaller = $AppInstaller.Replace('{{APPINSTALLER_URI}}', "https://github.com/$($env:GITHUB_REPOSITORY)/releases/download/windows-current/VibeWalkie-Windows.appinstaller")
    $AppInstaller = $AppInstaller.Replace('{{MSIX_URI}}', "$BaseUri/VibeWalkie-Windows-$Version.msix")
    $AppInstaller = $AppInstaller.Replace('{{PUBLISHER}}', [Security.SecurityElement]::Escape($Certificate.Subject)).Replace('{{VERSION}}', "$Version.0")
    [xml]$Verified = $AppInstaller
    [IO.File]::WriteAllText((Join-Path $Output 'VibeWalkie-Windows.appinstaller'), $AppInstaller, [Text.UTF8Encoding]::new($false))
    @{ version = $Version; commit = $env:GITHUB_SHA; signed = $true; subject = $Certificate.Subject; sha256 = (Get-FileHash $Msix -Algorithm SHA256).Hash.ToLowerInvariant() } |
        ConvertTo-Json | Set-Content (Join-Path $Output 'windows-release-evidence.json') -Encoding utf8
} finally {
    if (Test-Path $PfxPath) { Remove-Item -LiteralPath $PfxPath -Force }
    if ($null -ne $Certificate) { Remove-Item "Cert:/CurrentUser/My/$($Certificate.Thumbprint)" -Force }
}
