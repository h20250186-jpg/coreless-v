# NEW helper (2026-11-11). Starts one run_iisc_conv_sizes.ps1 simulation through
# a one-shot Windows scheduled task, so it runs outside the Claude Code session's
# console (WMI-launched runs received console Ctrl+C breaks on 2026-11-11).
# The task is unregistered right after it has started; the simulation keeps
# running. Output goes to sim_build\iisc_conv_logs\iisc_conv<Size>_<StandIn>.txt.
# Usage: powershell -File scripts\launch_iisc_conv_detached.ps1 -Size 32 -StandIn assumed
param([Parameter(Mandatory)][int]$Size, [ValidateSet('assumed','zero')][string]$StandIn = 'assumed')
$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root 'sim_build\iisc_conv_logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$out  = Join-Path $logs "iisc_conv${Size}_$StandIn.txt"
$name = "ATEE_iisc_conv${Size}_$StandIn"
# Hidden window (2026-11-11): a visible console window received Ctrl+C mid-run.
$arg  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& '$root\scripts\run_iisc_conv_sizes.ps1' -Size $Size -StandIn $StandIn *> '$out'`""
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $root
$trg  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 12) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set -Force | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTaskInfo -TaskName $name
    if ($info.LastRunTime -gt (Get-Date).AddMinutes(-5)) { break }
}
"{0}: started {1}, log {2}" -f $name, $info.LastRunTime, $out
# Unregistering a RUNNING task does not stop it; the task entry is removed.
Unregister-ScheduledTask -TaskName $name -Confirm:$false
