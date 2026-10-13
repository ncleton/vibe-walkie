$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Executable = Join-Path $Root 'build/windows-native-validation/VibeWalkie.Companion.exe'
$Process = Start-Process -FilePath $Executable -PassThru
try {
    $Window = $null
    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        $Process.Refresh()
        if ($Process.HasExited) { throw "The actual WinUI companion exited during startup (exit $($Process.ExitCode))." }
        if ($Process.MainWindowHandle -ne 0) {
            $Window = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
            if ($null -ne $Window) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $Window) { throw 'The real WinUI window did not become accessible.' }
    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $Buttons = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
    $Names = @($Buttons | ForEach-Object { $_.Current.Name })
    foreach ($Required in @('Nouveau QR', 'Démarrer le coach', 'Appliquer les commandes', 'Rechercher une mise à jour', 'Quitter Vibe Walkie')) {
        if ($Names -notcontains $Required) { throw "The actual WinUI window is missing the expected control: $Required" }
    }
    # Only UI control names are exported. Never export the generated pairing QR,
    # confirmation secret, TLS identity, screenshots or the user's camera.
    @{ nativeWindow = $true; title = $Window.Current.Name; requiredControls = $true } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'build/windows-native-validation/native-window-evidence.json') -Encoding utf8
} finally {
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
}
