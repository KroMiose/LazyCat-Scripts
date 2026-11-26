<#
.SYNOPSIS
One-paste entry for enrolling a Windows device as a LazyCat SSH node.
.DESCRIPTION
Run from an administrator Windows PowerShell (it relaunches itself elevated
when needed):

  & ([scriptblock]::Create((irm https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/windows/install.ps1)))

Without parameters it shows a menu and asks only for what it cannot infer.
It downloads setup-openssh.ps1 and lazycat-ssh-node.ps1 next to each other
under %ProgramData%\LazyCat\ssh-windows, installs the built-in OpenSSH
Server, creates the standard login account when missing, and enrolls the
LazyCat CA. Both scripts stay idempotent; re-running keeps their state.
.PARAMETER CaPublicKey
The CA public key line (cat ~/.lazycat/ssh-ca/lazycat-ssh-ca.pub on the CA host).
.PARAMETER Alias
Controller alias. Defaults to the lowercase computer name.
.PARAMETER Address
Address the controller connects to. Defaults to the IPv4 address of the
interface that holds the default route.
.PARAMETER User
Standard local account for certificate login. Created when missing. Defaults to lazycat.
.PARAMETER AllowedRemoteAddress
Firewall sources passed to setup-openssh.ps1. Defaults to LocalSubnet.
.PARAMETER FirewallProfile
Firewall profiles. Defaults to Domain,Private, plus the current profile when
the active network is Public and you agree.
.PARAMETER Source
Directory or URL holding the two scripts. Defaults to the directory of this
file when it has them, otherwise LAZYCAT_SSH_WINDOWS_SOURCE or the ep mirror.
.PARAMETER Yes
Accept defaults without asking. Missing required values become errors.
#>
[CmdletBinding(DefaultParameterSetName = 'Join')]
param(
    [Parameter(ParameterSetName = 'Join')][string]$CaPublicKey,
    [Parameter(ParameterSetName = 'Join')][string]$Alias,
    [Parameter(ParameterSetName = 'Join')][string]$Address,
    [Parameter(ParameterSetName = 'Join')][string]$User = 'lazycat',
    [Parameter(ParameterSetName = 'Join')][string[]]$AllowedRemoteAddress,
    [Parameter(ParameterSetName = 'Join')][ValidateSet('Domain', 'Private', 'Public', 'Any')][string[]]$FirewallProfile,
    [Parameter(ParameterSetName = 'Join')][ValidateRange(1, 65535)][int]$Port,
    [Parameter(ParameterSetName = 'Join')][ValidateSet('Lan', 'Wan', 'Tun')][string]$Route = 'Lan',
    [Parameter(ParameterSetName = 'Join')][string]$Via,
    [Parameter(Mandatory, ParameterSetName = 'Status')][switch]$Status,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove,
    [string]$Source,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$mirror = 'https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/windows'
$scripts = @('setup-openssh.ps1', 'lazycat-ssh-node.ps1')
$work = Join-Path $env:ProgramData 'LazyCat\ssh-windows'
# $PSCommandPath is empty when pasted through [scriptblock]::Create.
$selfPath = if ($PSCommandPath) { $PSCommandPath } else { $null }

function Format-Literal([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

function Read-Default([string]$Prompt, [string]$Default) {
    if ($Yes) { return $Default }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-Host "$Prompt$suffix"
    if ($answer.Trim()) { return $answer.Trim() }
    return $Default
}

function Confirm-Step([string]$Prompt, [bool]$Default = $true) {
    if ($Yes) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = (Read-Host "$Prompt ($hint)").Trim()
    if (-not $answer) { return $Default }
    return $answer -match '^(y|yes)$'
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    # Re-run the same entry with the parameters already given. EncodedCommand
    # avoids quoting problems with key comments and paths.
    $invocation = if ($selfPath) { '& ' + (Format-Literal $selfPath) }
        else { "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; & ([scriptblock]::Create((Invoke-RestMethod $(Format-Literal "$mirror/install.ps1"))))" }
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        $value = $entry.Value
        if ($value -is [switch]) { if ($value.IsPresent) { $invocation += " -$($entry.Key)" } }
        elseif ($value -is [array]) { $invocation += " -$($entry.Key) " + (($value | ForEach-Object { Format-Literal ([string]$_) }) -join ',') }
        else { $invocation += " -$($entry.Key) " + (Format-Literal ([string]$value)) }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    Write-Host 'Administrator rights are required. Approve the UAC prompt to continue in a new window.'
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
}

function Get-Scripts {
    $origin = $Source
    if (-not $origin -and $selfPath) {
        $local = Split-Path -Parent $selfPath
        if (@($scripts | Where-Object { -not (Test-Path -LiteralPath (Join-Path $local $_)) }).Count -eq 0) { $origin = $local }
    }
    if (-not $origin) { $origin = if ($env:LAZYCAT_SSH_WINDOWS_SOURCE) { $env:LAZYCAT_SSH_WINDOWS_SOURCE } else { $mirror } }
    $null = New-Item -ItemType Directory -Force -Path $work
    $remote = $origin -match '^https?://'
    if ($remote) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
    foreach ($name in $scripts) {
        $target = Join-Path $work $name
        $partial = "$target.download"
        if ($remote) { Invoke-WebRequest -UseBasicParsing -Uri ($origin.TrimEnd('/') + "/$name") -OutFile $partial }
        else { Copy-Item -LiteralPath (Join-Path $origin $name) -Destination $partial -Force }
        # Reject an empty or truncated download before replacing a working copy.
        $text = [IO.File]::ReadAllText($partial)
        if ($text -notmatch '\A#Requires -Version 5\.1' -or $text -notmatch '(?m)^\$ErrorActionPreference = ''Stop''') {
            Remove-Item -LiteralPath $partial -Force
            throw "Downloaded $name is incomplete or unexpected; nothing was changed."
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
    }
    # Local files are subject to the execution policy; pasted entries are not.
    try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { Write-Warning "Could not relax the process execution policy: $_" }
    @{ Setup = (Join-Path $work $scripts[0]); Node = (Join-Path $work $scripts[1]) }
}

function Get-DefaultAddress {
    $config = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    $addresses = @(if ($config) { $config.IPv4Address })
    if ($addresses.Count -gt 0) { return $addresses[0].IPAddress }
    return ''
}

function Get-DefaultAlias {
    $name = ($env:COMPUTERNAME.ToLowerInvariant() -replace '[^a-z0-9._-]', '-').Trim('-')
    if ($name -notmatch '\A[a-z0-9]') { $name = 'win-' + $name }
    return $name
}

function New-StandardUser([string]$Name) {
    # A random password satisfies local policy; certificate login never uses it.
    $password = ConvertTo-SecureString ('Lc!1' + [guid]::NewGuid().ToString('N')) -AsPlainText -Force
    $null = New-LocalUser -Name $Name -Password $password -PasswordNeverExpires -AccountNeverExpires -Description 'LazyCat SSH certificate login'
    # Users by SID, so localized Windows editions work too.
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $Name
    Write-Host "Created standard local account '$Name'."
}

function Invoke-Join($files) {
    $key = $CaPublicKey
    while (-not $key) {
        if ($Yes) { throw 'Specify -CaPublicKey.' }
        Write-Host 'Paste the CA public key. On the CA host run: cat ~/.lazycat/ssh-ca/lazycat-ssh-ca.pub'
        $key = (Read-Host 'CA public key').Trim()
    }
    if ($key.Trim() -cnotmatch '\A(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))[ \t]+[A-Za-z0-9+/]+={0,2}([ \t]+[^\r\n]*)?\z') {
        throw 'The CA public key must be one line starting with ssh-ed25519, ssh-rsa or ecdsa-sha2-*.'
    }
    $alias = if ($Alias) { $Alias } else { Read-Default 'Alias on the controller' (Get-DefaultAlias) }
    $address = if ($Address) { $Address } else { Read-Default 'Address the controller connects to' (Get-DefaultAddress) }
    if (-not $address) { throw 'Could not detect an address. Specify -Address.' }
    $account = $User.ToLowerInvariant()
    $sources = if ($AllowedRemoteAddress) { $AllowedRemoteAddress } else { @((Read-Default 'Allowed client sources (IP, CIDR or LocalSubnet; comma separated)' 'LocalSubnet') -split '\s*,\s*') }
    $profiles = $FirewallProfile
    if (-not $profiles) {
        $profiles = @('Domain', 'Private')
        $public = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object NetworkCategory -eq 'Public')
        if ($public.Count -gt 0) {
            Write-Host "The active network '$($public[0].Name)' is Public. The firewall rule would not apply to it by default."
            if (Confirm-Step 'Also allow SSH on Public networks (still limited to the sources above)?' $true) { $profiles += 'Public' }
        }
    }
    $existing = Get-LocalUser -Name $account -ErrorAction SilentlyContinue
    # Refuse before changing anything; the node script would reject it after OpenSSH setup.
    if ($existing -and (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID -eq $existing.SID })) {
        throw "'$account' is a local administrator. Use -User with a standard account name, for example lazycat."
    }

    Write-Host ''
    Write-Host 'About to:'
    Write-Host "  - install/configure the built-in OpenSSH Server (sources: $($sources -join ', '); profiles: $($profiles -join ', '))"
    if (-not $existing) { Write-Host "  - create standard local account '$account'" }
    Write-Host "  - enroll the LazyCat CA for '$account' as alias '$alias' at $address (restarts sshd)"
    if (-not (Confirm-Step 'Continue?' $true)) { Write-Host 'Cancelled; nothing was changed.'; return }

    $setupArgs = @{ AllowedRemoteAddress = $sources; FirewallProfile = $profiles }
    if ($Port) { $setupArgs.Port = $Port }
    & $files.Setup @setupArgs
    if (-not $existing) { New-StandardUser $account }

    $caFile = Join-Path $work 'lazycat-ssh-ca.pub'
    [IO.File]::WriteAllText($caFile, $key.Trim() + "`n", [Text.UTF8Encoding]::new($false))
    $joinArgs = @{ User = $account; Alias = $alias; Address = $address; CaPublicKeyFile = $caFile; Route = $Route }
    if ($Port) { $joinArgs.Port = $Port }
    if ($Via) { $joinArgs.Via = $Via }
    $entry = (& $files.Node @joinArgs) -join "`n"

    Write-Host ''
    Write-Host 'Done on this device. On the controller:'
    Write-Host '  1. Add this entry under hosts: in the Gist:'
    Write-Host ''
    Write-Output $entry
    Write-Host ''
    Write-Host "  2. Append $account to ca.principals in the Gist (keep the existing values)."
    Write-Host '  3. Run lazycat-ssh and choose 2) sync, which also renews the certificate.'
    Write-Host "  4. Test with: ssh $alias whoami   (compare the host key fingerprint shown above)"
}

if (-not (Test-Administrator)) {
    if ($Yes) { throw 'Run from an administrator Windows PowerShell.' }
    Restart-Elevated
    return
}

$mode = $PSCmdlet.ParameterSetName
if ($mode -eq 'Join' -and -not $CaPublicKey -and -not $Yes) {
    Write-Host 'LazyCat SSH Windows node'
    Write-Host '  1) Enroll or update this device'
    Write-Host '  2) Show status'
    Write-Host '  3) Remove LazyCat enrollment'
    Write-Host '  q) Quit'
    switch ((Read-Host 'Choose [1]').Trim()) {
        { $_ -in '', '1' } { $mode = 'Join' }
        '2' { $mode = 'Status' }
        '3' { $mode = 'Remove' }
        default { return }
    }
}

$files = Get-Scripts
switch ($mode) {
    'Status' {
        & $files.Setup -Status
        & $files.Node -Status
    }
    'Remove' {
        if (-not (Confirm-Step 'Remove LazyCat certificate login and restore the previous SSH policy?' $true)) { return }
        & $files.Node -Remove -Confirm:$false
        Write-Host 'OpenSSH Server, firewall rules and the login account are kept. Delete the account if unused, for example: Remove-LocalUser lazycat'
        Write-Host 'Also delete the Gist entry and sync so controllers drop this alias.'
    }
    default { Invoke-Join $files }
}
