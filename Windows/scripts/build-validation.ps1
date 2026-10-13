[CmdletBinding()]
param([string]$Version = "1.0.76")
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Output = Join-Path $Root 'build/windows-native-validation'
function Run-Checked([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Windows validation build failed with exit code $LASTEXITCODE." }
}
Push-Location $Root
try {
    Run-Checked { python -m pip install -r Windows/Vision/requirements.txt }
    Run-Checked { python Windows/scripts/fetch-models.py }
    Run-Checked { python -m PyInstaller --noconfirm --clean --onedir --name VibeWalkieVision --collect-all mediapipe --collect-all pygrabber --distpath build/vision Windows/Vision/vision_worker.py }
    Run-Checked { swift build --package-path Shared/PostureCore -c release }
    Run-Checked { dotnet publish Windows/VibeWalkie.Companion/VibeWalkie.Companion.csproj -c Release -r win-x64 -p:WindowsPackageType=None -p:WindowsAppSDKSelfContained=true -p:SelfContained=true -p:PublishTrimmed=false -p:Version=$Version -p:AssemblyVersion="$Version.0" -p:FileVersion="$Version.0" -o $Output }
    $Vision = Join-Path $Output 'Vision'
    New-Item -ItemType Directory -Force $Vision | Out-Null
    Copy-Item build/vision/VibeWalkieVision/* $Vision -Recurse -Force
    Copy-Item Windows/Vision/models (Join-Path $Vision 'models') -Recurse -Force
    Copy-Item Windows/Vision/model-sha256.json (Join-Path $Vision 'models/model-sha256.json') -Force
    $Core = Join-Path $Output 'PostureCore'
    New-Item -ItemType Directory -Force $Core | Out-Null
    $BinPath = (& swift build --package-path Shared/PostureCore -c release --show-bin-path).Trim()
    Copy-Item (Join-Path $BinPath 'PostureCore.exe') $Core
    $Target = & swift -print-target-info | ConvertFrom-Json
    $SwiftBin = Split-Path (Get-Command swift).Source -Parent
    $RuntimePaths = @($Target.paths.runtimeLibraryPaths) + @($SwiftBin, (Join-Path $env:SDKROOT 'usr/bin'))
    foreach ($RuntimePath in $RuntimePaths | Select-Object -Unique) {
        if (Test-Path -LiteralPath $RuntimePath) {
            Get-ChildItem -LiteralPath $RuntimePath -Filter '*.dll' | Copy-Item -Destination $Core -Force
        }
    }
    if (-not (Test-Path (Join-Path $Core 'swiftCore.dll'))) { throw 'The self-contained posture runtime is incomplete: swiftCore.dll is missing.' }
    & (Join-Path $PSScriptRoot 'test-bundled-components.ps1') -Bundle $Output
    $Files = Get-ChildItem $Output -Recurse -File | ForEach-Object {
        @{ path = $_.FullName.Substring($Output.Length + 1); sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    @{ signed = $false; purpose = 'validation'; commit = $env:GITHUB_SHA; files = @($Files) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Output 'validation-manifest.json') -Encoding utf8
} finally { Pop-Location }
