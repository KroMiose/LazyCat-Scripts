#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Enroll an existing Windows OpenSSH Server as a LazyCat SSH node.
.DESCRIPTION
Configure certificate-only login for one existing local standard user. Print a
hosts entry for the controller's Gist; no credentials for writing to Gist are needed.
Run locally, since restarting sshd can interrupt existing SSH sessions.
.EXAMPLE
.\lazycat-ssh-node.ps1 -User lazycat -Alias win-dev-01 -Address win-dev-01.example.net -CaPublicKeyFile .\lazycat-ssh-ca.pub
.PARAMETER Port
Advertised port for the controller. If omitted, discover the single effective listener port.
.PARAMETER Route
Gist route for the advertised endpoint: Lan (default), Wan or Tun.
.PARAMETER Via
Optional LazyCat alias of a jump host to use for this route.
.PARAMETER Status
Show sshd and LazyCat enrollment status without modifying the node.
.PARAMETER Remove
Remove the LazyCat trust block and restore the account's previous SSH policy.
#>
[CmdletBinding(DefaultParameterSetName = 'Join', SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ParameterSetName = 'Join')]
    [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,19}\z')]
    [string]$User,

    [Parameter(Mandatory, ParameterSetName = 'Join')]
    [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z')]
    [string]$Alias,

    [Parameter(Mandatory, ParameterSetName = 'Join')]
    [string]$Address,

    [Parameter(Mandatory, ParameterSetName = 'Join')]
    [string]$CaPublicKeyFile,

    [Parameter(ParameterSetName = 'Join')]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(ParameterSetName = 'Join')]
    [ValidateSet('Lan', 'Wan', 'Tun')]
    [string]$Route = 'Lan',

    [Parameter(ParameterSetName = 'Join')]
    [ValidatePattern('\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z')]
    [string]$Via,

    [Parameter(Mandatory, ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(Mandatory, ParameterSetName = 'Remove')]
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$begin = '# >>> LazyCat SSH Windows Node BEGIN >>>'
$end = '# <<< LazyCat SSH Windows Node END <<<'
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-NodeConfigParts([string]$Text) {
    $startPattern = '(?m)^' + [regex]::Escape($begin) + '[ \t]*\r?$'
    $endPattern = '(?m)^' + [regex]::Escape($end) + '[ \t]*\r?$'
    $starts = [regex]::Matches($Text, $startPattern)
    $ends = [regex]::Matches($Text, $endPattern)
    if ($starts.Count -eq 0 -and $ends.Count -eq 0) {
        return @{ Unmanaged = $Text; Managed = '' }
    }
    if ($starts.Count -ne 1 -or $ends.Count -ne 1 -or $starts[0].Index -ge $ends[0].Index) {
        throw 'Invalid LazyCat markers in sshd_config. Repair the managed block before continuing.'
    }
    $start = $starts[0].Index
    $after = $ends[0].Index + $ends[0].Length
    if ($after -lt $Text.Length -and $Text[$after] -eq "`n") { $after++ }
    return @{
        Unmanaged = $Text.Remove($start, $after - $start)
        Managed = $Text.Substring($start, $after - $start)
    }
}

function Add-NodeConfigBlock([string]$Text, [string]$Block) {
    # A later Match can be overridden by the first matching block. Put our
    # account-specific settings before other Match blocks, after global directives.
    $firstMatch = [regex]::Match($Text, '(?im)^[ \t]*Match(?:[ \t=]|\r?$)')
    if ($firstMatch.Success) { return $Text.Insert($firstMatch.Index, $Block) }
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += "`n" }
    return $Text + $Block
}

function Invoke-NodeOpenSsh([string]$Exe, [string[]]$Arguments) {
    # Native stderr in Windows PowerShell must not bypass the exit-code check.
    $ErrorActionPreference = 'Continue'
    $output = @(& $Exe @Arguments 2>&1 | ForEach-Object { ([string]$_).TrimEnd() })
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($Exe)) failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Assert-NodePath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to use a reparse point: $Path"
    }
}

