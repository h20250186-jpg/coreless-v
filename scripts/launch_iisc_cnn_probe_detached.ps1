# NEW helper (2026-11-16), same method as launch_iisc_conv_detached.ps1
# (unchanged): one-shot scheduled task, hidden window, outside the session
# console. Runs scripts/run_iisc_cnn_probe.ps1 once per argument string in
# -Runs (in order). Output in sim_build\iisc_cnn_probe\logs\task_<Name>.txt.
# Usage: powershell -File scripts\launch_iisc_cnn_probe_detached.ps1 -Name zA -Runs '-StandIn zero -From 0 -To 49'
param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Runs)
$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root 'sim_build\iisc_cnn_probe\logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$out  = Join-Path $logs "task_$Name.txt"
$task = "ATEE_iisc_cnn_probe_$Name"
$cmd  = ($Runs | ForEach-Object { "& '$root\scripts\run_iisc_cnn_probe.ps1' $_" }) -join '; '
$arg  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd *> '$out'`""
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $root
$trg  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 30) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Settings $set -Force | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTaskInfo -TaskName $task
    if ($info.LastRunTime -gt (Get-Date).AddMinutes(-5)) { break }
}
"{0}: started {1}, log {2}" -f $task, $info.LastRunTime, $out
Unregister-ScheduledTask -TaskName $task -Confirm:$false
