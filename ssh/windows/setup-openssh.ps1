#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
安装并配置 Windows 内置的 OpenSSH Server。
.DESCRIPTION
以系统自带的 sshd_config 作为新配置的基础，管理一个全局 LazyCat 配置块，
以及一条范围严格限定的 Windows 防火墙规则。
已有的认证设置和主机密钥会被保留。新建的配置会在 sshd 首次启动前禁用密码认证。
.PARAMETER Port
监听端口。省略时保持当前生效的端口；全新的默认配置使用 22 端口。
.PARAMETER AllowedRemoteAddress
一个或多个来源 IP 地址、CIDR 网段、LocalSubnet，或显式指定的 Any。
除非使用 -NoFirewall，否则必须指定。
.PARAMETER FirewallProfile
受管防火墙规则所用的 Windows 防火墙配置文件。默认为 Domain,Private。
.PARAMETER NoFirewall
不创建或修改防火墙规则。若本次运行安装的功能自带了默认规则，
该规则仍会在 sshd 启动前被禁用。
.PARAMETER Status
显示功能、服务、监听端口、防火墙和主机密钥的状态。
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
        throw "$([IO.Path]::GetFileName($Exe)) 执行失败：$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Assert-PlainPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "拒绝使用重解析点：$Path"
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
        throw 'sshd_config 中的 LazyCat 配置块标记无效。请先修复该受管配置块再继续。'
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
            if ($settings.HasPort) { throw 'LazyCat 配置块中包含多于一条 Port 指令。' }
            $settings.HasPort = $true
            $settings.Port = [int]$Matches[1]
            continue
        }
        if ($trimmed -match '\APasswordAuthentication[ \t=]+no(?:[ \t]+#.*)?\z') {
            $settings.DisablePassword = $true
            continue
        }
        throw "LazyCat 配置块中存在意外的指令：$trimmed"
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
        throw "应当有且仅有一个生效的 sshd 监听端口，实际为：$($ports -join ', ')。"
    }
    return $ports[0]
}

function ConvertTo-ValidatedRemoteAddresses([string[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) {
        throw '请指定 -AllowedRemoteAddress；若防火墙由其他系统管理，请使用 -NoFirewall。'
    }
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($raw in $Values) {
        if ($null -eq $raw -or -not $raw.Trim()) { throw 'AllowedRemoteAddress 不能包含空值。' }
        $value = $raw.Trim()
        if ($value -ieq 'Any') { $result.Add('Any'); continue }
        if ($value -ieq 'LocalSubnet') { $result.Add('LocalSubnet'); continue }

        $pieces = @($value -split '/')
        if ($pieces.Count -gt 2 -or -not $pieces[0]) { throw "无效的 IP 地址或 CIDR 网段：$value" }
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($pieces[0], [ref]$ip)) {
            throw "AllowedRemoteAddress 必须是 IP 地址、CIDR 网段、LocalSubnet 或 Any：$value"
        }
        $isV4 = $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
        if ($isV4 -and $pieces[0] -notmatch '\A(?:[0-9]{1,3}\.){3}[0-9]{1,3}\z') {
            throw "IPv4 地址请使用四段式写法：$value"
        }
        if (-not $isV4 -and $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) {
            throw "不支持的 IP 地址：$value"
        }
        $canonical = $ip.ToString()
        if ($pieces.Count -eq 2) {
            $prefix = 0
            if (-not [int]::TryParse($pieces[1], [ref]$prefix)) { throw "无效的 CIDR 前缀：$value" }
            $maximum = if ($isV4) { 32 } else { 128 }
            if ($prefix -lt 0 -or $prefix -gt $maximum) { throw "CIDR 前缀超出范围：$value" }
            $bytes = $ip.GetAddressBytes()
            $fullBytes = [int][Math]::Floor($prefix / 8)
            $remainingBits = $prefix % 8
            if ($remainingBits -gt 0) {
                $hostMask = (1 -shl (8 - $remainingBits)) - 1
                if (($bytes[$fullBytes] -band $hostMask) -ne 0) { throw "CIDR 必须使用其网络地址：$value" }
                $fullBytes++
            }
            for ($i = $fullBytes; $i -lt $bytes.Length; $i++) {
                if ($bytes[$i] -ne 0) { throw "CIDR 必须使用其网络地址：$value" }
            }
            $canonical += "/$prefix"
        }
        $result.Add($canonical)
    }
    $unique = @($result | Sort-Object -Unique)
    if ($unique -icontains 'Any' -and $unique.Count -ne 1) {
        throw 'AllowedRemoteAddress 的 Any 必须单独使用，不能与范围更窄的来源同时指定。'
    }
    return $unique
}

