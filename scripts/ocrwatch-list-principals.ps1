# ocrwatch-list-principals.ps1
# Lists likely principals that can be used in WatchFolderPrincipals

$computerName = $env:COMPUTERNAME
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

Write-Host "=== Suggested WatchFolderPrincipals ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "Current user:" -ForegroundColor Yellow
Write-Host "  $currentUser"
Write-Host ""

Write-Host "Local users:" -ForegroundColor Yellow
try {
    Get-LocalUser |
        Sort-Object Name |
        ForEach-Object {
            $status = if ($_.Enabled) { "enabled" } else { "disabled" }
            Write-Host "  $computerName\$($_.Name) [$status]"
        }
} catch {
    Write-Warning "Could not enumerate local users: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Local groups:" -ForegroundColor Yellow
try {
    Get-LocalGroup |
        Sort-Object Name |
        ForEach-Object {
            Write-Host "  $computerName\$($_.Name)"
        }
} catch {
    Write-Warning "Could not enumerate local groups: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Example config snippet:" -ForegroundColor Yellow
Write-Host '  $WatchFolderPrincipals = @('
Write-Host "      `"$currentUser`""
Write-Host "      `"$computerName\ScannerUser`""
Write-Host '  )'
