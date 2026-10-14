param([string]$EvidenceDirectory = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Executable = Join-Path $Root 'build/windows-native-validation/VibeWalkie.Companion.exe'
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) { $EvidenceDirectory = Join-Path $Root 'build/windows-native-validation' }
if (-not (Test-Path -LiteralPath $EvidenceDirectory)) { New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null }
$env:VIBEWALKIE_UI_DIAGNOSTIC_PATH = Join-Path $EvidenceDirectory 'ui-startup.log'
if (Test-Path $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH) { Remove-Item -LiteralPath $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH }
# Create the GUI process directly so the test's environment and desktop are
# inherited by this exact process, including the opt-in stage diagnostic path.
$Start = [Diagnostics.ProcessStartInfo]::new($Executable)
$Start.UseShellExecute = $false
$Start.WorkingDirectory = Split-Path -Parent $Executable
$Start.EnvironmentVariables['VIBEWALKIE_UI_DIAGNOSTIC_PATH'] = $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH
$Process = [Diagnostics.Process]::Start($Start)
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
        $Modules = @($Process.Modules | ForEach-Object { $_.ModuleName })
        $Metadata = 'startup_modules ' + ($Modules -join ',')
        Add-Content -LiteralPath $env:VIBEWALKIE_UI_DIAGNOSTIC_PATH -Value $Metadata
        throw "The real WinUI window did not become accessible. App session: $($Process.SessionId); verifier session: $((Get-Process -Id $PID).SessionId)."
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
    function Invoke-NativeButton([string]$Label) {
        $Button = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition) |
            Where-Object { $_.Current.Name -eq $Label } | Select-Object -First 1
        if ($null -eq $Button) { throw "The real window has no button: $Label" }
        ([System.Windows.Automation.InvokePattern]$Button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
    }
    function Require-NativeText([string]$Expected) {
        $TextCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text)
        for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
            $Texts = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $TextCondition)
            if (@($Texts | Where-Object { $_.Current.Name.Contains($Expected) }).Count -gt 0) { return }
            Start-Sleep -Milliseconds 100
        }
        throw 'The real companion did not display the expected actionable state.'
    }
    $TitleCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'control-title-upper_left')
    $TitleField = $null
    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        $TitleField = $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $TitleCondition)
        if ($null -ne $TitleField) { break }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $TitleField) { throw 'The actual seven-zone command editor was not populated.' }
    $Value = [System.Windows.Automation.ValuePattern]$TitleField.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $Value.SetValue('Validation Windows')
    Invoke-NativeButton 'Appliquer les commandes'
    Add-Type -AssemblyName System.Security
    $ConfigurationPath = Join-Path $env:LOCALAPPDATA 'VibeWalkie/configuration.dpapi'
    $Persisted = $false
    for ($Attempt = 0; $Attempt -lt 100; $Attempt++) {
        if (Test-Path -LiteralPath $ConfigurationPath) {
            $Bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($ConfigurationPath), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $Configuration = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json
            $UpperLeft = $Configuration.buttons | Where-Object { $_.zone -eq 'upper_left' }
            if ($Configuration.buttons.Count -eq 7 -and $UpperLeft.title -eq 'Validation Windows') { $Persisted = $true; break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $Persisted) { throw 'Applying the real command editor did not persist the verified DPAPI configuration.' }
    Invoke-NativeButton 'Rechercher une mise à jour'
    Require-NativeText 'Installez le paquet MSIX signé'
    Invoke-NativeButton 'Démarrer le coach'
    Require-NativeText 'Actualisez les caméras'
    $WindowTitle = $Window.Current.Name
    $Quit = $Buttons | Where-Object { $_.Current.Name -eq 'Quitter Vibe Walkie' } | Select-Object -First 1
    $Invoke = [System.Windows.Automation.InvokePattern]$Quit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $Invoke.Invoke()
    if (-not $Process.WaitForExit(30000)) { throw 'The actual companion did not exit after its native Quit button was invoked.' }
    if ($Process.ExitCode -ne 0) { throw "The actual companion failed during shutdown (exit $($Process.ExitCode))." }
    # Only UI control names are exported. Never export the generated pairing QR,
    # confirmation secret, TLS identity, screenshots or the user's camera.
    @{ nativeWindow = $true; title = $WindowTitle; requiredControls = $true; runtimeStarted = $true; gracefulExit = $true; configurationPersisted = $true; unpackagedUpdateError = $true; cameraSelectionError = $true } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'native-window-evidence.json') -Encoding utf8
} finally {
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
}