function ConvertTo-ValidatedProfiles([string[]]$Profiles) {
    $unique = @($Profiles | Sort-Object -Unique)
    if ($unique -icontains 'Any' -and $unique.Count -ne 1) {
        throw 'FirewallProfile 的 Any 必须单独使用，不能与具名配置文件同时指定。'
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
    $localPolicy = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
    $localRules = Get-Item -LiteralPath $localPolicy -ErrorAction SilentlyContinue
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
        $application = $rule | Get-NetFirewallApplicationFilter
        # Packaged-app rules can report Program=Any but do not apply to sshd.
        if ($application.Package -and $application.Package -ine 'Any') { continue }
        # Some local rules store only a package family name (PFN), which
        # NetSecurity omits from the application filter. Only consult the
        # local registry for rules that actually originate in that store.
        if ($localRules -and $rule.PolicyStoreSourceType -eq 'Local' -and
            $rule.PolicyStoreSource -eq 'PersistentStore' -and
            ([string]$localRules.GetValue($rule.Name) -match '(?:^|\|)PFN=[^|]+\|')) { continue }
        $program = [string]$application.Program
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
    if ($rules.Count -gt 1) { throw "存在多条名为 $managedRuleName 的持久防火墙规则。" }
    if ($rules.Count -eq 0) { return $null }
    $rule = $rules[0]
    if ($rule.Description -ne $managedRuleDescription) {
        throw "防火墙规则 '$managedRuleName' 已存在，但不属于本脚本管理。请先重命名或删除它。"
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
        -LocalPort $TargetPort -RemoteAddress $Sources -Program $SshdPath
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
        throw "生效的受管防火墙规则 '$managedRuleName' 缺失或未启用。可能被组策略覆盖。"
    }
    $portFilter = $rules[0] | Get-NetFirewallPortFilter
    if (([string]$portFilter.Protocol -notin @('TCP', '6')) -or
        -not (Test-PortExpression $portFilter.LocalPort $TargetPort)) {
        throw "生效的受管防火墙规则未放行 TCP 端口 $TargetPort。"
    }
    $actualSources = @(($rules[0] | Get-NetFirewallAddressFilter).RemoteAddress |
        ForEach-Object { ConvertTo-CanonicalFirewallAddress ([string]$_) } | Sort-Object -Unique)
    $expectedSources = @($Sources |
        ForEach-Object { ConvertTo-CanonicalFirewallAddress ([string]$_) } | Sort-Object -Unique)
    if (($actualSources -join ',').ToLowerInvariant() -ne ($expectedSources -join ',').ToLowerInvariant()) {
        throw "生效的受管防火墙来源与请求的来源不一致：$($actualSources -join ', ')。"
    }
    $actualProfiles = @(([string]$rules[0].Profile -split ',') | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $expectedProfiles = @($Profiles | Sort-Object -Unique)
    if (($actualProfiles -join ',').ToLowerInvariant() -ne ($expectedProfiles -join ',').ToLowerInvariant()) {
        throw "生效的受管防火墙配置文件与请求的配置文件不一致：$($actualProfiles -join ', ')。"
    }
    $program = [Environment]::ExpandEnvironmentVariables(
        [string](($rules[0] | Get-NetFirewallApplicationFilter).Program)
    )
    # The built-in sshd service has SID type NONE, so a service condition never
    # matches and remote connections fall through to the default block; loopback
    # bypasses the firewall, so local tests cannot catch this.
    $service = [string](($rules[0] | Get-NetFirewallServiceFilter).Service)
    if ($program -ine $SshdPath) {
        throw '生效的受管防火墙规则未限定为仅作用于内置的 sshd.exe。'
    }
    if ($service -and $service -ine 'Any') {
        throw "生效的受管防火墙规则带有服务条件 '$service'，sshd 进程不带服务 SID，远程连接会被拦截。"
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
                throw "sshd 正在监听意外的端口：$($ports -join ', ')。"
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "sshd 未能在 15 秒内开始监听 TCP 端口 $TargetPort。"
}

function Write-HostFingerprints([string]$Keygen, [string]$ConfigDir) {
    $keys = @(Get-ChildItem -LiteralPath $ConfigDir -Filter 'ssh_host_*_key.pub' -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
    if ($keys.Count -eq 0) {
        Write-Output '主机密钥指纹：未找到'
        return
    }
    Write-Output '主机密钥指纹：'
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
        default { throw "不支持的 sshd 启动模式：$StartMode" }
    }
}

function Disable-NewStockRule([bool]$RuleExistedBeforeInstall) {
    if ($RuleExistedBeforeInstall) { return }
    $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $stockRuleName -ErrorAction SilentlyContinue)
    foreach ($rule in $rules) {
        if ($rule.Enabled -eq 'True') {
            Disable-NetFirewallRule -InputObject $rule
            Write-Warning "已禁用 OpenSSH 功能自带的宽泛默认防火墙规则：$stockRuleName"
        }
    }
}

$windowsDir = $env:WINDIR
$programData = $env:ProgramData
if (-not $windowsDir -or -not $programData) { throw '无法获取 Windows 环境路径。' }
$sshBin = Join-Path $windowsDir 'System32\OpenSSH'
$sshd = Join-Path $sshBin 'sshd.exe'
$keygen = Join-Path $sshBin 'ssh-keygen.exe'
$stockConfig = Join-Path $sshBin 'sshd_config_default'
$configDir = Join-Path $programData 'ssh'
$config = Join-Path $configDir 'sshd_config'

$capability = Get-WindowsCapability -Online -Name $capabilityName
$service = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue

if ($Status) {
    Write-Output "OpenSSH Server 功能：$($capability.State)"
    if (-not $service) {
        Write-Output 'sshd 服务：缺失'
        return
    }
    Write-Output "sshd 服务：$($service.State)（启动模式：$($service.StartMode)）"
    Write-Output "sshd 服务命令：$($service.PathName)"
    if (-not (Test-ServiceExecutable $service $sshd)) {
        Write-Output '配置状态：不支持自定义的 sshd 可执行文件或服务参数'
        return
    }
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        Write-Output "配置：未初始化（$config）"
    } else {
        Assert-PlainPath $config
        $null = Invoke-OpenSsh $sshd @('-t', '-f', $config)
        $effectivePort = Get-EffectivePort $sshd $config
        Write-Output "生效的配置端口：$effectivePort"
        if ($service.State -eq 'Running' -and $service.ProcessId -gt 0) {
            $listening = @(Get-NetTCPConnection -State Listen -OwningProcess $service.ProcessId -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
            Write-Output "实际监听端口：$($listening -join ', ')"
        }
    }
    $managedFirewall = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $managedRuleName -ErrorAction SilentlyContinue)
    if ($managedFirewall.Count -eq 0) { Write-Output '受管防火墙规则：不存在' }
    else { Write-Output "受管防火墙规则：$($managedFirewall[0].Enabled)，配置文件 $($managedFirewall[0].Profile)" }
    if (Test-Path -LiteralPath $keygen -PathType Leaf) { Write-HostFingerprints $keygen $configDir }
    return
}

$validatedProfiles = ConvertTo-ValidatedProfiles $FirewallProfile
$validatedSources = $null
if ($NoFirewall) {
    if ($PSBoundParameters.ContainsKey('AllowedRemoteAddress') -or $PSBoundParameters.ContainsKey('FirewallProfile')) {
        throw '-NoFirewall 不能与 -AllowedRemoteAddress 或 -FirewallProfile 同时使用。'
    }
} else {
    $validatedSources = ConvertTo-ValidatedRemoteAddresses $AllowedRemoteAddress
}

if (-not $PSCmdlet.ShouldProcess('Windows OpenSSH Server', '安装/配置 sshd 及其入站防火墙规则')) { return }

$stockRuleBeforeInstall = @(Get-NetFirewallRule -PolicyStore PersistentStore -Name $stockRuleName -ErrorAction SilentlyContinue)
if ($capability.State -ne 'Installed') {
    Write-Host '正在安装 Windows OpenSSH Server 可选功能，Windows 可能需要下载组件。'
    try {
        $installResult = Add-WindowsCapability -Online -Name $capabilityName
    } catch {
        $message = [string]$_
        if ($message -match '0x800f0954|0x8024402c|WSUS|source files could not be found') {
            throw "OpenSSH Server 功能安装失败，可能是 Windows Update/WSUS 无法提供安装包。请让 Windows 管理员允许 OpenSSH 可选功能，然后重新运行。原始错误：$message"
        }
        throw
    }
    Disable-NewStockRule ($stockRuleBeforeInstall.Count -gt 0)
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($installResult.RestartNeeded -or $capability.State -ne 'Installed') {
        throw 'OpenSSH Server 安装需要重启或尚未完成。请重启 Windows，然后重新运行此命令。'
    }
    Write-Host 'Windows OpenSSH Server 可选功能已安装。'
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
}

if (-not $service) {
    throw 'OpenSSH 功能已安装，但 sshd 服务不可用。请重启 Windows 后重新运行。'
}
if (-not (Test-ServiceExecutable $service $sshd)) {
    throw "sshd 服务使用了自定义的可执行文件或参数：$($service.PathName)。仅支持使用标准配置路径的 Windows 内置 OpenSSH 服务。"
}
foreach ($path in @($sshd, $keygen, $stockConfig)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少必需的 OpenSSH 文件：$path" }
    Assert-PlainPath $path
}
if ($service.State -notin @('Running', 'Stopped')) {
    throw "sshd 处于不支持的状态 '$($service.State)'。请先停止或恢复它，然后重新运行。"
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
        throw "拒绝覆盖生效中的非受管 Port 指令：$($conflictingPorts -join ', ')。请手动更新它们，然后重新运行。"
    }

    $candidate = $rendered.Text

    [IO.File]::WriteAllText($candidateTemp, $candidate, $utf8)
    if ($newConfiguration) { Set-RestrictedOpenSshAcl $candidateTemp }
    else { Set-Acl -LiteralPath $candidateTemp -AclObject (Get-Acl -LiteralPath $config) }
    $null = Invoke-OpenSsh $sshd @('-t', '-f', $candidateTemp)
    $candidatePort = Get-EffectivePort $sshd $candidateTemp
    if ($candidatePort -ne $targetPort) {
        throw "候选配置未生效：请求的端口为 $targetPort，实际生效端口为 $candidatePort。请检查 Include、Port 和 ListenAddress 指令。"
    }
    if ($rendered.DisablePassword) {
        $effective = @(Invoke-OpenSsh $sshd @('-T', '-f', $candidateTemp))
        if ($effective -notcontains 'passwordauthentication no') {
            throw '候选配置未能有效禁用密码认证。'
        }
    }

    if ($targetPort -ne $currentPort) {
        $otherListeners = @(Get-NetTCPConnection -State Listen -LocalPort $targetPort -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -ne $service.ProcessId })
        if ($otherListeners.Count -gt 0) {
            $owners = @($otherListeners | Select-Object -ExpandProperty OwningProcess -Unique)
            throw "TCP 端口 $targetPort 已被进程 ID 占用：$($owners -join ', ')。"
        }
    }

    if (-not $NoFirewall) {
        $firewallSnapshot = Get-ManagedFirewallSnapshot
        $overlaps = @(Get-OverlappingFirewallRules $targetPort $sshd)
        if ($overlaps.Count -gt 0) {
            throw "其他已启用的入站放行规则与 sshd 的 TCP 端口 ${targetPort} 重叠：$($overlaps -join '; ')。请禁用或收窄这些规则，然后重新运行。"
        }
    } else {
        $enabledStockRules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $stockRuleName -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq 'True' })
        if ($enabledStockRules.Count -gt 0) {
            Write-Warning "已指定 NoFirewall；现有的默认规则 '$stockRuleName' 仍保持启用且不受管理。"
        }
    }

    if ($candidate -cne $original) {
        if ($newConfiguration) {
            Move-Item -LiteralPath $candidateTemp -Destination $config
            $configCreated = $true
        } else {
            if ([IO.File]::ReadAllText($config, $utf8) -cne $original) {
                throw '安装过程中 sshd_config 发生了变化。请重新运行该命令。'
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
                Write-Host "已接管并禁用宽泛的默认防火墙规则：$stockRuleName"
            } else {
                Write-Host "现有的默认防火墙规则已处于禁用状态，将保持禁用：$stockRuleName"
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

    if ($configReplaced) { Write-Host "已将之前的配置保存到 $backup" }
    Write-Output "OpenSSH Server 正在运行，并监听 TCP 端口 $targetPort。"
    if ($NoFirewall) { Write-Warning '未配置 Windows 防火墙。请确保其他策略只放行预期的来源。' }
    else { Write-Output "受管防火墙来源：$($validatedSources -join ', ')（配置文件：$($validatedProfiles -join ', ')）" }
    Write-HostFingerprints $keygen $configDir
} catch {
    $failure = $_
    if ($configReplaced) {
        try {
            [IO.File]::Replace($backup, $config, $rejected)
            Write-Warning "已恢复之前的 sshd_config。被拒绝的配置：$rejected"
        } catch { Write-Warning "无法恢复 sshd_config：$_。备份位于 $configDir。" }
    } elseif ($configCreated) {
        try { Remove-Item -LiteralPath $config -Force } catch { Write-Warning "回滚时无法删除新的 sshd_config：$_" }
    }
    if ($firewallChanged) {
        try { Restore-ManagedFirewallRule $firewallSnapshot }
        catch { Write-Warning "无法恢复受管防火墙规则：$_" }
    }
    foreach ($rule in $stockRulesDisabled) {
        try { Enable-NetFirewallRule -InputObject $rule }
        catch { Write-Warning "无法重新启用默认防火墙规则 '$($rule.Name)'：$_" }
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
        } catch { Write-Warning "无法完全恢复 sshd 服务状态：$_" }
    }
    throw $failure
} finally {
    Remove-Item -LiteralPath $baseTemp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $candidateTemp -Force -ErrorAction SilentlyContinue
}
