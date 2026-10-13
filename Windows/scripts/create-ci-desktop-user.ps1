$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This disposable desktop account is only for the hosted GitHub Actions test machine.' }
$TestUser = 'VwCI' + ([guid]::NewGuid().ToString('N').Substring(0, 10))
$TestPassword = 'Vw!' + [guid]::NewGuid().ToString('N') + '9x'
Write-Output "::add-mask::$TestPassword"
$SecurePassword = ConvertTo-SecureString $TestPassword -AsPlainText -Force
New-LocalUser -Name $TestUser -Password $SecurePassword -PasswordNeverExpires -Description 'Disposable Vibe Walkie native integration target' | Out-Null
$UsersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
Add-LocalGroupMember -Group $UsersGroup.Name -Member $TestUser
"VIBEWALKIE_TEST_USERNAME=$TestUser" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
"VIBEWALKIE_TEST_PASSWORD=$TestPassword" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
Write-Output 'Created a real standard desktop user for the native input target.'
