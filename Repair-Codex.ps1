#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Repair','Diagnose','Verify','Resume')][string]$Mode = 'Diagnose',
    [switch]$LibraryOnly,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$script:ServiceName = 'CodexSandboxService.OpenAI.Codex'
$script:ServiceKey = 'SYSTEM\CurrentControlSet\Services\CodexSandboxService.OpenAI.Codex'
$script:NativeKey = 'HKLM\SYSTEM\CurrentControlSet\Services\CodexSandboxService.OpenAI.Codex'
$script:Root = $PSScriptRoot
# 恢复数据与可分享的脚本分开；原始备份只留在当前用户的本机数据目录。
$script:DataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexRecovery'
$script:StatePath = Join-Path $script:DataRoot 'pending.json'
$script:RunOnceName = 'CodexRecoveryVerify'
$script:LogPath = $null

function Write-Status {
    param([string]$Message, [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray)
    # 仅接收程序内预设摘要，不接收异常正文、事件正文或外部命令输出。
    Write-Host $Message -ForegroundColor $ForegroundColor
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $Message -Encoding UTF8 }
}

function New-StateOwnerToken {
    Add-Type -AssemblyName System.Security
    $identity = [Environment]::MachineName + '|' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
    # DPAPI 由 Windows 当前用户加密；机器标识作为附加熵，防止跨电脑复用记录。
    $entropy = [Text.Encoding]::UTF8.GetBytes([Environment]::MachineName)
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Test-StateOwner($State) {
    # 待重启记录属于原电脑和原用户，复制工具时不得将其套用到另一台机器。
    try {
        Add-Type -AssemblyName System.Security
        if (!$State.OwnerToken) { return $false }
        $entropy = [Text.Encoding]::UTF8.GetBytes([Environment]::MachineName)
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($State.OwnerToken), $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $expected = [Environment]::MachineName + '|' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        return [Text.Encoding]::UTF8.GetString($bytes) -eq $expected
    } catch { return $false }
}

function Get-ServiceRegistration {
    # 使用原生注册表读取，避免服务停止/删除后 PowerShell provider 缓存造成误判。
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:ServiceKey)
    if ($null -eq $key) { return $null }
    try { return [pscustomobject]@{ PackageFullName=$key.GetValue('PackageFullName'); ImagePath=$key.GetValue('ImagePath') } }
    finally { $key.Dispose() }
}

function Test-RepairEvidence($Package, $Registration, $Events) {
    # 仅处理已经在本机反复复现的更新冲突，不将网络或普通启动问题套用此修复。
    if (!$Package -or [string]$Package.Status -ne 'Servicing' -or !$Registration) { return $false }
    if (!$Registration.PackageFullName -or $Registration.PackageFullName -eq $Package.PackageFullName) { return $false }
    $matching = @($Events | Where-Object {
        $_.Message -like ('*' + $Package.PackageFullName + '*') -and
        $_.Message -match 'windows\.service' -and $_.Message -match '0x80070005'
    })
    return $matching.Count -gt 0
}

function Get-Snapshot {
    $packages = @(Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending)
    $package = $packages | Select-Object -First 1
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName='Microsoft-Windows-AppXDeploymentServer/Operational'; StartTime=(Get-Date).AddHours(-24); Level=2
    } -MaxEvents 500 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'OpenAI\.Codex' })
    $registration = Get-ServiceRegistration
    $service = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Package=$package; Registration=$registration; Events=$events;
        ServiceStatus=if($service){[string]$service.Status}else{'Absent'};
        BootTime=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
}

function Show-Snapshot($Snapshot) {
    # 输出白名单摘要，不打印启动时间、版本、路径、主机名、身份或原始日志。
    if (!$Snapshot.Package) { Write-Status '程序包状态：未注册。' }
    elseif ([string]$Snapshot.Package.Status -eq 'Ok') { Write-Status '程序包状态：正常。' }
    elseif ([string]$Snapshot.Package.Status -eq 'Servicing') { Write-Status '程序包状态：正在维护。' }
    else { Write-Status '程序包状态：需要检查。' }
    if ($Snapshot.ServiceStatus -eq 'Running') { Write-Status '服务状态：运行中。' }
    elseif ($Snapshot.ServiceStatus -eq 'Stopped') { Write-Status '服务状态：已停止。' }
    else { Write-Status '服务状态：未运行或不存在。' }
    if (Test-RepairEvidence $Snapshot.Package $Snapshot.Registration $Snapshot.Events) {
        Write-Status '故障证据：符合旧版本服务注册冲突，错误码 0x80070005。'
    } else { Write-Status '故障证据：未匹配自动清理条件。' }
}

