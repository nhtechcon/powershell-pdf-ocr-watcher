# ocrwatch-cleanup.ps1
# Cleans up backup files older than 7 days

# Load shared configuration
$ConfigPath = Join-Path $PSScriptRoot "ocrwatch-config.ps1"
if (!(Test-Path $ConfigPath)) { Write-Host "Config not found: $ConfigPath" -ForegroundColor Red; exit 1 }
. $ConfigPath

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [$Level] $Message" | Tee-Object -FilePath $LogFile -Append | Write-Host
}

function Get-FileContentHash {
    param([string]$Path)

    if (!(Test-Path $Path)) {
        throw "File not found: $Path"
    }

    return (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Rebuild-ProcessedHashesFile {
    $hashSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $hashFailures = 0

    if (!(Test-Path $WatchFolder)) {
        Write-Log "Watch folder not found while rebuilding processed hashes: $WatchFolder" "WARN"
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
            Write-Log "Failed to hash $($file.FullName) during processed-hash rebuild: $($_.Exception.Message)" "ERROR"
        }
    }

    Set-Content -Path $ProcessedHashesFile -Value @($hashSet) -Encoding ASCII
    Write-Log "Rebuilt processed hash state with $($hashSet.Count) hash(es) from $($pdfFiles.Count) current PDF file(s)" "CLEANUP"

    if ($hashFailures -gt 0) {
        Write-Log "Processed-hash rebuild completed with $hashFailures hash failure(s)" "WARN"
    }
}

Write-Log "Cleanup started - removing backups older than $DaysToKeep days" "CLEANUP"

if (!(Test-Path $BackupFolder)) {
    Write-Log "Backup folder not found: $BackupFolder" "WARN"
    Rebuild-ProcessedHashesFile
    exit 0
}

$cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
$oldFiles = Get-ChildItem -Path $BackupFolder -File | Where-Object { $_.LastWriteTime -lt $cutoffDate }

if ($oldFiles.Count -eq 0) {
    Write-Log "No old backup files to clean up" "CLEANUP"
} else {
    $totalSize = ($oldFiles | Measure-Object -Property Length -Sum).Sum
    $sizeMB = [math]::Round($totalSize / 1MB, 2)
    
    Write-Log "Found $($oldFiles.Count) files to delete (${sizeMB}MB total)" "CLEANUP"
    
    foreach ($file in $oldFiles) {
        try {
            Remove-Item $file.FullName -Force
            Write-Log "Deleted: $($file.Name) ($(Get-Date $file.LastWriteTime -Format 'yyyy-MM-dd'))" "CLEANUP"
        } catch {
            Write-Log "Failed to delete $($file.Name): $($_.Exception.Message)" "ERROR"
        }
    }
    
    Write-Log "Cleanup completed - freed ${sizeMB}MB" "CLEANUP"
}

Rebuild-ProcessedHashesFile
