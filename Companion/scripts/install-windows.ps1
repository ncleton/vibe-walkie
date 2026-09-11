param([string]$Python = "py")
$ErrorActionPreference = "Stop"
$Source = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Install = Join-Path $env:LOCALAPPDATA "VibeWalkie\runtime"
$PythonArguments = @()
if ([IO.Path]::GetFileNameWithoutExtension($Python) -eq "py") { $PythonArguments += "-3" }
& $Python @PythonArguments -m venv $Install
if ($LASTEXITCODE -ne 0) { throw "Install Python 3.11 or newer from python.org and rerun this installer." }
$Runtime = Join-Path $Install "Scripts\python.exe"
& $Runtime -m pip install $Source
if ($LASTEXITCODE -ne 0) { throw "Companion dependency installation failed. Check network access and the pip error above." }
$Executable = Join-Path $Install "Scripts\vibewalkie.exe"
$Shell = New-Object -ComObject WScript.Shell
$Link = $Shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "Vibe Walkie.lnk"))
$Link.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$QuotedExecutable = $Executable.Replace("'", "''")
# Keep the console visible when setup or permissions fail, so the user can
# read the actionable error and retry from the same terminal.
$Link.Arguments = "-NoLogo -NoProfile -NoExit -Command `"& '$QuotedExecutable' serve`""
$Link.WorkingDirectory = $Install
$Link.Save()
Write-Host "Installed. Start Vibe Walkie from your Desktop after connecting Tailscale."
Write-Host "Pair from another PowerShell window: & '$Executable' pair --qr '$env:USERPROFILE\Desktop\VibeWalkie-pair.png'"
