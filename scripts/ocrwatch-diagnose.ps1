# ocrwatch-diagnose.ps1
param(
    [int]$EventCount = 10,
    [int]$LogTail = 20
)

$ConfigPath = Join-Path $PSScriptRoot "ocrwatch-config.ps1"
if (!(Test-Path $ConfigPath)) {
    Write-Host "Config not found: $ConfigPath" -ForegroundColor Red
    exit 1
}

. $ConfigPath

Import-Module (Join-Path $PSScriptRoot "OcrWatch.Common.psm1") -Force

function Get-TaskEvents {
    param(
        [string]$Name,
        [int]$MaxEvents
    )

    $taskPathFragment = "\$Name"
    try {
        Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -ErrorAction Stop |
            Where-Object {
                $_.Message -like "*$taskPathFragment*" -or
                $_.Properties.Value -contains $taskPathFragment
            } |
            Select-Object -First $MaxEvents
    } catch {
        @()
    }
}

function Show-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

Show-Section "Scheduled Task"
try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
    $principal = $task.Principal
    $action = $task.Actions | Select-Object -First 1

    Write-Host "Task name:        $TaskName"
    Write-Host "State:            $($task.State)"
    Write-Host "Enabled:          $($task.Settings.Enabled)"
    Write-Host "Last run time:    $($info.LastRunTime)"
    Write-Host "Last result:      $($info.LastTaskResult)"
    Write-Host "Result meaning:   $(Resolve-TaskSchedulerResultMessage -Code $info.LastTaskResult)"
    Write-Host "Next run time:    $($info.NextRunTime)"
    Write-Host "Run as user:      $($principal.UserId)"
    Write-Host "Logon type:       $($principal.LogonType)"
    Write-Host "Run level:        $($principal.RunLevel)"
    Write-Host "Action execute:   $($action.Execute)"
    Write-Host "Action arguments: $($action.Arguments)"
} catch {
    Write-Host "Failed to read scheduled task '$TaskName': $($_.Exception.Message)" -ForegroundColor Red
}

Show-Section "Watcher Process"
$watcherProcess = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*ocrwatch-watcher.ps1*" -and $_.CommandLine -notlike "*-Status*" } |
    Select-Object -First 1

if ($watcherProcess) {
    Write-Host "Running: yes" -ForegroundColor Green
    Write-Host "PID:     $($watcherProcess.ProcessId)"
    Write-Host "Command: $($watcherProcess.CommandLine)"
} else {
    Write-Host "Running: no" -ForegroundColor Yellow
}

Show-Section "Recent Task Scheduler Events"
$events = Get-TaskEvents -Name $TaskName -MaxEvents $EventCount
if ($events.Count -eq 0) {
    Write-Host "No matching events found in Microsoft-Windows-TaskScheduler/Operational." -ForegroundColor Yellow
    Write-Host "If this log is disabled, enable it in Event Viewer under Applications and Services Logs > Microsoft > Windows > TaskScheduler > Operational."
} else {
    foreach ($event in $events) {
        $message = ($event.Message -replace '\s+', ' ').Trim()
        Write-Host "[$($event.TimeCreated)] Id=$($event.Id)" -ForegroundColor DarkCyan
        Write-Host "  $message"
    }
}

Show-Section "Watcher Log"
if (Test-Path $LogFile) {
    Write-Host "Log file: $LogFile"
    Get-Content $LogFile -Tail $LogTail
} else {
    Write-Host "Log file not found: $LogFile" -ForegroundColor Yellow
}

Show-Section "Likely Causes"
Write-Host "If the task never starts and no watcher process appears, the most common causes are:"
Write-Host "  1. The task account is missing 'Log on as a batch job' or is blocked by a deny policy."
Write-Host "  2. Task Scheduler can read the task, but Windows rejects the stored credentials."
Write-Host "  3. PowerShell launches, but the script exits immediately before writing useful logs."
Write-Host "  4. The Task Scheduler Operational log is disabled, hiding the failure reason."
if ($events | Where-Object { $_.Message -match '2147943785|LogonUserExEx' }) {
    Write-Host ""
    Write-Host "Detected issue: Task Scheduler rejected the account during logon." -ForegroundColor Yellow
    Write-Host "Windows error 2147943785 = 0x80070569 = ERROR_LOGON_TYPE_NOT_GRANTED." -ForegroundColor Yellow
    Write-Host "Fix: grant the account 'Log on as a batch job' and ensure it is not listed under 'Deny log on as a batch job'." -ForegroundColor Yellow
}
