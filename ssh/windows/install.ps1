<#
.SYNOPSIS
把 Windows 设备接入 LazyCat SSH 被控端的一行粘贴入口。
.DESCRIPTION
在 Windows PowerShell 中粘贴运行（不是管理员时会通过 UAC 自动以管理员重开）：

  [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; & ([scriptblock]::Create((irm https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/windows/install.ps1).TrimStart([char]0xFEFF)))

不带参数时显示菜单，只询问无法推断的值。它把 setup-openssh.ps1 和
lazycat-ssh-node.ps1 下载到 %ProgramData%\LazyCat\ssh-windows，安装系统自带的
OpenSSH Server，缺少登录账号时创建普通账号，并接入 LazyCat CA。两个底层脚本均可
重复执行，重跑会保留已有状态。

本文件以带 BOM 的 UTF-8 保存：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 中文按
系统代码页误读。粘贴入口用 TrimStart 去掉网络取回文本开头的 BOM。
.PARAMETER CaPublicKey
CA 公钥整行（在 CA 端执行 cat ~/.lazycat/ssh-ca/lazycat-ssh-ca.pub）。
.PARAMETER Alias
控制端使用的别名。默认为小写的计算机名。
.PARAMETER Address
控制端连接本机使用的地址。默认取有默认网关的物理网卡 IPv4，忽略代理 TUN、VPN、虚拟机等虚拟网卡。
.PARAMETER User
证书登录使用的本地普通账号，缺失时自动创建。默认 lazycat。
.PARAMETER AllowedRemoteAddress
传给 setup-openssh.ps1 的防火墙来源。默认 LocalSubnet。
.PARAMETER FirewallProfile
防火墙配置文件。默认 Domain,Private；连接所用网络为公用网络且同意时加上 Public。
.PARAMETER Source
两个底层脚本所在的目录或 URL。默认使用本文件所在目录（含这两个脚本时），否则使用
LAZYCAT_SSH_WINDOWS_SOURCE 或 ep 镜像。
.PARAMETER Yes
全部采用默认值，不再询问；缺少必填值时报错。
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
# Inside a function $PSBoundParameters is that function's own; keep the script's.
$scriptParameters = $PSBoundParameters

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
        else { "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; & ([scriptblock]::Create((Invoke-RestMethod $(Format-Literal "$mirror/install.ps1")).TrimStart([char]0xFEFF)))" }
    foreach ($entry in $scriptParameters.GetEnumerator()) {
        $value = $entry.Value
        if ($value -is [switch]) { if ($value.IsPresent) { $invocation += " -$($entry.Key)" } }
        elseif ($value -is [array]) { $invocation += " -$($entry.Key) " + (($value | ForEach-Object { Format-Literal ([string]$_) }) -join ',') }
        else { $invocation += " -$($entry.Key) " + (Format-Literal ([string]$value)) }
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    Write-Host '需要管理员权限。请在弹出的 UAC 窗口中同意，随后会在新的管理员窗口中继续。'
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
        # Raw bytes keep the UTF-8 BOM that Windows PowerShell 5.1 needs.
        if ($remote) { Invoke-WebRequest -UseBasicParsing -Uri ($origin.TrimEnd('/') + "/$name") -OutFile $partial }
        else { Copy-Item -LiteralPath (Join-Path $origin $name) -Destination $partial -Force }
        # Reject an empty or truncated download before replacing a working copy.
        $text = [IO.File]::ReadAllText($partial)
        if ($text -notmatch '\A#Requires -Version 5\.1' -or $text -notmatch '(?m)^\$ErrorActionPreference = ''Stop''') {
            Remove-Item -LiteralPath $partial -Force
            throw "下载的 $name 不完整或内容异常，未做任何改动。"
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
    }
    # Local files are subject to the execution policy; pasted entries are not.
    try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { Write-Warning "无法放宽当前进程的脚本执行策略：$_" }
    @{ Setup = (Join-Path $work $scripts[0]); Node = (Join-Path $work $scripts[1]) }
}

function Get-PhysicalInterface {
    # Proxy TUN (e.g. Clash/Meta, 198.18.0.0/15), VPN, Hyper-V and other
    # virtual adapters are not reachable from other devices on the LAN.
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { $_.ifIndex })
}

function Get-DefaultAddress {
    $physical = Get-PhysicalInterface
    $candidates = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $physical -contains $_.InterfaceIndex -and $_.IPAddress -notmatch '^(127\.|169\.254\.|198\.1[89]\.)'
    })
    $routed = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway } | ForEach-Object { $_.InterfaceIndex })
    $preferred = @($candidates | Where-Object { $routed -contains $_.InterfaceIndex })
    if ($preferred.Count -gt 0) { return $preferred[0].IPAddress }
    if ($candidates.Count -gt 0) { return $candidates[0].IPAddress }
    return ''
}

function Get-PublicNetwork([string]$ConnectAddress) {
    # Judge the network that actually carries the controller's connection:
    # the interface owning the address when it is local, else physical adapters.
    $owner = @(Get-NetIPAddress -IPAddress $ConnectAddress -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceIndex })
    $interfaces = if ($owner.Count -gt 0) { $owner } else { Get-PhysicalInterface }
    @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object {
        $interfaces -contains $_.InterfaceIndex -and [string]$_.NetworkCategory -eq 'Public'
    })
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
    Write-Host "已创建本地普通账号 '$Name'。"
}

