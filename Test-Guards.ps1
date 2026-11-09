#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Repair-Codex.ps1') -LibraryOnly
$package=[pscustomobject]@{Status='Servicing';PackageFullName='OpenAI.Codex_NEW'}
$old=[pscustomobject]@{PackageFullName='OpenAI.Codex_OLD'}
$same=[pscustomobject]@{PackageFullName='OpenAI.Codex_NEW'}
$event=[pscustomobject]@{Message='OpenAI.Codex_NEW windows.service 0x80070005'}
$cases=@(
    @{Name='Known failure';Package=$package;Registration=$old;Events=@($event);Expected=$true},
    @{Name='Missing package';Package=$null;Registration=$old;Events=@($event);Expected=$false},
    @{Name='Missing service';Package=$package;Registration=$null;Events=@($event);Expected=$false},
    @{Name='Matching service';Package=$package;Registration=$same;Events=@($event);Expected=$false},
    @{Name='No deployment evidence';Package=$package;Registration=$old;Events=@();Expected=$false},
    @{Name='Other package failure';Package=$package;Registration=$old;Events=@([pscustomobject]@{Message='OtherApp windows.service 0x80070005'});Expected=$false},
    @{Name='Other error';Package=$package;Registration=$old;Events=@([pscustomobject]@{Message='OpenAI.Codex_NEW windows.service 0x80070002'});Expected=$false},
    @{Name='Network failure';Package=$package;Registration=$old;Events=@([pscustomobject]@{Message='OpenAI.Codex_NEW network timeout'});Expected=$false},
    @{Name='Healthy package';Package=[pscustomobject]@{Status='Ok';PackageFullName='OpenAI.Codex_NEW'};Registration=$old;Events=@($event);Expected=$false}
)
foreach($case in $cases){
    $actual=Test-RepairEvidence $case.Package $case.Registration $case.Events
    if($actual -ne $case.Expected){throw "Guard failed: $($case.Name)"}
    Write-Output "PASS: $($case.Name)"
}
# 用当前机器快照验证保护分支；不会进入清理、提权或重启操作。
$snapshot=Get-Snapshot
if([string]$snapshot.Package.Status -eq 'Ok'){
    Invoke-Repair $snapshot
    if(!(Get-ServiceRegistration)){throw 'Healthy registration unexpectedly absent'}
    Write-Output 'PASS: current healthy machine bypasses repair'
}
$errors=$null
$tokens=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Repair-Codex.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw ($errors | Out-String)}
Write-Output 'PASS: Windows PowerShell syntax'
$owner=[pscustomobject]@{OwnerToken=(New-StateOwnerToken)}
if(!(Test-StateOwner $owner)){throw 'Current owner rejected'}
if(Test-StateOwner ([pscustomobject]@{OwnerToken='invalid'})){throw 'Invalid token accepted'}
if(Test-StateOwner ([pscustomobject]@{Phase='Removed'})){throw 'Legacy state accepted'}
$json=$owner | ConvertTo-Json
foreach($private in @([Environment]::MachineName,[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)){
    if($json.Contains($private)){throw 'Owner token contains plaintext identity'}
}
Write-Output 'PASS: encrypted owner token and rejected legacy/invalid states'
$privateSentinel='PRIVATE_SENTINEL_DO_NOT_PRINT'
$privateSnapshot=[pscustomobject]@{
    Package=[pscustomobject]@{Status=$privateSentinel;PackageFullName=$privateSentinel}
    Registration=[pscustomobject]@{ImagePath=$privateSentinel;PackageFullName=$privateSentinel}
    ServiceStatus=$privateSentinel;BootTime=$privateSentinel
    Events=@([pscustomobject]@{Message=$privateSentinel})
}
$display=& { Show-Snapshot $privateSnapshot } 6>&1 | Out-String
if($display.Contains($privateSentinel)){throw 'Snapshot emitted private data'}
Write-Output 'PASS: snapshot output excludes paths, identities and raw events'
