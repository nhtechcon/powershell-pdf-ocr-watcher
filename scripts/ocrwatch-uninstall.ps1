# =============================================================================
# ocrwatch-uninstall.ps1
#   Removes the OCR watcher setup created by setup.ps1
#   - Deletes the scheduled task
#   - Removes watcher & status scripts
#   - Optionally removes base folder and/or watch/processed folders
#   Run as Administrator
#   Date: March 2026
# =============================================================================

Write-Host "=== OCR Watcher Uninstaller ===" -ForegroundColor Cyan
Write-Host "This will remove the scheduled task and files created by the setup script." -ForegroundColor Yellow
Write-Host "Python and ocrmypdf will NOT be uninstalled automatically." -ForegroundColor Yellow
Write-Host "The dedicated service account can also be removed at the end." -ForegroundColor Yellow
Write-Host ""

# Load shared configuration
$ConfigPath = Join-Path $PSScriptRoot "ocrwatch-config.ps1"
if (!(Test-Path $ConfigPath)) { Write-Host "Config not found: $ConfigPath" -ForegroundColor Red; exit 1 }
. $ConfigPath

function Resolve-IdentityReference {
    param([string]$Principal)

    if ([string]::IsNullOrWhiteSpace($Principal)) {
        throw "Identity resolution failed: principal is empty."
    }

    if ($Principal -match '^S-\d(-\d+)+$') {
        return New-Object System.Security.Principal.SecurityIdentifier($Principal)
    }

    return (New-Object System.Security.Principal.NTAccount($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
}

function Assert-ResolvableIdentity {
    param([string]$Principal)

    $sid = Resolve-IdentityReference $Principal
    if (!$sid) {
        throw "Identity resolution failed for principal: $Principal"
    }
    return $sid.Value
}

function Get-UserRightsAssignments {
    $exportPath = Join-Path $env:TEMP "ocrwatch-uninstall-secpol.inf"

    try {
        secedit /export /cfg $exportPath /areas USER_RIGHTS /quiet | Out-Null
        if (!(Test-Path $exportPath)) {
            throw "secedit did not produce an export file."
        }

        $assignments = @{}
        foreach ($line in Get-Content $exportPath -ErrorAction Stop) {
            if ($line -match '^(Se\w+)\s*=\s*(.*)$') {
                $name = $matches[1]
                $values = @()
                if ($matches[2].Trim()) {
                    $values = $matches[2].Split(',') |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { $_ }
                }
                $assignments[$name] = $values
            }
        }

        return $assignments
    } finally {
        Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-AccountFromUserRight {
    param(
        [string]$Principal,
        [string]$RightName
    )

    $sidValue = Assert-ResolvableIdentity $Principal
    $assignments = Get-UserRightsAssignments
    $currentValues = @($assignments[$RightName])
    $filteredValues = @(
        $currentValues | Where-Object { $_.TrimStart('*') -ne $sidValue }
    )

    if ($filteredValues.Count -eq $currentValues.Count) {
        return $false
    }

    $configPath = Join-Path $env:TEMP "ocrwatch-uninstall-rights.inf"
    $dbPath = Join-Path $env:TEMP "ocrwatch-uninstall-rights.sdb"
    $lineValue = $filteredValues -join ','
    $inf = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
$RightName = $lineValue
"@

    try {
        Set-Content -Path $configPath -Value $inf -Encoding Unicode
        secedit /configure /db $dbPath /cfg $configPath /areas USER_RIGHTS | Out-Null
        gpupdate /target:computer /force | Out-Null
        Start-Sleep -Seconds 2
    } finally {
        Remove-Item $configPath -Force -ErrorAction SilentlyContinue
        Remove-Item $dbPath -Force -ErrorAction SilentlyContinue
        Remove-Item "$dbPath.jfm" -Force -ErrorAction SilentlyContinue
    }

    return $true
}

# Confirm
$confirm = Read-Host "Are you sure you want to uninstall? (type YES to continue)"
if ($confirm -ne "YES") {
    Write-Host "Uninstall cancelled." -ForegroundColor Green
    exit 0
}

# Step 1: Stop and delete Scheduled Tasks
Write-Host "`nStep 1: Removing Scheduled Tasks..." -ForegroundColor Cyan

# Remove watcher task
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed: $TaskName" -ForegroundColor Green
} catch {
    Write-Warning "Could not remove '$TaskName': $($_.Exception.Message)"
}

# Remove cleanup task
try {
    Stop-ScheduledTask -TaskName $CleanupTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $CleanupTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed: $CleanupTaskName" -ForegroundColor Green
} catch {
    Write-Warning "Could not remove '$CleanupTaskName': $($_.Exception.Message)"
}

# Step 2: Delete scripts
Write-Host "`nStep 2: Deleting script files..." -ForegroundColor Cyan

$filesToDelete = @(
    (Join-Path $BaseDir "ocrwatch-watcher.ps1"),
    (Join-Path $BaseDir "ocrwatch-cleanup.ps1"),
    (Join-Path $BaseDir "ocrwatch-logs.ps1"),
    (Join-Path $BaseDir "ocrwatch-diagnose.ps1"),
    (Join-Path $BaseDir "ocrwatch-uninstall.ps1"),
    (Join-Path $BaseDir "ocrwatch-list-principals.ps1"),
    (Join-Path $BaseDir "ocrwatch-config.ps1")
)

foreach ($file in $filesToDelete) {
    if (Test-Path $file) {
        Remove-Item $file -Force
        Write-Host "Deleted: $file" -ForegroundColor Green
    } else {
        Write-Host "Not found (already deleted?): $file" -ForegroundColor Gray
    }
}

# Step 3: Optional - remove base directory
$removeBase = Read-Host "`nDelete the entire base folder $BaseDir ? (YES/NO)"
if ($removeBase -eq "YES") {
    if (Test-Path $BaseDir) {
        Remove-Item $BaseDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Deleted base folder: $BaseDir" -ForegroundColor Green
    } else {
        Write-Host "Base folder not found." -ForegroundColor Gray
    }
}

# Step 4: Optional - remove log file only (watch folder is preserved)
$removeLog = Read-Host "`nDelete log file ($LogFile)? (YES/NO)"
if ($removeLog -eq "YES") {
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
        Write-Host "Deleted log: $LogFile" -ForegroundColor Green
    } else {
        Write-Host "Log file not found." -ForegroundColor Gray
    }
}

Write-Host "`nNote: Watch folder ($WatchFolder) is preserved and not deleted." -ForegroundColor Yellow

$removeServiceAccount = Read-Host "`nDelete the local service account ($ServiceAccountName)? (YES/NO)"
if ($removeServiceAccount -eq "YES") {
    try {
        $localAccountName = $ServiceAccountName -replace '^\.\\', ''
        $qualifiedAccountName = "$env:COMPUTERNAME\$localAccountName"
        $serviceUser = Get-LocalUser -Name $localAccountName -ErrorAction SilentlyContinue
        if ($serviceUser) {
            $removedBatchRight = Remove-AccountFromUserRight -Principal $qualifiedAccountName -RightName "SeBatchLogonRight"
            if ($removedBatchRight) {
                Write-Host "Removed '$qualifiedAccountName' from 'Log on as a batch job'." -ForegroundColor Green
            } else {
                Write-Host "Service account was not present in 'Log on as a batch job'." -ForegroundColor Gray
            }

            Remove-LocalUser -Name $localAccountName
            Write-Host "Deleted service account: $ServiceAccountName" -ForegroundColor Green
        } else {
            Write-Host "Service account not found." -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Could not delete service account '$ServiceAccountName': $($_.Exception.Message)"
    }
}

Write-Host "`n=== Uninstall finished ===" -ForegroundColor Cyan
Write-Host "What remains:"
Write-Host "  • Python (if installed via winget/Microsoft Store)"
Write-Host "  • ocrmypdf package (uninstall manually if desired: py -m pip uninstall ocrmypdf)"
Write-Host "  • Tesseract & Ghostscript (if you installed them separately)"
Write-Host ""
Write-Host "To fully clean up Python packages (optional):"
Write-Host "  py -m pip uninstall ocrmypdf"
Write-Host "  py -m pip list   # to check what's left"
Write-Host ""
Write-Host "Done. You can now safely delete this uninstall script."
