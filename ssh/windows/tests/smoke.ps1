#Requires -Version 5.1
#Requires -RunAsAdministrator
# Run only on a disposable GitHub-hosted Windows runner.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run this smoke test only on a disposable GitHub-hosted Windows runner.'
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
$setup = Join-Path $base 'setup-openssh.ps1'
$node = Join-Path $base 'lazycat-ssh-node.ps1'
$config = Join-Path $env:ProgramData 'ssh\sshd_config'
$ssh = (Get-Command ssh.exe -CommandType Application | Select-Object -First 1).Source
$keygen = (Get-Command ssh-keygen.exe -CommandType Application | Select-Object -First 1).Source
$temp = Join-Path $env:RUNNER_TEMP ('lazycat-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temp
$targetUser = 'lazycat-ci'
$otherUser = 'lazycat-ci-other'
$port = 22222
$loginKey = Join-Path $temp 'client'
$knownHosts = Join-Path $temp 'known_hosts'
$clientConfig = Join-Path $temp 'ssh_config'
try {
    & $setup -Port $port -AllowedRemoteAddress '127.0.0.1/32','::1/128' -FirewallProfile Any
    if (-not (Get-NetTCPConnection -State Listen -LocalPort $port)) { throw "sshd is not listening on $port." }
    $stock = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -PolicyStore ActiveStore -ErrorAction SilentlyContinue
    if ($stock -and $stock.Enabled -eq 'True') { throw 'The broad stock firewall rule was left enabled.' }
    $afterSetup = Get-FileHash -LiteralPath $config
    & $setup -AllowedRemoteAddress '127.0.0.1','::1' -FirewallProfile Any
    if ((Get-FileHash -LiteralPath $config).Hash -ne $afterSetup.Hash) { throw 'Re-running setup changed the SSH configuration.' }

    $password = ConvertTo-SecureString ("C!1" + [guid]::NewGuid().ToString('N')) -AsPlainText -Force
    foreach ($name in @($targetUser, $otherUser)) {
        $null = New-LocalUser -Name $name -Password $password
    }
    foreach ($name in @('ca', 'wrong-ca', 'client')) {
        $null = Invoke-TestNative $keygen @('-q', '-t', 'ed25519', '-f', (Join-Path $temp $name), '-N', '""')
    }
    $join = @{
        User = $targetUser
        Alias = 'lazycat-ci'
        Address = '127.0.0.1'
        CaPublicKeyFile = (Join-Path $temp 'ca.pub')
        Route = 'Tun'
        Via = 'ci-bastion'
    }
    $entry = (& $node @join) -join "`n"
    if ($entry -notmatch "(?m)^    tun_port: $port$" -or $entry -notmatch "(?m)^    tun_via: 'ci-bastion'$") {
        throw "Unexpected Gist entry:`n$entry"
    }
    $afterJoin = Get-FileHash -LiteralPath $config
    $null = & $node @join
    if ((Get-FileHash -LiteralPath $config).Hash -ne $afterJoin.Hash) { throw 'Re-enrollment changed the SSH configuration.' }

    $hostPublicKey = (Get-Content -LiteralPath (Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub') -Raw).Trim()
    [IO.File]::WriteAllText($knownHosts, "[127.0.0.1]:$port $hostPublicKey`n")
    [IO.File]::WriteAllText($clientConfig, '')
    $sshArgs = @('-F', $clientConfig, '-p', "$port", '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
        '-o', "UserKnownHostsFile=$($knownHosts.Replace('\', '/'))", '-o', 'StrictHostKeyChecking=yes',
        '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'ConnectTimeout=5', '-i', $loginKey)

    function Set-TestCertificate([string]$Ca, [string]$Principal, [string]$Validity = '-1m:+5m') {
        $null = Invoke-TestNative $keygen @('-s', (Join-Path $temp $Ca), '-I', 'lazycat-ci', '-n', $Principal,
            '-V', $Validity, "$loginKey.pub")
    }
    function Assert-Denied([string]$Name) {
        $output = Invoke-TestNative $ssh ($sshArgs + @("$Name@127.0.0.1", 'whoami')) 255
        if (($output -join "`n") -notmatch 'Permission denied') {
            throw "Expected authentication failure for $Name, got: $output"
        }
    }

    Assert-Denied $targetUser
    Set-TestCertificate 'ca' $targetUser
    $loggedIn = (Invoke-TestNative $ssh ($sshArgs + @("$targetUser@127.0.0.1", 'whoami'))) -join "`n"
    if ($loggedIn.Trim() -notmatch ('\\' + [regex]::Escape($targetUser) + '$')) {
        throw "Unexpected Windows identity: $loggedIn"
    }
    Set-TestCertificate 'ca' $otherUser
    Assert-Denied $targetUser
    Assert-Denied $otherUser
    Set-TestCertificate 'wrong-ca' $targetUser
    Assert-Denied $targetUser
    Set-TestCertificate 'ca' $targetUser '-10m:-5m'
    Assert-Denied $targetUser

    Set-TestCertificate 'ca' $targetUser
    $null = & $node -Remove -Confirm:$false
    if ((Get-FileHash -LiteralPath $config).Hash -ne $afterSetup.Hash) { throw 'Removal did not restore the pre-enrollment configuration.' }
    Assert-Denied $targetUser
    Write-Host 'Windows SSH setup, certificate enrollment, account scope and removal passed.'
} catch {
    if ($_ -like '*Other enabled inbound allow rule(s) overlap sshd*') {
        $appRule = Get-NetFirewallRule -PolicyStore ActiveStore -Name '*-In-Allow-ServerCapability' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($appRule) {
            $appRule | Format-List Name, Owner, PolicyStoreSourceType, EnforcementStatus | Out-Host
            $appRule | Get-NetFirewallApplicationFilter | Format-List Program, Package | Out-Host
            $appRule | Get-NetFirewallSecurityFilter | Format-List LocalUser, RemoteUser, RemoteMachine | Out-Host
        }
    }
    Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 15 -ErrorAction SilentlyContinue |
        Format-Table -Wrap -Property TimeCreated, Id, Message
    throw
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
