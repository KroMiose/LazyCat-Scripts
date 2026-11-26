#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
将已有的 Windows OpenSSH Server 接入为 LazyCat SSH 节点。
.DESCRIPTION
为一个已有的本地标准用户配置仅限证书的登录方式，并输出一条
用于控制端 Gist 的 hosts 条目，无需任何写入 Gist 的凭据。
请在本机运行，因为重启 sshd 可能会中断现有的 SSH 会话。
.EXAMPLE
.\lazycat-ssh-node.ps1 -User lazycat -Alias win-dev-01 -Address win-dev-01.example.net -CaPublicKeyFile .\lazycat-ssh-ca.pub
.PARAMETER Port
向控制端公布的端口。省略时自动识别唯一生效的监听端口。
.PARAMETER Route
公布的端点所用的 Gist 路由：Lan（默认）、Wan 或 Tun。
.PARAMETER Via
可选，此路由所用跳板机的 LazyCat 别名。
.PARAMETER Status
显示 sshd 和 LazyCat 接入状态，不修改节点。
.PARAMETER Remove
移除 LazyCat 信任配置块，并恢复该账户之前的 SSH 策略。
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
        throw 'sshd_config 中的 LazyCat 标记无效。请先修复该受管配置块再继续。'
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
        throw "$([IO.Path]::GetFileName($Exe)) 执行失败：$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Assert-NodePath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "拒绝使用重解析点：$Path"
    }
}

