# NEW helper (2026-11-14). Starts scripts/v7_power_iisc.ps1 for the given
# windows (in order, one after the other) through a one-shot Windows scheduled
# task with a hidden window (same pattern as launch_iisc_conv_detached.ps1,
# unchanged). Output: synth_build_2026/v7_power/iisc/run_<windows>.txt
# Usage: powershell -File scripts\launch_v7_power_iisc_detached.ps1 -Windows conv,all
param([Parameter(Mandatory)][string]$Windows)
$list = $Windows -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root ("synth_build_2026\v7_power\iisc\run_{0}.txt" -f ($list -join '_'))
$name = 'ATEE_v7_power_iisc'
$cmds = ($list | ForEach-Object { "& '$root\scripts\v7_power_iisc.ps1' -Window $_" }) -join '; '
$arg  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& { $cmds } *> '$out'`""
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $root
$trg  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 24) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $name -Action $act -Trigger $trg -Settings $set -Force | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTaskInfo -TaskName $name
    if ($info.LastRunTime -gt (Get-Date).AddMinutes(-5)) { break }
}
"{0}: started {1}, log {2}" -f $name, $info.LastRunTime, $out
Unregister-ScheduledTask -TaskName $name -Confirm:$false
