#Requires -Version 5.1
#Requires -RunAsAdministrator
# Run only on a disposable GitHub-hosted Windows runner, after smoke.ps1: it
# reuses that OpenSSH install (port 22222) and its AllowGroups test group.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run this test only on a disposable GitHub-hosted Windows runner.'
}

function Invoke-TestNative([string]$Exe, [string[]]$Arguments, [int]$ExpectedExit = 0) {
    $ErrorActionPreference = 'Continue'
    $output = @(& $Exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne $ExpectedExit) {
        throw "$Exe returned $LASTEXITCODE, expected ${ExpectedExit}: $($output -join "`n")"
    }
    return $output
}

$base = Split-Path $PSScriptRoot -Parent
$install = Join-Path $base 'install.ps1'
$config = Join-Path $env:ProgramData 'ssh\sshd_config'
$ssh = (Get-Command ssh.exe -CommandType Application | Select-Object -First 1).Source
$keygen = (Get-Command ssh-keygen.exe -CommandType Application | Select-Object -First 1).Source
$temp = Join-Path $env:RUNNER_TEMP ('lazycat-install-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temp
$user = 'lazycat-paste'
$port = 22222
$loginKey = Join-Path $temp 'client'
$knownHosts = Join-Path $temp 'known_hosts'
$clientConfig = Join-Path $temp 'ssh_config'
# The exact paste form from the docs, with the local checkout replacing the mirror.
$paste = [scriptblock]::Create([IO.File]::ReadAllText($install))
$common = @{ AllowedRemoteAddress = @('192.0.2.0/24', '2001:db8::/64'); FirewallProfile = 'Any'; Source = $base; Yes = $true }
try {
    foreach ($name in @('ca', 'client')) {
        $null = Invoke-TestNative $keygen @('-q', '-t', 'ed25519', '-f', (Join-Path $temp $name), '-N', '""')
    }
    $caKey = (Get-Content -LiteralPath (Join-Path $temp 'ca.pub') -Raw).Trim()
    if (Get-LocalUser -Name $user -ErrorAction SilentlyContinue) { throw "$user already exists on this runner." }

    $beforeAdmin = Get-FileHash -LiteralPath $config
    $refused = $false
    try { $null = & $paste -CaPublicKey $caKey -Alias 'ci-admin' -Address '127.0.0.1' -User $env:USERNAME @common }
    catch { $refused = "$_" -match 'local administrator' }
    if (-not $refused) { throw 'An administrator account was not refused.' }
    if ((Get-FileHash -LiteralPath $config).Hash -ne $beforeAdmin.Hash) { throw 'Refusing an administrator still changed sshd_config.' }

    $entry = (& $paste -CaPublicKey $caKey -Alias 'ci-paste' -Address '127.0.0.1' -User $user @common) -join "`n"
    if ($entry -notmatch "(?m)^    user: '$user'$" -or $entry -notmatch "(?m)^    lan_port: $port$") {
        throw "Unexpected Gist entry:`n$entry"
    }
    $account = Get-LocalUser -Name $user
    if (-not $account.Enabled) { throw "$user was not created enabled." }
    if (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID -eq $account.SID }) { throw "$user was made an administrator." }
    if (-not (Get-LocalGroupMember -SID 'S-1-5-32-545' | Where-Object { $_.SID -eq $account.SID })) { throw "$user is not in Users." }
    # smoke.ps1 restricts the Server image to this group; see the comment there.
    Add-LocalGroupMember -Name 'lazycat-ci-ssh' -Member $user

    $afterJoin = Get-FileHash -LiteralPath $config
    $null = & $paste -CaPublicKey $caKey -Alias 'ci-paste' -Address '127.0.0.1' -User $user @common
    if ((Get-FileHash -LiteralPath $config).Hash -ne $afterJoin.Hash) { throw 'Re-running the paste entry changed sshd_config.' }
    $null = & $paste -Status -Source $base

    $hostPublicKey = (Get-Content -LiteralPath (Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub') -Raw).Trim()
    [IO.File]::WriteAllText($knownHosts, "[127.0.0.1]:$port $hostPublicKey`n")
    [IO.File]::WriteAllText($clientConfig, '')
    $sshArgs = @('-F', $clientConfig, '-p', "$port", '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', "UserKnownHostsFile=$($knownHosts.Replace('\', '/'))", '-o', 'StrictHostKeyChecking=yes',
        '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'ConnectTimeout=5', '-i', $loginKey)
    $null = Invoke-TestNative $keygen @('-s', (Join-Path $temp 'ca'), '-I', 'lazycat-ci', '-n', $user, '-V', '-1m:+5m', "$loginKey.pub")
    $loggedIn = (Invoke-TestNative $ssh ($sshArgs + @("$user@127.0.0.1", 'whoami'))) -join "`n"
    if ($loggedIn.Trim() -notmatch ('\\' + [regex]::Escape($user) + '$')) { throw "Unexpected Windows identity: $loggedIn" }

    $null = & $paste -Remove -Source $base -Yes
    $output = Invoke-TestNative $ssh ($sshArgs + @("$user@127.0.0.1", 'whoami')) 255
    if (($output -join "`n") -notmatch 'Permission denied') { throw "Expected login to fail after removal, got: $output" }
    if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) { throw 'Removal deleted the account; it should be kept.' }
    Write-Host 'Paste entry: admin refusal, account creation, enrollment, idempotence, login and removal passed.'
} catch {
    Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 15 -ErrorAction SilentlyContinue |
        Format-Table -Wrap -Property TimeCreated, Id, Message
    throw
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

# The last native command deliberately tests a rejected login.
exit 0
