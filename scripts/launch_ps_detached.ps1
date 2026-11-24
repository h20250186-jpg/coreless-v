# NEW helper (2026-11-14). Runs one PowerShell script (no arguments) through a
# one-shot Windows scheduled task with a hidden window, output to -Out (same
# pattern as launch_iisc_conv_detached.ps1, unchanged).
# Usage: powershell -File scripts\launch_ps_detached.ps1 -Script scripts\v7_rtlsaif_iisc.ps1 -Out <log> -Name <task name>
param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string]$Name)
$root = Split-Path -Parent $PSScriptRoot
$sp   = (Resolve-Path (Join-Path $root $Script)).Path
$arg  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& { & '$sp' } *> '$Out'`""
$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg -WorkingDirectory $root
$trg  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(3)
$set  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 24) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $Name -Action $act -Trigger $trg -Settings $set -Force | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTaskInfo -TaskName $Name
    if ($info.LastRunTime -gt (Get-Date).AddMinutes(-5)) { break }
}
"{0}: started {1}, log {2}" -f $Name, $info.LastRunTime, $Out
Unregister-ScheduledTask -TaskName $Name -Confirm:$false