function New-NodeCaFile([string]$Path, [string]$Contents) {
    if (Test-Path -LiteralPath $Path) {
        Assert-NodePath $Path
        if ([IO.File]::ReadAllText($Path, $utf8) -cne $Contents) {
            throw "CA file already exists with unexpected contents: $Path"
        }
    } else {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
        try {
            $bytes = $utf8.GetBytes($Contents)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    }

    # The key is public, but its integrity controls who can log in.
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($admins, $system)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-NodeAddress([string]$Value) {
    $parsed = $null
    if ($Value.Contains(':')) {
        return $Value -match '\A[0-9A-Fa-f:.]+\z' -and
            [Net.IPAddress]::TryParse($Value, [ref]$parsed)
    }
    if ($Value -match '\A[0-9.]+\z') {
        return $Value -match '\A(?:[0-9]{1,3}\.){3}[0-9]{1,3}\z' -and
            [Net.IPAddress]::TryParse($Value, [ref]$parsed)
    }
    return $Value.Length -le 253 -and
        $Value -match '\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.?\z'
}

$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'"
if (-not $service) { throw 'The sshd service is missing. Run setup-openssh.ps1 first.' }
$sshBin = Join-Path $env:WINDIR 'System32\OpenSSH'
$sshd = Join-Path $sshBin 'sshd.exe'
$keygen = Join-Path $sshBin 'ssh-keygen.exe'
$servicePath = [Environment]::ExpandEnvironmentVariables($service.PathName).Trim()
if ($servicePath -ine $sshd -and $servicePath -ine ('"' + $sshd + '"')) {
    throw "The sshd service uses a custom executable or arguments: $servicePath. This script supports Windows built-in OpenSSH with the default config path."
}
$configDir = Join-Path $env:ProgramData 'ssh'
$config = Join-Path $configDir 'sshd_config'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw 'sshd_config does not exist. Run setup-openssh.ps1 first.'
}
Assert-NodePath $configDir
Assert-NodePath $config
$original = [IO.File]::ReadAllText($config, $utf8)
$parts = Get-NodeConfigParts $original

if ($Status) {
    Write-Output "sshd: $($service.State)"
    Write-Output "Configuration: $config"
    if ($parts.Managed) { Write-Output $parts.Managed.TrimEnd() }
    else { Write-Output 'LazyCat node is not enrolled.' }
    return
}
if ($Remove -and -not $parts.Managed) {
    Write-Output 'LazyCat node is already unenrolled.'
    return
}
if ($service.State -ne 'Running') {
    throw 'sshd must be running before changing enrollment. Start it or run setup-openssh.ps1 first.'
}

$candidateText = $parts.Unmanaged
$caPath = $null
$caContents = $null
$caFingerprint = $null
if (-not $Remove) {
    if (-not (Test-NodeAddress $Address)) { throw 'Specify an IPv4 address, IPv6 address, or DNS hostname in -Address.' }
    $User = $User.ToLowerInvariant()
    $account = Get-LocalUser -Name $User
    if (-not $account.Enabled -or $account.PrincipalSource -ne 'Local') {
        throw "'$User' must be an enabled local Windows account."
    }
    $adminGroup = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    if (Get-LocalGroupMember -SID $adminGroup | Where-Object { $_.SID -eq $account.SID }) {
        throw "'$User' is a local administrator. Select a standard user for LazyCat SSH."
    }
    if ($candidateText -match '(?im)^[ \t]*(?:Include|TrustedUserCAKeys|AuthorizedPrincipalsFile|AuthorizedPrincipalsCommand)[ \t=]') {
        throw 'sshd_config already includes other configuration files or certificate policy. Review the existing SSH policy before enrolling this host.'
    }
    if ($candidateText -match '(?im)^[ \t]*AuthenticationMethods[ \t=]+(?!(?:any|publickey)(?:[ \t]*(?:#.*)?\r?$))') {
        throw 'sshd_config has a custom AuthenticationMethods policy. Review it before enrolling this host.'
    }
    $effective = @(Invoke-NodeOpenSsh $sshd @('-T', '-f', $config))
    if (-not $PSBoundParameters.ContainsKey('Port')) {
        $ports = @($effective | ForEach-Object {
            if ($_ -match '^listenaddress\s+\S+:(\d+)\s*$') { [int]$Matches[1] }
        } | Sort-Object -Unique)
        if ($ports.Count -ne 1) { throw 'Could not infer one listener port. Set the advertised port with -Port.' }
        $Port = $ports[0]
    }

    $source = (Resolve-Path -LiteralPath $CaPublicKeyFile).ProviderPath
    $publicKey = [IO.File]::ReadAllText($source, $utf8).Trim()
    if ($publicKey -cnotmatch '\A(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))[ \t]+([A-Za-z0-9+/]+={0,2})(?:[ \t]+[^\r\n]*)?\z') {
        throw 'Expected a single SSH CA public key (Ed25519, RSA or ECDSA) in -CaPublicKeyFile.'
    }
    $caContents = "$($Matches[1]) $($Matches[2])`n"
    $blob = [Convert]::FromBase64String($Matches[2])
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $hash = [Convert]::ToBase64String($sha256.ComputeHash($blob)).TrimEnd('=') }
    finally { $sha256.Dispose() }
    $keyId = $hash.Replace('+', '-').Replace('/', '_')
    $caPath = Join-Path $configDir "lazycat-user-ca-$keyId.pub"
    $configCaPath = $caPath.Replace('\', '/')
    $lineEnd = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
    # Leave AuthorizedPrincipalsFile unset so OpenSSH matches the account name.
    # Some versions interpret an explicit "none" as a filename.
    $block = @(
        $begin
        "Match User $User"
        "    TrustedUserCAKeys `"$configCaPath`""
        '    AuthorizedKeysFile none'
        '    PubkeyAuthentication yes'
        '    PasswordAuthentication no'
        '    AuthenticationMethods publickey'
        $end
    ) -join $lineEnd
    $candidateText = Add-NodeConfigBlock $candidateText ($block + $lineEnd)
}

$action = if ($Remove) { 'Remove LazyCat SSH trust and restart sshd' } else { "Enroll Windows user '$User' in LazyCat SSH" }
if (-not $PSCmdlet.ShouldProcess($config, $action)) { return }

$tempConfig = Join-Path $configDir ('.lazycat-node-' + [guid]::NewGuid() + '.tmp')
$backup = "$config.lazycat-node-$([guid]::NewGuid()).bak"
$replaced = $false
$newCaFile = $false
try {
    if ($caPath) {
        $newCaFile = -not (Test-Path -LiteralPath $caPath)
        New-NodeCaFile $caPath $caContents
        $caFingerprint = (Invoke-NodeOpenSsh $keygen @('-l', '-E', 'sha256', '-f', $caPath)) -join ' '
        if ($caFingerprint -cnotmatch ('\bSHA256:' + [regex]::Escape($hash) + '(?:\s|$)')) {
            throw 'The CA file did not validate as an SSH public key.'
        }
    }
    [IO.File]::WriteAllText($tempConfig, $candidateText, $utf8)
    Set-Acl -LiteralPath $tempConfig -AclObject (Get-Acl -LiteralPath $config)
    $null = Invoke-NodeOpenSsh $sshd @('-t', '-f', $tempConfig)
    if ($caPath) {
        $scoped = @(Invoke-NodeOpenSsh $sshd @('-T', '-f', $tempConfig, '-C',
            "user=$User,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=$Port"))
        $expectedCa = "trustedusercakeys $configCaPath"
        if (($scoped -inotcontains $expectedCa -and $scoped -inotcontains "trustedusercakeys $caPath") -or
            $scoped -notcontains 'authorizedprincipalsfile none' -or $scoped -notcontains 'authorizedkeysfile none' -or
            $scoped -notcontains 'pubkeyauthentication yes' -or $scoped -notcontains 'passwordauthentication no' -or
            $scoped -notcontains 'authenticationmethods publickey') {
            throw "sshd did not apply the expected certificate-only settings for '$User'."
        }
        $unscoped = @(Invoke-NodeOpenSsh $sshd @('-T', '-f', $tempConfig))
        if ($unscoped -notcontains 'trustedusercakeys none') { throw 'The CA trust is not scoped to the intended user.' }
    }
    if ($candidateText -cne $original) {
        if ([IO.File]::ReadAllText($config, $utf8) -cne $original) {
            throw 'sshd_config was modified during enrollment. Re-run the command.'
        }
        [IO.File]::Replace($tempConfig, $config, $backup)
        $replaced = $true
        Restart-Service -Name sshd
        (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        Write-Host "Saved previous configuration to $backup"
    }
} catch {
    if ($replaced) {
        try {
            [IO.File]::Replace($backup, $config, "$backup.failed")
            Restart-Service -Name sshd
            (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
            Write-Warning "Restored previous SSH configuration. Rejected configuration: $backup.failed"
            $replaced = $false
        } catch { Write-Warning "Rollback failed: $_. Check $config and backups at $configDir." }
    }
    if ($newCaFile -and -not $replaced) {
        Remove-Item -LiteralPath $caPath -Force -ErrorAction SilentlyContinue
    }
    throw
} finally {
    Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
}

if ($Remove) {
    Write-Output 'LazyCat trust removed. Remove the Gist entry separately if this host should no longer appear on controllers.'
    return
}
Write-Host "CA fingerprint: $caFingerprint"
Write-Host "Merge this entry into the existing hosts map in the controller Gist, then sync and verify: ssh $Alias whoami"
$routeKey = $Route.ToLowerInvariant()
Write-Output @"
  '${Alias}':
    user: '$User'
    ${routeKey}_host: '$Address'
    ${routeKey}_port: $Port
"@
if ($Via) { Write-Output "    ${routeKey}_via: '$Via'" }