function Invoke-Join($files) {
    $key = $CaPublicKey
    while (-not $key) {
        if ($Yes) { throw '请通过 -CaPublicKey 提供 CA 公钥。' }
        Write-Host '请粘贴 CA 公钥。在 CA 端执行：cat ~/.lazycat/ssh-ca/lazycat-ssh-ca.pub'
        $key = (Read-Host 'CA 公钥').Trim()
    }
    if ($key.Trim() -cnotmatch '\A(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521))[ \t]+[A-Za-z0-9+/]+={0,2}([ \t]+[^\r\n]*)?\z') {
        throw 'CA 公钥必须是以 ssh-ed25519、ssh-rsa 或 ecdsa-sha2-* 开头的一整行。'
    }
    $alias = if ($Alias) { $Alias } else { Read-Default '控制端使用的别名' (Get-DefaultAlias) }
    $address = if ($Address) { $Address } else { Read-Default '控制端连接本机的地址' (Get-DefaultAddress) }
    if (-not $address) { throw '未能检测到可用地址，请通过 -Address 指定。' }
    $account = $User.ToLowerInvariant()
    $sources = if ($AllowedRemoteAddress) { $AllowedRemoteAddress } else { @((Read-Default '允许连接的来源（IP、CIDR 网段或 LocalSubnet，多个用逗号分隔）' 'LocalSubnet') -split '\s*,\s*') }
    $profiles = $FirewallProfile
    if (-not $profiles) {
        $profiles = @('Domain', 'Private')
        $public = Get-PublicNetwork $address
        if ($public.Count -gt 0) {
            Write-Host "连接所用的网络「$($public[0].Name)」是公用网络，防火墙规则默认不在公用网络下生效。"
            if (Confirm-Step '是否也在公用网络下放行 SSH（仍只限上面填写的来源）？' $true) { $profiles += 'Public' }
        }
    }
    $existing = Get-LocalUser -Name $account -ErrorAction SilentlyContinue
    # Refuse before changing anything; the node script would reject it after OpenSSH setup.
    if ($existing -and (Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID -eq $existing.SID })) {
        throw "'$account' 是本地管理员账号。请用 -User 指定一个普通账号名，例如 lazycat。"
    }

    Write-Host ''
    Write-Host '即将执行：'
    Write-Host "  - 安装并配置系统自带的 OpenSSH Server（来源：$($sources -join ', ')；网络类型：$($profiles -join ', ')）"
    if (-not $existing) { Write-Host "  - 创建本地普通账号 '$account'" }
    Write-Host "  - 为 '$account' 接入 LazyCat CA，别名 '$alias'，地址 $address（会重启 sshd）"
    if (-not (Confirm-Step '继续？' $true)) { Write-Host '已取消，未做任何改动。'; return }

    $setupArgs = @{ AllowedRemoteAddress = $sources; FirewallProfile = $profiles }
    if ($Port) { $setupArgs.Port = $Port }
    & $files.Setup @setupArgs | Out-Host
    if (-not $existing) { New-StandardUser $account }

    $caFile = Join-Path $work 'lazycat-ssh-ca.pub'
    [IO.File]::WriteAllText($caFile, $key.Trim() + "`n", [Text.UTF8Encoding]::new($false))
    $joinArgs = @{ User = $account; Alias = $alias; Address = $address; CaPublicKeyFile = $caFile; Route = $Route }
    if ($Port) { $joinArgs.Port = $Port }
    if ($Via) { $joinArgs.Via = $Via }
    $entry = ((& $files.Node @joinArgs) -join "`n") -replace "`r", ''

    Write-Host ''
    Write-Host '本机已完成。接下来在控制端：'
    Write-Host '  1. 把下面这段加到 Gist 的 hosts: 下：'
    Write-Host ''
    Write-Host $entry
    Write-Host ''
    Write-Host "  2. 在 Gist 的 ca.principals 末尾追加 $account（保留原有的值）。"
    Write-Host '  3. 运行 lazycat-ssh，选择 2) 同步，同步时会重新申请证书。'
    Write-Host "  4. 测试：ssh $alias whoami（首次连接时核对上面显示的主机公钥指纹）"
    # The entry alone on the pipeline, for callers that capture it.
    Write-Output $entry
}

if (-not (Test-Administrator)) {
    if ($Yes) { throw '请在管理员身份的 Windows PowerShell 中运行。' }
    Restart-Elevated
    return
}

$mode = $PSCmdlet.ParameterSetName
if ($mode -eq 'Join' -and -not $CaPublicKey -and -not $Yes) {
    Write-Host 'LazyCat SSH Windows 被控端'
    Write-Host '  1) 接入或更新本机'
    Write-Host '  2) 查看状态'
    Write-Host '  3) 撤销 LazyCat 接入'
    Write-Host '  q) 退出'
    switch ((Read-Host '请选择 [1]').Trim()) {
        { $_ -in '', '1' } { $mode = 'Join' }
        '2' { $mode = 'Status' }
        '3' { $mode = 'Remove' }
        default { return }
    }
}

$files = Get-Scripts
switch ($mode) {
    'Status' {
        & $files.Setup -Status | Out-Host
        & $files.Node -Status | Out-Host
    }
    'Remove' {
        if (-not (Confirm-Step '撤销 LazyCat 证书登录，并恢复原来的 SSH 配置？' $true)) { return }
        & $files.Node -Remove -Confirm:$false | Out-Host
        Write-Host 'OpenSSH Server、防火墙规则和登录账号均已保留。账号不再需要时可删除，例如：Remove-LocalUser lazycat'
        Write-Host '还需要删除 Gist 中的条目并同步，控制端才不再显示这台机器。'
    }
    default { Invoke-Join $files }
}
