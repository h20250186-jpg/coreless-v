# NEW helper (2026-11-13). Starts one Vivado 2026.1 batch run through a one-shot
# Windows scheduled task (hidden window), so it runs outside the Claude Code
# session's console and survives a session end. Same pattern as
# scripts/launch_iisc_conv_detached.ps1 (unchanged). The task entry is removed
# once the run has started; the run keeps going.
# Log: synth_build_2026/v7_xc7vx485t/logs/<Tag>.log
# Usage: powershell -File scripts\launch_vivado2026_detached.ps1 -Tcl scripts\v7_impl_atee.tcl -Tag atee_vl16 [-TclArgs vl16]
param([Parameter(Mandatory)][string]$Tcl, [Parameter(Mandatory)][string]$Tag, [string]$TclArgs = '')
$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root 'synth_build_2026\v7_xc7vx485t\logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$log  = Join-Path $logs "$Tag.log"
$jou  = Join-Path $logs "$Tag.jou"
$tclp = (Resolve-Path (Join-Path $root $Tcl)).Path -replace '\\','/'
$ta   = if ($TclArgs) { "-tclargs $TclArgs" } else { '' }
. (Join-Path $PSScriptRoot '..\tools\load_paths.ps1')
$cmd  = "/c `"$VIVADO2026_ROOT\bin\vivado.bat -mode batch -log `"$log`" -journal `"$jou`" -source `"$tclp`" $ta`""
$name = "ATEE_v7_$Tag"
$act  = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmd -WorkingDirectory $root
$trg  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set -Force | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTaskInfo -TaskName $name
    if ($info.LastRunTime -gt (Get-Date).AddMinutes(-5)) { break }
}
"{0}: started {1}, log {2}" -f $name, $info.LastRunTime, $log
Unregister-ScheduledTask -TaskName $name -Confirm:$false
