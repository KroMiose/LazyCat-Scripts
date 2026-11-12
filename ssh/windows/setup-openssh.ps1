#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Install and configure the Windows built-in OpenSSH Server.
.DESCRIPTION
Uses the stock sshd_config as the base for a new configuration, manages one
global LazyCat block, and manages one narrowly scoped Windows Firewall rule.
Existing authentication settings and host keys are preserved. A newly created
configuration disables password authentication before sshd is first started.
.PARAMETER Port
Listener port. When omitted, keep the current effective port; a new stock
configuration uses port 22.
.PARAMETER AllowedRemoteAddress
One or more source IP addresses, CIDR networks, LocalSubnet, or explicit Any.
Required unless -NoFirewall is used.
.PARAMETER FirewallProfile
Windows Firewall profiles for the managed rule. Defaults to Domain,Private.
.PARAMETER NoFirewall
Do not create or change firewall rules. A stock rule created by a capability
installed during this run is still disabled before sshd starts.
.PARAMETER Status
Display capability, service, listener, firewall, and host-key status.
#>
[CmdletBinding(DefaultParameterSetName = 'Configure', SupportsShouldProcess)]
param(
    [Parameter(ParameterSetName = 'Configure')]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(ParameterSetName = 'Configure')]
    [string[]]$AllowedRemoteAddress,

    [Parameter(ParameterSetName = 'Configure')]
    [ValidateSet('Domain', 'Private', 'Public', 'Any')]
    [string[]]$FirewallProfile = @('Domain', 'Private'),

    [Parameter(ParameterSetName = 'Configure')]
    [switch]$NoFirewall,

    [Parameter(Mandatory, ParameterSetName = 'Status')]
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$capabilityName = 'OpenSSH.Server~~~~0.0.1.0'
$managedRuleName = 'LazyCat-OpenSSH-Server-In-TCP'
$managedRuleDescription = 'Managed by LazyCat setup-openssh.ps1.'
$stockRuleName = 'OpenSSH-Server-In-TCP'
$begin = '# >>> LazyCat SSH Windows Setup BEGIN >>>'
$end = '# <<< LazyCat SSH Windows Setup END <<<'
$nodeBegin = '# >>> LazyCat SSH Windows Node BEGIN >>>'
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Invoke-OpenSsh([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $output = @(& $Exe @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$([IO.Path]::GetFileName($Exe)) failed: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Assert-PlainPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to use a reparse point: $Path"
    }
}

function Get-SetupConfigParts([string]$Text) {
    $startPattern = '(?m)^' + [regex]::Escape($begin) + '[ \t]*\r?$'
    $endPattern = '(?m)^' + [regex]::Escape($end) + '[ \t]*\r?$'
    $starts = [regex]::Matches($Text, $startPattern)
    $ends = [regex]::Matches($Text, $endPattern)
    if ($starts.Count -eq 0 -and $ends.Count -eq 0) {
        return @{ Unmanaged = $Text; Managed = '' }
    }
    if ($starts.Count -ne 1 -or $ends.Count -ne 1 -or $starts[0].Index -ge $ends[0].Index) {
        throw 'Invalid LazyCat setup markers in sshd_config. Repair the managed block before continuing.'
    }
    $start = $starts[0].Index
    $after = $ends[0].Index + $ends[0].Length
    if ($after -lt $Text.Length -and $Text[$after] -eq "`n") { $after++ }
    return @{
        Unmanaged = $Text.Remove($start, $after - $start)
        Managed = $Text.Substring($start, $after - $start)
    }
}

function Get-ManagedSettings([string]$Block) {
    $settings = @{ HasPort = $false; Port = 0; DisablePassword = $false }
    if (-not $Block) { return $settings }
    foreach ($line in ($Block -split '\r?\n')) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '\APort[ \t=]+([0-9]+)(?:[ \t]+#.*)?\z') {
            if ($settings.HasPort) { throw 'The LazyCat setup block contains more than one Port directive.' }
            $settings.HasPort = $true
            $settings.Port = [int]$Matches[1]
            continue
        }
        if ($trimmed -match '\APasswordAuthentication[ \t=]+no(?:[ \t]+#.*)?\z') {
            $settings.DisablePassword = $true
            continue
        }
        throw "Unexpected directive in the LazyCat setup block: $trimmed"
    }
    return $settings
}

