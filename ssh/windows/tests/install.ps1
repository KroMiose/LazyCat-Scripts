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
# The exact paste form from the docs, with the local checkout replacing the
# mirror: irm returns the UTF-8 text including the BOM, which the entry trims.
$downloaded = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($install))
if ($downloaded[0] -ne [char]0xFEFF) { throw 'install.ps1 must be saved as UTF-8 with BOM for Windows PowerShell 5.1.' }
$paste = [scriptblock]::Create($downloaded.TrimStart([char]0xFEFF))
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
    # "本地管理员" (local administrator), escaped to keep this file ASCII.
    catch { $refused = "$_" -match '\u672c\u5730\u7ba1\u7406\u5458' }
    if (-not $refused) { throw 'An administrator account was not refused.' }
    if ((Get-FileHash -LiteralPath $config).Hash -ne $beforeAdmin.Hash) { throw 'Refusing an administrator still changed sshd_config.' }

    $entry = (& $paste -CaPublicKey $caKey -Alias 'ci-paste' -Address '127.0.0.1' -User $user @common) -join "`n"
    # Only the Gist entry reaches the pipeline; progress goes to the host.
    if ($entry -notmatch "\A  'ci-paste':`n    user: '$user'`n    lan_host: '127\.0\.0\.1'`n    lan_port: $port\z") {
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
    # Loopback logins below bypass the firewall, so check the rule can match a
    # remote connection: sshd has no service SID, so a service condition never does.
    $managedRule = Get-NetFirewallRule -PolicyStore ActiveStore -Name 'LazyCat-OpenSSH-Server-In-TCP'
    $ruleService = [string]($managedRule | Get-NetFirewallServiceFilter).Service
    if ($ruleService -and $ruleService -ine 'Any') { throw "Managed firewall rule is scoped to service '$ruleService'." }
    $ruleProgram = [Environment]::ExpandEnvironmentVariables([string]($managedRule | Get-NetFirewallApplicationFilter).Program)
    if ($ruleProgram -notlike '*\OpenSSH\sshd.exe') { throw "Managed firewall rule program is '$ruleProgram'." }
    # Local files: Windows PowerShell 5.1 must decode the Chinese text ("管理员").
    foreach ($file in @($install, (Join-Path $base 'setup-openssh.ps1'), (Join-Path $base 'lazycat-ssh-node.ps1'))) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "$file does not parse: $($errors -join '; ')" }
        if ($ast.Extent.Text -notmatch '\u7ba1\u7406\u5458') { throw "$file Chinese text was not decoded as UTF-8." }
    }
    & $install -Status

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
