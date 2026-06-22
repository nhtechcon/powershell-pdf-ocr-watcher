# check-ocr-logs.ps1
param(
    [int]$Tail = 20,
    [switch]$All,
    [switch]$Follow
)

# Load shared configuration
$ConfigPath = Join-Path $PSScriptRoot "ocrwatch-config.ps1"
if (!(Test-Path $ConfigPath)) { Write-Host "Config not found: $ConfigPath" -ForegroundColor Red; exit 1 }
. $ConfigPath

if (!(Test-Path $LogFile)) {
    Write-Host "Log file not found: $LogFile" -ForegroundColor Red
    exit 1
}

if ($Follow) {
    Write-Host "Following log file (Ctrl+C to stop)..." -ForegroundColor Cyan
    Get-Content $LogFile -Wait -Tail 10
    exit 0
}

if ($All) {
    Get-Content $LogFile
} else {
    Write-Host "Last $Tail log entries:" -ForegroundColor Cyan
    Get-Content $LogFile -Tail $Tail
}