function Invoke-Verification($Snapshot) {
    $verificationStart = Get-Date
    if (!$Snapshot.Package -or [string]$Snapshot.Package.Status -ne 'Ok') {
        Write-Status '尚未恢复：程序包未达到 Ok。请保留日志进一步排查，不会循环删除服务。' -ForegroundColor Yellow
        return
    }
    $reg = $Snapshot.Registration
    $serviceMatches = $reg -and $reg.PackageFullName -eq $Snapshot.Package.PackageFullName -and
        $reg.ImagePath -and $reg.ImagePath.StartsWith($Snapshot.Package.InstallLocation + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $reg.ImagePath)
    if (!$serviceMatches) { Write-Status '尚未恢复：沙箱服务版本/路径缺失或不匹配。' -ForegroundColor Yellow; return }
    $desktop = Join-Path $Snapshot.Package.InstallLocation 'app\ChatGPT.exe'
    if (!(Test-Path -LiteralPath $desktop)) { Write-Status '尚未恢复：桌面程序文件不存在。'; return }
    # 通过当前用户的 AppX 入口激活，避免运行旧版本 EXE。
    Start-Process explorer.exe -ArgumentList ('shell:AppsFolder\' + $Snapshot.Package.PackageFamilyName + '!App')
    Start-Sleep -Seconds 8
    $processes = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.Equals($desktop, [StringComparison]::OrdinalIgnoreCase)
    })
    $service = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
    $freshErrors = @(Get-WinEvent -FilterHashtable @{
        LogName='Microsoft-Windows-AppXDeploymentServer/Operational'; StartTime=$verificationStart; Level=2
    } -MaxEvents 100 -ErrorAction SilentlyContinue | Where-Object {
        $_.Message -like ('*' + $Snapshot.Package.PackageFullName + '*')
    })
    if ($processes.Count -gt 0 -and $service.Status -eq 'Running' -and $freshErrors.Count -eq 0) {
        Write-Status '本地启动检查通过：程序包 Ok、服务版本匹配且运行、桌面进程存在。' -ForegroundColor Green
        Write-Status '请在窗口确认能加载组织设置和会话；本工具未验证在线请求。'
    } else { Write-Status '验证未通过：桌面进程或沙箱服务尚未正常运行，请查看日志。' -ForegroundColor Yellow }
}

function Invoke-Repair($Snapshot) {
    if (!(Test-RepairEvidence $Snapshot.Package $Snapshot.Registration $Snapshot.Events)) {
        Write-Status '未满足已知故障条件，不删除任何服务。可双击 Check-Codex.cmd 查看状态。' -ForegroundColor Yellow
        return
    }
    if (Test-Path -LiteralPath $script:StatePath) {
        $oldState = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (!(Test-StateOwner $oldState)) {
            throw 'pending.json 不属于当前电脑/用户或来自旧版工具。请保留原记录，使用干净的工具包。'
        }
        if ($oldState.Phase -eq 'Removed' -and $Snapshot.BootTime.ToUniversalTime().Ticks -le [long]$oldState.BootTicks) {
            Write-Status '已有清理记录，等待真实重启，不重复删除。'; return
        }
    }
    $backupDir = Join-Path $script:DataRoot 'backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $backup = Join-Path $backupDir ('CodexSandboxService-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.reg')
    & reg.exe export $script:NativeKey $backup /y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '注册表导出失败，已停止。' }
    $content = Get-Content -LiteralPath $backup -Encoding Unicode -Raw
    if ((Get-Item -LiteralPath $backup).Length -lt 500 -or $content -notmatch 'Windows Registry Editor Version 5.00' -or
        $content -notmatch '\[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\CodexSandboxService\.OpenAI\.Codex\]' -or
        $content -notmatch '"ImagePath"=') { throw '备份内容校验失败，未删除。' }
    Write-Status '备份已校验，保存在当前用户本机数据目录的 CodexRecovery/backups。'
    $state = [ordered]@{Phase='Prepared'; Backup=(Join-Path 'backups' ([IO.Path]::GetFileName($backup)));
        OwnerToken=(New-StateOwnerToken);
        BootTicks=$Snapshot.BootTime.ToUniversalTime().Ticks; Package=$Snapshot.Package.PackageFullName}
    $state | ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
    $resume = '"' + $PSHOME + '\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode Resume'
    # 用户下次登录仅验证一次，不安装常驻任务、不自动循环清理。
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $script:RunOnceName -Value $resume -PropertyType String -Force | Out-Null
    try {
        # 导出后再次比对，防止商店在备份期间已经完成更新而误删新注册。
        $latest = Get-Snapshot
        if (!(Test-RepairEvidence $latest.Package $latest.Registration $latest.Events) -or
            $latest.Package.PackageFullName -ne $Snapshot.Package.PackageFullName -or
            $latest.Registration.PackageFullName -ne $Snapshot.Registration.PackageFullName) {
            throw '备份期间包/服务状态已改变，停止清理，请重新检查。'
        }
        & sc.exe stop $script:ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & reg.exe delete $script:NativeKey /f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '删除服务注册项失败。' }
        if ($null -ne (Get-ServiceRegistration)) { throw '删除后注册项仍存在。' }
    } catch {
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $script:RunOnceName -ErrorAction SilentlyContinue
        throw
    }
    $state.Phase = 'Removed'
    $state | ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
    Write-Status 'Codex 服务注册项已删除。必须完整重启以清除服务管理器中的旧记录。'
    Write-Status '请保存所有工作。输入 Y 将在 60 秒后重启；其他输入则稍后自行重启。'
    if ((Read-Host '现在重启？[Y/N]') -ieq 'Y') {
        & shutdown.exe /r /t 60 /c 'Codex 服务修复后重启，请保存工作' /d p:4:1 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '安排重启失败，请手动重启。' }
        Write-Status '已安排真实重启；如需取消，在命令提示符执行 shutdown /a。'
    } else { Write-Status '尚未重启。请选择 Windows 开始菜单中的“重启”，下次登录自动复查。' }
}