function New-NodeCaFile([string]$Path, [string]$Contents) {
    if (Test-Path -LiteralPath $Path) {
        Assert-NodePath $Path
        if ([IO.File]::ReadAllText($Path, $utf8) -cne $Contents) {
            throw "CA 文件已存在，但内容不符合预期：$Path"
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
if (-not $service) { throw 'sshd 服务不存在。请先运行 setup-openssh.ps1。' }
$sshBin = Join-Path $env:WINDIR 'System32\OpenSSH'
$sshd = Join-Path $sshBin 'sshd.exe'
$keygen = Join-Path $sshBin 'ssh-keygen.exe'
$servicePath = [Environment]::ExpandEnvironmentVariables($service.PathName).Trim()
if ($servicePath -ine $sshd -and $servicePath -ine ('"' + $sshd + '"')) {
    throw "sshd 服务使用了自定义的可执行文件或参数：$servicePath。本脚本仅支持使用默认配置路径的 Windows 内置 OpenSSH。"
}
$configDir = Join-Path $env:ProgramData 'ssh'
$config = Join-Path $configDir 'sshd_config'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw 'sshd_config 不存在。请先运行 setup-openssh.ps1。'
}
Assert-NodePath $configDir
Assert-NodePath $config
$original = [IO.File]::ReadAllText($config, $utf8)
$parts = Get-NodeConfigParts $original

if ($Status) {
    Write-Output "sshd：$($service.State)"
    Write-Output "配置：$config"
    if ($parts.Managed) { Write-Output $parts.Managed.TrimEnd() }
    else { Write-Output 'LazyCat 节点尚未接入。' }
    return
}
if ($Remove -and -not $parts.Managed) {
    Write-Output 'LazyCat 节点已处于未接入状态。'
    return
}
if ($service.State -ne 'Running') {
    throw '修改接入状态前 sshd 必须处于运行状态。请先启动它，或先运行 setup-openssh.ps1。'
}

$candidateText = $parts.Unmanaged
$caPath = $null
$caContents = $null
$caFingerprint = $null
if (-not $Remove) {
    if (-not (Test-NodeAddress $Address)) { throw '请在 -Address 中指定 IPv4 地址、IPv6 地址或 DNS 主机名。' }
    $User = $User.ToLowerInvariant()
    $account = Get-LocalUser -Name $User
    if (-not $account.Enabled -or $account.PrincipalSource -ne 'Local') {
        throw "'$User' 必须是已启用的本地 Windows 账户。"
    }
    $adminGroup = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    if (Get-LocalGroupMember -SID $adminGroup | Where-Object { $_.SID -eq $account.SID }) {
        throw "'$User' 是本地管理员。请为 LazyCat SSH 选择标准用户。"
    }
    if ($candidateText -match '(?im)^[ \t]*(?:Include|TrustedUserCAKeys|AuthorizedPrincipalsFile|AuthorizedPrincipalsCommand)[ \t=]') {
        throw 'sshd_config 已包含其他配置文件或证书策略。接入此主机前，请先审阅现有的 SSH 策略。'
    }
    if ($candidateText -match '(?im)^[ \t]*AuthenticationMethods[ \t=]+(?!(?:any|publickey)(?:[ \t]*(?:#.*)?\r?$))') {
        throw 'sshd_config 中有自定义的 AuthenticationMethods 策略。接入此主机前请先审阅。'
    }
    $effective = @(Invoke-NodeOpenSsh $sshd @('-T', '-f', $config))
    if (-not $PSBoundParameters.ContainsKey('Port')) {
        $ports = @($effective | ForEach-Object {
            if ($_ -match '^listenaddress\s+\S+:(\d+)\s*$') { [int]$Matches[1] }
        } | Sort-Object -Unique)
        if ($ports.Count -ne 1) { throw '无法推断出唯一的监听端口。请用 -Port 指定要公布的端口。' }
        $Port = $ports[0]
    }

    $source = (Resolve-Path -LiteralPath $CaPublicKeyFile).ProviderPath
    $publicKey = [IO.File]::ReadAllText($source, $utf8).Trim()
    if ($publicKey -cnotmatch '\A(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))[ \t]+([A-Za-z0-9+/]+={0,2})(?:[ \t]+[^\r\n]*)?\z') {
        throw '-CaPublicKeyFile 中应当只有一个 SSH CA 公钥（Ed25519、RSA 或 ECDSA）。'
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

$action = if ($Remove) { '移除 LazyCat SSH 信任并重启 sshd' } else { "将 Windows 用户 '$User' 接入 LazyCat SSH" }
if (-not $PSCmdlet.ShouldProcess($config, $action)) { return }

$tempConfig = Join-Path $configDir ('.lazycat-node-' + [guid]::NewGuid() + '.tmp')
$probeConfig = "$tempConfig.probe"
$backup = "$config.lazycat-node-$([guid]::NewGuid()).bak"
$replaced = $false
$newCaFile = $false
try {
    if ($caPath) {
        $newCaFile = -not (Test-Path -LiteralPath $caPath)
        New-NodeCaFile $caPath $caContents
        $caFingerprint = (Invoke-NodeOpenSsh $keygen @('-l', '-E', 'sha256', '-f', $caPath)) -join ' '
        if ($caFingerprint -cnotmatch ('\bSHA256:' + [regex]::Escape($hash) + '(?:\s|$)')) {
            throw 'CA 文件未通过 SSH 公钥校验。'
        }
    }
    [IO.File]::WriteAllText($tempConfig, $candidateText, $utf8)
    Set-Acl -LiteralPath $tempConfig -AclObject (Get-Acl -LiteralPath $config)
    $null = Invoke-NodeOpenSsh $sshd @('-t', '-f', $tempConfig)
    if ($caPath) {
        # In-box sshd may need its LocalSystem service token to evaluate
        # existing Match Group blocks. Our block comes first and sets all
        # managed options, so probe it with only the global configuration.
        $firstMatch = [regex]::Match($parts.Unmanaged, '(?im)^[ \t]*Match(?:[ \t=]|\r?$)')
        $probePath = $tempConfig
        if ($firstMatch.Success) {
            [IO.File]::WriteAllText($probeConfig,
                (Add-NodeConfigBlock $parts.Unmanaged.Substring(0, $firstMatch.Index) ($block + $lineEnd)), $utf8)
            Set-Acl -LiteralPath $probeConfig -AclObject (Get-Acl -LiteralPath $config)
            $probePath = $probeConfig
        }
        $scoped = @(Invoke-NodeOpenSsh $sshd @('-T', '-f', $probePath, '-C',
            "user=$User,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=$Port"))
        $expectedCa = "trustedusercakeys $configCaPath"
        if (($scoped -inotcontains $expectedCa -and $scoped -inotcontains "trustedusercakeys $caPath") -or
            $scoped -notcontains 'authorizedprincipalsfile none' -or $scoped -notcontains 'authorizedkeysfile none' -or
            $scoped -notcontains 'pubkeyauthentication yes' -or $scoped -notcontains 'passwordauthentication no' -or
            $scoped -notcontains 'authenticationmethods publickey') {
            throw "sshd 未对 '$User' 应用预期的仅限证书的设置。"
        }
        $unscoped = @(Invoke-NodeOpenSsh $sshd @('-T', '-f', $tempConfig))
        if ($unscoped -notcontains 'trustedusercakeys none') { throw 'CA 信任未限定在目标用户范围内。' }
    }
    if ($candidateText -cne $original) {
        if ([IO.File]::ReadAllText($config, $utf8) -cne $original) {
            throw '接入过程中 sshd_config 被修改。请重新运行该命令。'
        }
        [IO.File]::Replace($tempConfig, $config, $backup)
        $replaced = $true
        Restart-Service -Name sshd
        (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        Write-Host "已将之前的配置保存到 $backup"
    }
} catch {
    if ($replaced) {
        try {
            [IO.File]::Replace($backup, $config, "$backup.failed")
            Restart-Service -Name sshd
            (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
            Write-Warning "已恢复之前的 SSH 配置。被拒绝的配置：$backup.failed"
            $replaced = $false
        } catch { Write-Warning "回滚失败：$_。请检查 $config 以及位于 $configDir 的备份。" }
    }
    if ($newCaFile -and -not $replaced) {
        Remove-Item -LiteralPath $caPath -Force -ErrorAction SilentlyContinue
    }
    throw
} finally {
    Remove-Item -LiteralPath $tempConfig, $probeConfig -Force -ErrorAction SilentlyContinue
}

if ($Remove) {
    Write-Output '已移除 LazyCat 信任。若此主机不应再出现在控制端，请另行删除对应的 Gist 条目。'
    return
}
Write-Host "CA 指纹：$caFingerprint"
Write-Host "请将此条目合并到控制端 Gist 中现有的 hosts 映射，然后同步并验证：ssh $Alias whoami"
$routeKey = $Route.ToLowerInvariant()
Write-Output @"
  '${Alias}':
    user: '$User'
    ${routeKey}_host: '$Address'
    ${routeKey}_port: $Port
"@
if ($Via) { Write-Output "    ${routeKey}_via: '$Via'" }