function Add-GlobalConfigBlock([string]$Text, [string]$Block) {
    $firstMatch = [regex]::Match($Text, '(?im)^[ \t]*Match(?:[ \t=]|\r?$)')
    if ($firstMatch.Success) {
        $insertAt = $firstMatch.Index
        $beforeMatch = $Text.Substring(0, $firstMatch.Index)
        $nodeMarker = [regex]::Match(
            $beforeMatch,
            '(?m)^' + [regex]::Escape($nodeBegin) + '[ \t]*\r?$'
        )
        if ($nodeMarker.Success) { $insertAt = $nodeMarker.Index }
        return $Text.Insert($insertAt, $Block)
    }
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n")) { $Text += "`n" }
    return $Text + $Block
}

function Get-UnmanagedPorts([string]$Text) {
    $firstMatch = [regex]::Match($Text, '(?im)^[ \t]*Match(?:[ \t=]|\r?$)')
    if ($firstMatch.Success) { $Text = $Text.Substring(0, $firstMatch.Index) }
    return @([regex]::Matches($Text, '(?im)^[ \t]*Port[ \t=]+([0-9]+)(?:[ \t]*(?:#.*)?)?\r?$') |
        ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
}

function New-SetupConfigCandidate(
    [string]$Text,
    [int]$TargetPort,
    [bool]$PortSpecified,
    [bool]$NewConfiguration
) {
    $parts = Get-SetupConfigParts $Text
    $managedSettings = Get-ManagedSettings $parts.Managed
    $unmanagedPorts = @(Get-UnmanagedPorts $parts.Unmanaged)
    $lineEnd = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $managedLines = New-Object 'System.Collections.Generic.List[string]'
    $managedLines.Add($begin)
    $writeManagedPort = $unmanagedPorts.Count -eq 0 -and ($PortSpecified -or $managedSettings.HasPort)
    if ($writeManagedPort) { $managedLines.Add("Port $TargetPort") }
    if ($NewConfiguration -or $managedSettings.DisablePassword) {
        $managedLines.Add('PasswordAuthentication no')
    }
    $managedLines.Add($end)
    $managedBlock = ($managedLines -join $lineEnd) + $lineEnd
    return [pscustomobject]@{
        Text = Add-GlobalConfigBlock $parts.Unmanaged $managedBlock
        UnmanagedPorts = $unmanagedPorts
        DisablePassword = $NewConfiguration -or $managedSettings.DisablePassword
    }
}

function Get-EffectivePort([string]$Sshd, [string]$Config) {
    $effective = @(Invoke-OpenSsh $Sshd @('-T', '-f', $Config))
    $ports = @($effective | ForEach-Object {
        if ($_ -match '^listenaddress\s+(?:\[[^]]+\]|[^: ]+):([0-9]+)\s*$') { [int]$Matches[1] }
    } | Sort-Object -Unique)
    if ($ports.Count -eq 0) {
        $ports = @($effective | ForEach-Object {
            if ($_ -match '^port\s+([0-9]+)\s*$') { [int]$Matches[1] }
        } | Sort-Object -Unique)
    }
    if ($ports.Count -ne 1) {
        throw "Expected exactly one effective sshd listener port; found: $($ports -join ', ')."
    }
    return $ports[0]
}

function ConvertTo-ValidatedRemoteAddresses([string[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) {
        throw 'Specify -AllowedRemoteAddress, or use -NoFirewall when another system manages the firewall.'
    }
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($raw in $Values) {
        if ($null -eq $raw -or -not $raw.Trim()) { throw 'AllowedRemoteAddress cannot contain an empty value.' }
        $value = $raw.Trim()
        if ($value -ieq 'Any') { $result.Add('Any'); continue }
        if ($value -ieq 'LocalSubnet') { $result.Add('LocalSubnet'); continue }

        $pieces = @($value -split '/')
        if ($pieces.Count -gt 2 -or -not $pieces[0]) { throw "Invalid IP address or CIDR network: $value" }
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($pieces[0], [ref]$ip)) {
            throw "AllowedRemoteAddress must be an IP address, CIDR network, LocalSubnet, or Any: $value"
        }
        $isV4 = $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
        if ($isV4 -and $pieces[0] -notmatch '\A(?:[0-9]{1,3}\.){3}[0-9]{1,3}\z') {
            throw "Use four-octet notation for IPv4 addresses: $value"
        }
        if (-not $isV4 -and $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) {
            throw "Unsupported IP address: $value"
        }
        $canonical = $ip.ToString()
        if ($pieces.Count -eq 2) {
            $prefix = 0
            if (-not [int]::TryParse($pieces[1], [ref]$prefix)) { throw "Invalid CIDR prefix: $value" }
            $maximum = if ($isV4) { 32 } else { 128 }
            if ($prefix -lt 0 -or $prefix -gt $maximum) { throw "CIDR prefix is out of range: $value" }
            $bytes = $ip.GetAddressBytes()
            $fullBytes = [int][Math]::Floor($prefix / 8)
            $remainingBits = $prefix % 8
            if ($remainingBits -gt 0) {
                $hostMask = (1 -shl (8 - $remainingBits)) - 1
                if (($bytes[$fullBytes] -band $hostMask) -ne 0) { throw "CIDR must use its network address: $value" }
                $fullBytes++
            }
            for ($i = $fullBytes; $i -lt $bytes.Length; $i++) {
                if ($bytes[$i] -ne 0) { throw "CIDR must use its network address: $value" }
            }
            $canonical += "/$prefix"
        }
        $result.Add($canonical)
    }
    $unique = @($result | Sort-Object -Unique)
    if ($unique -icontains 'Any' -and $unique.Count -ne 1) {
        throw 'Use AllowedRemoteAddress Any by itself; do not combine it with narrower sources.'
    }
    return $unique
}

function ConvertTo-ValidatedProfiles([string[]]$Profiles) {
    $unique = @($Profiles | Sort-Object -Unique)
    if ($unique -icontains 'Any' -and $unique.Count -ne 1) {
        throw 'Use FirewallProfile Any by itself; do not combine it with named profiles.'
    }
    return $unique
}

function Test-ServiceExecutable([object]$Service, [string]$ExpectedPath) {
    $pathName = [Environment]::ExpandEnvironmentVariables([string]$Service.PathName).Trim()
    if ($pathName -match '\A"([^"]+)"\z') { $pathName = $Matches[1] }
    return $pathName -ieq $ExpectedPath
}

function Test-PortExpression([object]$Expression, [int]$TargetPort) {
    foreach ($raw in @($Expression)) {
        foreach ($part in ([string]$raw -split ',')) {
            $item = $part.Trim()
            if ($item -ieq 'Any') { return $true }
            if ($item -match '\A([0-9]+)-([0-9]+)\z') {
                if ($TargetPort -ge [int]$Matches[1] -and $TargetPort -le [int]$Matches[2]) { return $true }
            } elseif ($item -match '\A[0-9]+\z' -and $TargetPort -eq [int]$item) {
                return $true
            }
        }
    }
    return $false
}

function ConvertTo-CanonicalFirewallAddress([string]$Value) {
    $value = $Value.Trim()
    if ($value -ieq 'Any') { return 'Any' }
    if ($value -ieq 'LocalSubnet') { return 'LocalSubnet' }
    $pieces = @($value -split '/')
    if ($pieces.Count -gt 2) { return $value.ToLowerInvariant() }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($pieces[0], [ref]$ip)) { return $value.ToLowerInvariant() }
    $maximum = if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
    $prefix = $maximum
    if ($pieces.Count -eq 2) {
        if ($pieces[1] -match '\A[0-9]+\z') {
            $prefix = [int]$pieces[1]
        } elseif ($maximum -eq 32) {
            $mask = $null
            if (-not [Net.IPAddress]::TryParse($pieces[1], [ref]$mask) -or
                $mask.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
                return $value.ToLowerInvariant()
            }
            $seenZero = $false
            $prefix = 0
            foreach ($byte in $mask.GetAddressBytes()) {
                for ($bit = 7; $bit -ge 0; $bit--) {
                    $set = ($byte -band (1 -shl $bit)) -ne 0
                    if ($set -and $seenZero) { return $value.ToLowerInvariant() }
                    if ($set) { $prefix++ } else { $seenZero = $true }
                }
            }
        } else {
            return $value.ToLowerInvariant()
        }
    }
    return "$($ip.ToString())/$prefix"
}

function Set-RestrictedOpenSshAcl([string]$Path, [switch]$Directory) {
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    if ($Directory) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = [Security.AccessControl.FileSecurity]::new()
        $inheritance = [Security.AccessControl.InheritanceFlags]::None
    }
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($admins, $system)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-OverlappingFirewallRules([int]$TargetPort, [string]$SshdPath) {
    $conflicts = New-Object 'System.Collections.Generic.List[string]'
    $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Allow)
    foreach ($rule in $rules) {
        if ($rule.Name -eq $managedRuleName) { continue }
        if ($rule.Name -eq $stockRuleName -and $rule.PolicyStoreSourceType -eq 'Local') { continue }
        $portFilters = @($rule | Get-NetFirewallPortFilter)
        $portMatch = $false
        foreach ($filter in $portFilters) {
            $protocol = [string]$filter.Protocol
            if (($protocol -ieq 'TCP' -or $protocol -eq '6' -or $protocol -ieq 'Any') -and
                (Test-PortExpression $filter.LocalPort $TargetPort)) {
                $portMatch = $true
                break
            }
        }
        if (-not $portMatch) { continue }
        $program = [string](($rule | Get-NetFirewallApplicationFilter).Program)
        $service = [string](($rule | Get-NetFirewallServiceFilter).Service)
        $programMatch = -not $program -or $program -ieq 'Any' -or
            [Environment]::ExpandEnvironmentVariables($program) -ieq $SshdPath
        $serviceMatch = -not $service -or $service -ieq 'Any' -or $service -ieq 'sshd'
        if ($programMatch -and $serviceMatch) {
            $conflicts.Add("$($rule.DisplayName) [$($rule.Name), $($rule.PolicyStoreSourceType)]")
        }
    }
    return @($conflicts)
}

function Get-ManagedFirewallSnapshot {
    $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $managedRuleName -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 1) { throw "More than one persistent firewall rule is named $managedRuleName." }
    if ($rules.Count -eq 0) { return $null }
    $rule = $rules[0]
    if ($rule.Description -ne $managedRuleDescription) {
        throw "Firewall rule '$managedRuleName' exists but is not owned by this script. Rename or remove it first."
    }
    $portFilter = $rule | Get-NetFirewallPortFilter
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    return [pscustomobject]@{
        DisplayName = [string]$rule.DisplayName
        Description = [string]$rule.Description
        Enabled = [string]$rule.Enabled
        Profile = @(([string]$rule.Profile -split ',') | ForEach-Object { $_.Trim() })
        Direction = [string]$rule.Direction
        Action = [string]$rule.Action
        Protocol = [string]$portFilter.Protocol
        LocalPort = @($portFilter.LocalPort)
        RemoteAddress = @($addressFilter.RemoteAddress)
        Program = [string](($rule | Get-NetFirewallApplicationFilter).Program)
        Service = [string](($rule | Get-NetFirewallServiceFilter).Service)
    }
}

function New-ManagedFirewallRule([int]$TargetPort, [string[]]$Sources, [string[]]$Profiles, [string]$SshdPath) {
    Get-NetFirewallRule -PolicyStore PersistentStore -Name $managedRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    $null = New-NetFirewallRule -PolicyStore PersistentStore -Name $managedRuleName `
        -DisplayName 'LazyCat OpenSSH Server (sshd)' -Description $managedRuleDescription `
        -Enabled True -Profile $Profiles -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $TargetPort -RemoteAddress $Sources -Program $SshdPath -Service sshd
}

function Restore-ManagedFirewallRule([object]$Snapshot) {
    Get-NetFirewallRule -PolicyStore PersistentStore -Name $managedRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    if ($null -eq $Snapshot) { return }
    $arguments = @{
        PolicyStore = 'PersistentStore'
        Name = $managedRuleName
        DisplayName = $Snapshot.DisplayName
        Description = $Snapshot.Description
        Enabled = $Snapshot.Enabled
        Profile = $Snapshot.Profile
        Direction = $Snapshot.Direction
        Action = $Snapshot.Action
        Protocol = $Snapshot.Protocol
        LocalPort = $Snapshot.LocalPort
        RemoteAddress = $Snapshot.RemoteAddress
    }
    if ($Snapshot.Program -and $Snapshot.Program -ine 'Any') { $arguments.Program = $Snapshot.Program }
    if ($Snapshot.Service -and $Snapshot.Service -ine 'Any') { $arguments.Service = $Snapshot.Service }
    $null = New-NetFirewallRule @arguments
}

function Assert-ManagedFirewallRule(
    [int]$TargetPort,
    [string[]]$Sources,
    [string[]]$Profiles,
    [string]$SshdPath
) {
    $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $managedRuleName -ErrorAction SilentlyContinue)
    if ($rules.Count -ne 1 -or $rules[0].Enabled -ne 'True' -or $rules[0].Direction -ne 'Inbound' -or
        $rules[0].Action -ne 'Allow') {
        throw "The effective managed firewall rule '$managedRuleName' is missing or inactive. Group Policy may be overriding it."
    }
    $portFilter = $rules[0] | Get-NetFirewallPortFilter
    if (([string]$portFilter.Protocol -notin @('TCP', '6')) -or
        -not (Test-PortExpression $portFilter.LocalPort $TargetPort)) {
        throw "The effective managed firewall rule does not allow TCP port $TargetPort."
    }
    $actualSources = @(($rules[0] | Get-NetFirewallAddressFilter).RemoteAddress |
        ForEach-Object { ConvertTo-CanonicalFirewallAddress ([string]$_) } | Sort-Object -Unique)
    $expectedSources = @($Sources |
        ForEach-Object { ConvertTo-CanonicalFirewallAddress ([string]$_) } | Sort-Object -Unique)
    if (($actualSources -join ',').ToLowerInvariant() -ne ($expectedSources -join ',').ToLowerInvariant()) {
        throw "The effective managed firewall sources differ from the requested sources: $($actualSources -join ', ')."
    }
    $actualProfiles = @(([string]$rules[0].Profile -split ',') | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $expectedProfiles = @($Profiles | Sort-Object -Unique)
    if (($actualProfiles -join ',').ToLowerInvariant() -ne ($expectedProfiles -join ',').ToLowerInvariant()) {
        throw "The effective managed firewall profiles differ from the requested profiles: $($actualProfiles -join ', ')."
    }
    $program = [Environment]::ExpandEnvironmentVariables(
        [string](($rules[0] | Get-NetFirewallApplicationFilter).Program)
    )
    $service = [string](($rules[0] | Get-NetFirewallServiceFilter).Service)
    if ($program -ine $SshdPath -or $service -ine 'sshd') {
        throw 'The effective managed firewall rule is not restricted to the built-in sshd service.'
    }
}

function Wait-SshListener([int]$TargetPort) {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'"
        if ($service.State -eq 'Running' -and $service.ProcessId -gt 0) {
            $ports = @(Get-NetTCPConnection -State Listen -OwningProcess $service.ProcessId -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
            if ($ports.Count -eq 1 -and $ports[0] -eq $TargetPort) { return }
            if ($ports.Count -gt 0 -and ($ports -notcontains $TargetPort -or $ports.Count -gt 1)) {
                throw "sshd is listening on unexpected port(s): $($ports -join ', ')."
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "sshd did not begin listening on TCP port $TargetPort within 15 seconds."
}

function Write-HostFingerprints([string]$Keygen, [string]$ConfigDir) {
    $keys = @(Get-ChildItem -LiteralPath $ConfigDir -Filter 'ssh_host_*_key.pub' -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
    if ($keys.Count -eq 0) {
        Write-Output 'Host key fingerprints: none found'
        return
    }
    Write-Output 'Host key fingerprints:'
    foreach ($key in $keys) {
        $fingerprint = (Invoke-OpenSsh $Keygen @('-l', '-E', 'sha256', '-f', $key.FullName)) -join ' '
        Write-Output "  $fingerprint"
    }
}

function Get-StartupType([string]$StartMode) {
    switch ($StartMode) {
        'Auto' { return 'Automatic' }
        'Manual' { return 'Manual' }
        'Disabled' { return 'Disabled' }
        default { throw "Unsupported sshd start mode: $StartMode" }
    }
}

function Disable-NewStockRule([bool]$RuleExistedBeforeInstall) {
    if ($RuleExistedBeforeInstall) { return }
    $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $stockRuleName -ErrorAction SilentlyContinue)
    foreach ($rule in $rules) {
        if ($rule.Enabled -eq 'True') {
            Disable-NetFirewallRule -InputObject $rule
            Write-Warning "Disabled the broad stock firewall rule created by the OpenSSH capability: $stockRuleName"
        }
    }
}

$windowsDir = $env:WINDIR
$programData = $env:ProgramData
if (-not $windowsDir -or -not $programData) { throw 'Windows environment paths are unavailable.' }
$sshBin = Join-Path $windowsDir 'System32\OpenSSH'
$sshd = Join-Path $sshBin 'sshd.exe'
$keygen = Join-Path $sshBin 'ssh-keygen.exe'
$stockConfig = Join-Path $sshBin 'sshd_config_default'
$configDir = Join-Path $programData 'ssh'
$config = Join-Path $configDir 'sshd_config'

$capability = Get-WindowsCapability -Online -Name $capabilityName
$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue

if ($Status) {
    Write-Output "OpenSSH Server capability: $($capability.State)"
    if (-not $service) {
        Write-Output 'sshd service: missing'
        return
    }
    Write-Output "sshd service: $($service.State) (start mode: $($service.StartMode))"
    Write-Output "sshd service command: $($service.PathName)"
    if (-not (Test-ServiceExecutable $service $sshd)) {
        Write-Output 'Configuration status: unsupported custom sshd executable or service arguments'
        return
    }
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        Write-Output "Configuration: not initialized ($config)"
    } else {
        Assert-PlainPath $config
        $null = Invoke-OpenSsh $sshd @('-t', '-f', $config)
        $effectivePort = Get-EffectivePort $sshd $config
        Write-Output "Effective configured port: $effectivePort"
        if ($service.State -eq 'Running' -and $service.ProcessId -gt 0) {
            $listening = @(Get-NetTCPConnection -State Listen -OwningProcess $service.ProcessId -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
            Write-Output "Actual listening port(s): $($listening -join ', ')"
        }
    }
    $managedFirewall = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $managedRuleName -ErrorAction SilentlyContinue)
    if ($managedFirewall.Count -eq 0) { Write-Output 'Managed firewall rule: absent' }
    else { Write-Output "Managed firewall rule: $($managedFirewall[0].Enabled), profiles $($managedFirewall[0].Profile)" }
    if (Test-Path -LiteralPath $keygen -PathType Leaf) { Write-HostFingerprints $keygen $configDir }
    return
}

$validatedProfiles = ConvertTo-ValidatedProfiles $FirewallProfile
$validatedSources = $null
if ($NoFirewall) {
    if ($PSBoundParameters.ContainsKey('AllowedRemoteAddress') -or $PSBoundParameters.ContainsKey('FirewallProfile')) {
        throw 'Do not combine -NoFirewall with -AllowedRemoteAddress or -FirewallProfile.'
    }
} else {
    $validatedSources = ConvertTo-ValidatedRemoteAddresses $AllowedRemoteAddress
}

if (-not $PSCmdlet.ShouldProcess('Windows OpenSSH Server', 'Install/configure sshd and its inbound firewall rule')) { return }

$stockRuleBeforeInstall = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $stockRuleName -ErrorAction SilentlyContinue)
if ($capability.State -ne 'Installed') {
    try {
        $installResult = Add-WindowsCapability -Online -Name $capabilityName
    } catch {
        $message = [string]$_
        if ($message -match '0x800f0954|0x8024402c|WSUS|source files could not be found') {
            throw "OpenSSH Server capability installation failed, likely because Windows Update/WSUS cannot provide the payload. Ask the Windows administrator to allow the OpenSSH optional feature, then rerun. Original error: $message"
        }
        throw
    }
    Disable-NewStockRule ($stockRuleBeforeInstall.Count -gt 0)
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($installResult.RestartNeeded -or $capability.State -ne 'Installed') {
        throw 'OpenSSH Server installation requires a reboot or has not completed. Reboot Windows, then rerun this command.'
    }
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
}

if (-not $service) {
    throw 'The OpenSSH capability is installed but the sshd service is unavailable. Reboot Windows, then rerun.'
}
if (-not (Test-ServiceExecutable $service $sshd)) {
    throw "The sshd service uses a custom executable or arguments: $($service.PathName). Only the Windows built-in OpenSSH service with its standard config path is supported."
}
foreach ($path in @($sshd, $keygen, $stockConfig)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required OpenSSH file is missing: $path" }
    Assert-PlainPath $path
}
if ($service.State -notin @('Running', 'Stopped')) {
    throw "sshd is in unsupported state '$($service.State)'. Stop or resume it, then rerun."
}

$newConfiguration = -not (Test-Path -LiteralPath $config -PathType Leaf)
if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $configDir
    Set-RestrictedOpenSshAcl $configDir -Directory
}
Assert-PlainPath $configDir
if ($newConfiguration) {
    $original = [IO.File]::ReadAllText($stockConfig, $utf8)
} else {
    Assert-PlainPath $config
    $original = [IO.File]::ReadAllText($config, $utf8)
}

# Generate only missing host keys. Record existing private keys so their owner
# and ACL remain untouched; sshd runs as LocalSystem, so new private keys must
# not retain ownership from the elevated interactive account.
$existingHostKeys = @{}
Get-ChildItem -LiteralPath $configDir -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue |
    ForEach-Object { $existingHostKeys[$_.FullName.ToLowerInvariant()] = $true }
$null = Invoke-OpenSsh $keygen @('-A')
Get-ChildItem -LiteralPath $configDir -Filter 'ssh_host_*_key' -File -ErrorAction SilentlyContinue |
    ForEach-Object {
        if (-not $existingHostKeys.ContainsKey($_.FullName.ToLowerInvariant())) {
            Set-RestrictedOpenSshAcl $_.FullName
        }
    }

$baseTemp = Join-Path $configDir ('.lazycat-setup-base-' + [guid]::NewGuid() + '.tmp')
$candidateTemp = Join-Path $configDir ('.lazycat-setup-' + [guid]::NewGuid() + '.tmp')
$backup = "$config.lazycat-setup-$([guid]::NewGuid()).bak"
$rejected = "$config.lazycat-setup-$([guid]::NewGuid()).rejected"
$configReplaced = $false
$configCreated = $false
$firewallChanged = $false
$startupChanged = $false
$serviceOperationAttempted = $false
$stockRulesDisabled = @()
$firewallSnapshot = $null
$originalState = [string]$service.State
$originalStartMode = [string]$service.StartMode

try {
    [IO.File]::WriteAllText($baseTemp, $original, $utf8)
    if ($newConfiguration) { Set-RestrictedOpenSshAcl $baseTemp }
    else { Set-Acl -LiteralPath $baseTemp -AclObject (Get-Acl -LiteralPath $config) }
    $null = Invoke-OpenSsh $sshd @('-t', '-f', $baseTemp)
    $currentPort = Get-EffectivePort $sshd $baseTemp
    $portSpecified = $PSBoundParameters.ContainsKey('Port')
    $targetPort = if ($portSpecified) { $Port } else { $currentPort }

    $rendered = New-SetupConfigCandidate $original $targetPort $portSpecified $newConfiguration
    $unmanagedPorts = @($rendered.UnmanagedPorts)
    $conflictingPorts = @($unmanagedPorts | Where-Object { $_ -ne $targetPort })
    if ($targetPort -ne $currentPort -and $conflictingPorts.Count -gt 0) {
        throw "Refusing to override active unmanaged Port directive(s): $($conflictingPorts -join ', '). Update them explicitly, then rerun."
    }

    $candidate = $rendered.Text

    [IO.File]::WriteAllText($candidateTemp, $candidate, $utf8)
    if ($newConfiguration) { Set-RestrictedOpenSshAcl $candidateTemp }
    else { Set-Acl -LiteralPath $candidateTemp -AclObject (Get-Acl -LiteralPath $config) }
    $null = Invoke-OpenSsh $sshd @('-t', '-f', $candidateTemp)
    $candidatePort = Get-EffectivePort $sshd $candidateTemp
    if ($candidatePort -ne $targetPort) {
        throw "The candidate configuration is ineffective: requested port $targetPort, effective port $candidatePort. Check Include, Port, and ListenAddress directives."
    }
    if ($rendered.DisablePassword) {
        $effective = @(Invoke-OpenSsh $sshd @('-T', '-f', $candidateTemp))
        if ($effective -notcontains 'passwordauthentication no') {
            throw 'The candidate configuration does not effectively disable password authentication.'
        }
    }

    if ($targetPort -ne $currentPort) {
        $otherListeners = @(Get-NetTCPConnection -State Listen -LocalPort $targetPort -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -ne $service.ProcessId })
        if ($otherListeners.Count -gt 0) {
            $owners = @($otherListeners | Select-Object -ExpandProperty OwningProcess -Unique)
            throw "TCP port $targetPort is already in use by process ID(s): $($owners -join ', ')."
        }
    }

    if (-not $NoFirewall) {
        $firewallSnapshot = Get-ManagedFirewallSnapshot
        $overlaps = @(Get-OverlappingFirewallRules $targetPort $sshd)
        if ($overlaps.Count -gt 0) {
            throw "Other enabled inbound allow rule(s) overlap sshd TCP port ${targetPort}: $($overlaps -join '; '). Disable or narrow them, then rerun."
        }
    } else {
        $enabledStockRules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $stockRuleName -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq 'True' })
        if ($enabledStockRules.Count -gt 0) {
            Write-Warning "NoFirewall was requested; existing stock rule '$stockRuleName' remains enabled and unmanaged."
        }
    }

    if ($candidate -cne $original) {
        if ($newConfiguration) {
            Move-Item -LiteralPath $candidateTemp -Destination $config
            $configCreated = $true
        } else {
            if ([IO.File]::ReadAllText($config, $utf8) -cne $original) {
                throw 'sshd_config changed while setup was running. Rerun the command.'
            }
            [IO.File]::Replace($candidateTemp, $config, $backup)
            $configReplaced = $true
        }
    }

    if (-not $NoFirewall) {
        $stockRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $stockRuleName -ErrorAction SilentlyContinue)
        $firewallChanged = $true
        foreach ($rule in $stockRules) {
            if ($rule.Enabled -eq 'True') {
                $stockRulesDisabled += $rule
                Disable-NetFirewallRule -InputObject $rule
                Write-Host "Adopted and disabled broad stock firewall rule: $stockRuleName"
            } else {
                Write-Host "Existing stock firewall rule is already disabled and remains disabled: $stockRuleName"
            }
        }
        New-ManagedFirewallRule $targetPort $validatedSources $validatedProfiles $sshd
    }

    $startupChanged = $originalStartMode -ne 'Auto'
    if ($startupChanged) { Set-Service -Name sshd -StartupType Automatic }
    if ($service.State -eq 'Running' -and ($configCreated -or $configReplaced)) {
        $serviceOperationAttempted = $true
        Restart-Service -Name sshd
    } elseif ($service.State -ne 'Running') {
        $serviceOperationAttempted = $true
        Start-Service -Name sshd
    }
    (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    Wait-SshListener $targetPort
    if (-not $NoFirewall) {
        Assert-ManagedFirewallRule $targetPort $validatedSources $validatedProfiles $sshd
    }

    if ($configReplaced) { Write-Host "Saved previous configuration to $backup" }
    Write-Output "OpenSSH Server is running and listening on TCP port $targetPort."
    if ($NoFirewall) { Write-Warning 'Windows Firewall was not configured. Ensure another policy allows only the intended sources.' }
    else { Write-Output "Managed firewall sources: $($validatedSources -join ', ') (profiles: $($validatedProfiles -join ', '))" }
    Write-HostFingerprints $keygen $configDir
} catch {
    $failure = $_
    if ($configReplaced) {
        try {
            [IO.File]::Replace($backup, $config, $rejected)
            Write-Warning "Restored the previous sshd_config. Rejected configuration: $rejected"
        } catch { Write-Warning "Could not restore sshd_config: $_. Backups are in $configDir." }
    } elseif ($configCreated) {
        try { Remove-Item -LiteralPath $config -Force } catch { Write-Warning "Could not remove the new sshd_config during rollback: $_" }
    }
    if ($firewallChanged) {
        try { Restore-ManagedFirewallRule $firewallSnapshot }
        catch { Write-Warning "Could not restore the managed firewall rule: $_" }
    }
    foreach ($rule in $stockRulesDisabled) {
        try { Enable-NetFirewallRule -InputObject $rule }
        catch { Write-Warning "Could not re-enable stock firewall rule '$($rule.Name)': $_" }
    }
    if ($serviceOperationAttempted -or $startupChanged) {
        try {
            if ($serviceOperationAttempted) {
                if ($originalState -eq 'Running') {
                    Restart-Service -Name sshd
                    (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
                } else {
                    Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
                }
            }
            if ($startupChanged) {
                Set-Service -Name sshd -StartupType (Get-StartupType $originalStartMode)
            }
        } catch { Write-Warning "Could not fully restore sshd service state: $_" }
    }
    throw $failure
} finally {
    Remove-Item -LiteralPath $baseTemp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $candidateTemp -Force -ErrorAction SilentlyContinue
}