function Invoke-Resume($Snapshot) {
    if (!(Test-Path -LiteralPath $script:StatePath)) { Write-Status '没有待完成的修复记录。'; return }
    $state = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (!(Test-StateOwner $state)) { throw '待复查记录不属于当前电脑/用户或来自旧版工具，不执行恢复操作。' }
    if ($state.Phase -ne 'Removed') { Write-Status '上次未完成清理，停止自动处理，请查看日志。'; return }
    if ($Snapshot.BootTime.ToUniversalTime().Ticks -le [long]$state.BootTicks) { Write-Status '尚未发生真实重启，请重启后再验证。'; return }
    # 重启后仅在服务键缺失且当前包仍卡住时尝试一次正常 AppX 注册。
    if ($Snapshot.Package -and [string]$Snapshot.Package.Status -eq 'Servicing' -and !$Snapshot.Registration) {
        $manifest = Join-Path $Snapshot.Package.InstallLocation 'AppxManifest.xml'
        if (!(Test-Path -LiteralPath $manifest)) { throw '找不到当前包清单，无法重新注册。' }
        Add-AppxPackage -DisableDevelopmentMode -Register $manifest
        $Snapshot = Get-Snapshot
    }
    Show-Snapshot $Snapshot
    Invoke-Verification $Snapshot
    # 保留历史状态以便排查，后续修复会生成新的备份。
    Move-Item -LiteralPath $script:StatePath -Destination (Join-Path $script:DataRoot ('completed-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json'))
}

if ($LibraryOnly) { return }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此工具仅支持 Windows AppX 版 Codex。' }
if ($PSVersionTable.PSEdition -eq 'Core' -or ![Environment]::Is64BitProcess) {
    # 不依赖终端的当前目录或 PATH 中的 PowerShell 版本；Appx 使用系统自带的 64 位运行时。
    $systemDir = if ([Environment]::Is64BitOperatingSystem -and ![Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $windowsPowerShell = Join-Path $env:SystemRoot ($systemDir + '\WindowsPowerShell\v1.0\powershell.exe')
    $forward = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Mode',$Mode)
    if ($NoPause) { $forward += '-NoPause' }
    & $windowsPowerShell @forward
    exit $LASTEXITCODE
}
if ($Mode -eq 'Repair') {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$admin) {
        # 编码固定脚本入口，避免含空格或单引号的路径被提权参数错误解析。
        $escaped = $PSCommandPath.Replace("'", "''")
        $command = "& '$escaped' -Mode Repair"
        if ($NoPause) { $command += ' -NoPause' }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded) -Wait
        exit
    }
}
$logDir = Join-Path $script:DataRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
# 使用独占文件句柄防止重复双击同时清理；关闭进程后锁自动释放。
try { $runLock = [IO.File]::Open((Join-Path $script:DataRoot '.running.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { Write-Status '已有恢复工具正在运行，请先关闭原窗口。'; exit 1 }
$script:LogPath = Join-Path $logDir ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Mode + '.log')
try {
    Write-Status "Codex 恢复工具 / $Mode"
    $snapshot = Get-Snapshot
    Show-Snapshot $snapshot
    switch ($Mode) {
        'Repair' { Invoke-Repair $snapshot }
        'Verify' { Invoke-Verification $snapshot }
        'Resume' { Invoke-Resume $snapshot }
        'Diagnose' { Write-Status "符合已知清理条件：$(Test-RepairEvidence $snapshot.Package $snapshot.Registration $snapshot.Events)" }
    }
} catch {
    # 不直接输出 ErrorRecord，异常中可能包含用户名、路径或事件原文。
    Write-Status '处理失败：操作未完成。请检查权限、修复状态或交由人工排查；不输出原始异常。' -ForegroundColor Red
    Write-Status '请保留本机备份，不要手动批量删除服务。'
}
finally {
    Write-Status '摘要日志位于当前用户本机数据目录的 CodexRecovery/logs；不包含原始终端转录。'
    $runLock.Dispose()
    if (!$NoPause -and [Environment]::UserInteractive) { Read-Host '按 Enter 关闭窗口' | Out-Null }
}
