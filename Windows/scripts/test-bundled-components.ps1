[CmdletBinding()]
param([Parameter(Mandatory)][string]$Bundle)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Run-Bundled([string]$Executable, [string[]]$Arguments) {
    $Start = [System.Diagnostics.ProcessStartInfo]::new($Executable)
    $Start.UseShellExecute = $false
    $Start.CreateNoWindow = $true
    $Start.RedirectStandardInput = $true
    $Start.RedirectStandardOutput = $true
    $Start.RedirectStandardError = $true
    # A user's installation must run without the CI Swift/Python toolchains.
    $Start.Environment['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot"
    foreach ($Argument in $Arguments) { $Start.ArgumentList.Add($Argument) }
    $Process = [System.Diagnostics.Process]::Start($Start)
    try {
        $Process.StandardInput.Close()
        $Output = $Process.StandardOutput.ReadToEndAsync()
        $Errors = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit(25000)) {
            $Process.Kill($true)
            throw "The bundled component did not terminate: $Executable"
        }
        $Text = $Output.GetAwaiter().GetResult()
        $ErrorText = $Errors.GetAwaiter().GetResult()
        if ($Process.ExitCode -ne 0) {
            throw "The bundled component failed (exit $($Process.ExitCode)): $Executable; $ErrorText; $Text"
        }
        return $Text
    } finally { $Process.Dispose() }
}
$Vision = Join-Path $Bundle 'Vision/VibeWalkieVision.exe'
$Models = Join-Path $Bundle 'Vision/models'
$CameraList = (Run-Bundled $Vision @('--models', $Models, '--list')).Trim()
if (-not ($CameraList.StartsWith('[') -and $CameraList.EndsWith(']'))) {
    throw 'The bundled camera worker did not return the real camera inventory.'
}
$null = $CameraList | ConvertFrom-Json
$Core = Join-Path $Bundle 'PostureCore/PostureCore.exe'
$Output = Run-Bundled $Core @()
if (-not [string]::IsNullOrWhiteSpace($Output)) { throw 'The bundled posture engine returned unexpected output without input.' }
Write-Output 'The packaged camera worker and shared posture engine run without the CI toolchain on PATH. Physical camera validation is still required.'
