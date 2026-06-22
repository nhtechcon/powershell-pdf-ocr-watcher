# ocrwatch-cleanup.ps1
# Cleans up backup files older than 7 days

# Load shared configuration
$ConfigPath = Join-Path $PSScriptRoot "ocrwatch-config.ps1"
if (!(Test-Path $ConfigPath)) { Write-Host "Config not found: $ConfigPath" -ForegroundColor Red; exit 1 }
. $ConfigPath

Import-Module (Join-Path $PSScriptRoot "OcrWatch.Common.psm1") -Force

function Rebuild-ProcessedHashesFile {
    $hashSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $hashFailures = 0

    if (!(Test-Path $WatchFolder)) {
        Write-Log -Path $LogFile -Message "Watch folder not found while rebuilding processed hashes: $WatchFolder" -Level "WARN"
        Set-Content -Path $ProcessedHashesFile -Value @() -Encoding ASCII
        return
    }

    $pdfFiles = Get-ChildItem -Path $WatchFolder -Filter "*.pdf" -File -ErrorAction SilentlyContinue
    foreach ($file in $pdfFiles) {
        try {
            $hash = Get-FileContentHash -Path $file.FullName
            $null = $hashSet.Add($hash)
        } catch {
            $hashFailures++
            Write-Log -Path $LogFile -Message "Failed to hash $($file.FullName) during processed-hash rebuild: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    $hashSet | Set-Content -Path $ProcessedHashesFile -Encoding ASCII
    Write-Log -Path $LogFile -Message "Rebuilt processed hash state with $($hashSet.Count) hash(es) from $($pdfFiles.Count) current PDF file(s)" -Level "CLEANUP"

    if ($hashFailures -gt 0) {
        Write-Log -Path $LogFile -Message "Processed-hash rebuild completed with $hashFailures hash failure(s)" -Level "WARN"
    }
}

Write-Log -Path $LogFile -Message "Cleanup started - removing backups older than $DaysToKeep days" -Level "CLEANUP"

if (!(Test-Path $BackupFolder)) {
    Write-Log -Path $LogFile -Message "Backup folder not found: $BackupFolder" -Level "WARN"
    Rebuild-ProcessedHashesFile
    exit 0
}

$cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
$oldFiles = Get-ChildItem -Path $BackupFolder -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }

if ($oldFiles.Count -eq 0) {
    Write-Log -Path $LogFile -Message "No old backup files to clean up" -Level "CLEANUP"
} else {
    $totalSize = ($oldFiles | Measure-Object -Property Length -Sum).Sum
    $sizeMB = [math]::Round($totalSize / 1MB, 2)
    
    Write-Log -Path $LogFile -Message "Found $($oldFiles.Count) files to delete (${sizeMB}MB total)" -Level "CLEANUP"
    
    foreach ($file in $oldFiles) {
        try {
            Remove-Item $file.FullName -Force
            Write-Log -Path $LogFile -Message "Deleted: $($file.Name) ($(Get-Date $file.LastWriteTime -Format 'yyyy-MM-dd'))" -Level "CLEANUP"
        } catch {
            Write-Log -Path $LogFile -Message "Failed to delete $($file.Name): $($_.Exception.Message)" -Level "ERROR"
        }
    }
    
    Write-Log -Path $LogFile -Message "Cleanup completed - freed ${sizeMB}MB" -Level "CLEANUP"
}

Rebuild-ProcessedHashesFile
