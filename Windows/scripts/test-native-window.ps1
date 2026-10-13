$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Executable = Join-Path $Root 'build/windows-native-validation/VibeWalkie.Companion.exe'
$env:VIBEWALKIE_UI_DIAGNOSTIC_PATH = Join-Path $env:RUNNER_TEMP 'vibewalkie-ui-startup.log'
if (Test-Path $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH) { Remove-Item -LiteralPath $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH }
$Process = Start-Process -FilePath $Executable -PassThru
try {
    $Window = $null
    $ProcessCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$Process.Id)
    for ($Attempt = 0; $Attempt -lt 300; $Attempt++) {
        $Process.Refresh()
        if ($Process.HasExited) { throw "The actual WinUI companion exited during startup (exit $($Process.ExitCode))." }
        # WinUI's top-level window can be missed by Process.MainWindowHandle.
        # Query the actual automation tree by the launched process identity.
        $Window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children, $ProcessCondition)
        if ($null -ne $Window -and $Window.Current.Name -eq 'Vibe Walkie') { break }
        $Window = $null
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $Window) {
        if (Test-Path $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH) { Get-Content $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH }
        Write-Output "UI process session: $($Process.SessionId); test session: $((Get-Process -Id $PID).SessionId)"
        throw 'The real WinUI window did not become accessible.'
    }
    $RuntimeStarted = $false
    for ($Attempt = 0; $Attempt -lt 300; $Attempt++) {
        if (Test-Path $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH) {
            $Stages = @(Get-Content -LiteralPath $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH)
            if ($Stages -match " $($Process.Id) runtime_error_") {
                $Stages | Write-Output
                throw 'The actual companion displayed a window but its runtime failed to start.'
            }
            if ($Stages -match " $($Process.Id) runtime_started$") { $RuntimeStarted = $true; break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $RuntimeStarted) { throw 'The actual companion runtime did not start.' }
    $Condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $Buttons = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
    $Names = @($Buttons | ForEach-Object { $_.Current.Name })
    foreach ($Required in @('Nouveau QR', 'Démarrer le coach', 'Appliquer les commandes', 'Rechercher une mise à jour', 'Quitter Vibe Walkie')) {
        if ($Names -notcontains $Required) { throw "The actual WinUI window is missing the expected control: $Required" }
    }
    $WindowTitle = $Window.Current.Name
    $Quit = $Buttons | Where-Object { $_.Current.Name -eq 'Quitter Vibe Walkie' } | Select-Object -First 1
    $Invoke = [System.Windows.Automation.InvokePattern]$Quit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $Invoke.Invoke()
    if (-not $Process.WaitForExit(30000)) { throw 'The actual companion did not exit after its native Quit button was invoked.' }
    if ($Process.ExitCode -ne 0) { throw "The actual companion failed during shutdown (exit $($Process.ExitCode))." }
    # Only UI control names are exported. Never export the generated pairing QR,
    # confirmation secret, TLS identity, screenshots or the user's camera.
    @{ nativeWindow = $true; title = $WindowTitle; requiredControls = $true; runtimeStarted = $true; gracefulExit = $true } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'build/windows-native-validation/native-window-evidence.json') -Encoding utf8
} finally {
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
}
