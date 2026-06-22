# ocrwatch-watcher.ps1
param(
    [switch]$Logs,
    [switch]$Status,
    [switch]$Help,
    [int]$Tail = 0
)

# Load shared configuration
$ConfigPath = Join-Path $PSScriptRoot "ocrwatch-config.ps1"
if (!(Test-Path $ConfigPath)) { Write-Host "Config not found: $ConfigPath" -ForegroundColor Red; exit 1 }
. $ConfigPath

$OcrmypdfArgs = "--deskew --clean --optimize 3 --output-type pdfa --skip-text"
$PythonExe = $PythonExePath

# Create temp and backup folders if they don't exist
foreach ($dir in @($TempFolder, $BackupFolder)) {
    if (!(Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}

if (!(Test-Path $ProcessedHashesFile)) {
    New-Item -Path $ProcessedHashesFile -ItemType File -Force | Out-Null
}

# Handle command-line arguments
if ($Help) {
    Write-Host "OCRmyPDF Auto Watcher - Command Line Options" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  ocrwatch-watcher.ps1              Start the watcher (default)"
    Write-Host "  ocrwatch-watcher.ps1 -Logs        View full log file"
    Write-Host "  ocrwatch-watcher.ps1 -Tail N      View last N lines of log"
    Write-Host "  ocrwatch-watcher.ps1 -Status      Check if watcher is running"
    Write-Host "  ocrwatch-watcher.ps1 -Help        Show this help"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  ocrwatch-watcher.ps1 -Logs        # View all logs"
    Write-Host "  ocrwatch-watcher.ps1 -Tail 50     # View last 50 log lines"
    Write-Host "  ocrwatch-watcher.ps1 -Status      # Check watcher status"
    Write-Host ""
    Write-Host "Folders:"
    Write-Host "  Config:  $ConfigPath"
    Write-Host "  Watch:   $WatchFolder"
    Write-Host "  Temp:    $TempFolder"
    Write-Host "  Backup:  $BackupFolder"
    Write-Host "  Log:     $LogFile"
    Write-Host "  Hashes:  $ProcessedHashesFile"
    Write-Host "  Python:  $PythonExe"
    exit 0
}

if ($Logs) {
    if (Test-Path $LogFile) {
        Get-Content $LogFile
    } else {
        Write-Host "Log file not found: $LogFile" -ForegroundColor Yellow
    }
    exit 0
}

if ($Tail -gt 0) {
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail $Tail
    } else {
        Write-Host "Log file not found: $LogFile" -ForegroundColor Yellow
    }
    exit 0
}

if ($Status) {
    Write-Host "=== OCR Watcher Status ===" -ForegroundColor Cyan
    $proc = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like "*ocrwatch-watcher.ps1*" -and $_.CommandLine -notlike "*-Status*" }

    if ($proc) {
        Write-Host "Watcher is RUNNING" -ForegroundColor Green
        Write-Host "  PID(s): $($proc.ProcessId -join ', ')"
        Write-Host "  Started: $($proc.CreationDate | Select-Object -First 1)"
    } else {
        Write-Host "Watcher is NOT running" -ForegroundColor Yellow
    }

    if (Test-Path $LogFile) {
        $lastLines = Get-Content $LogFile -Tail 5
        Write-Host "`nLast 5 log entries:" -ForegroundColor Cyan
        $lastLines | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "=========================="
    exit 0
}

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

function Load-ProcessedHashSet {
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$HashSet
    )

    if (!(Test-Path $ProcessedHashesFile)) {
        return
    }

    try {
        foreach ($line in Get-Content -Path $ProcessedHashesFile -ErrorAction Stop) {
            $normalized = $line.Trim().ToUpperInvariant()
            if ($normalized) {
                $null = $HashSet.Add($normalized)
            }
        }
    } catch {
        Write-Log "Failed to load processed hash state from ${ProcessedHashesFile}: $($_.Exception.Message)" "ERROR"
    }
}

function Save-ProcessedHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hash,
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$HashSet
    )

    $normalized = $Hash.Trim().ToUpperInvariant()
    if (!$normalized) {
        throw "Cannot persist an empty hash."
    }

    if ($HashSet.Contains($normalized)) {
        return $false
    }

    Add-Content -Path $ProcessedHashesFile -Value $normalized -ErrorAction Stop
    $null = $HashSet.Add($normalized)
    return $true
}

function Reset-FilePermissionsFromParent {
    param([string]$Path)

    if (!(Test-Path $Path)) {
        throw "File not found for ACL reset: $Path"
    }

    # Reset the file ACL so it inherits the watch-folder permissions instead of
    # keeping the explicit ACL it had while living in the temp folder.
    $null = & icacls.exe $Path /reset 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "icacls reset failed for $Path with exit code $LASTEXITCODE"
    }
}

function Invoke-OcrMyPdf {
    param(
        [string]$InputFile,
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$ProcessedHashSet
    )
    if (!(Test-Path $InputFile)) { return $false }

    if (!$PythonExe -or !(Test-Path $PythonExe)) {
        Write-Log "Pinned Python executable not found at '$PythonExe' - cannot process files" "ERROR"
        return $false
    }

    $fileName = [IO.Path]::GetFileName($InputFile)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    # Copy file to temp first so users cannot mutate the OCR input mid-run.
    $tempInput = Join-Path $TempFolder "$timestamp`_input_$fileName"
    $tempOutput = Join-Path $TempFolder "$timestamp`_output_$fileName"

    Write-Log "Processing $InputFile"
    try {
        Copy-Item -Path $InputFile -Destination $tempInput -Force
        Write-Log "Copied to temp for processing"

        $backupPath = Join-Path $BackupFolder "$timestamp`_$fileName"
        Move-Item -Path $InputFile -Destination $backupPath -Force
        Write-Log "Backed up original to: $backupPath"

        $args = @("-m", "ocrmypdf", $tempInput, $tempOutput, "-l", $Language) + $OcrmypdfArgs.Split()
        & $PythonExe @args 2>&1 | ForEach-Object { Write-Log "  $_" "DEBUG" }

        if (Test-Path $tempOutput) {
            Move-Item -Path $tempOutput -Destination $InputFile -Force
            Reset-FilePermissionsFromParent -Path $InputFile
            try {
                $finalOutputHash = Get-FileContentHash -Path $InputFile
                $persisted = Save-ProcessedHash -Hash $finalOutputHash -HashSet $ProcessedHashSet
                if ($persisted) {
                    Write-Log "Recorded processed hash for $InputFile" "DEBUG"
                }
            } catch {
                Write-Log "Failed to persist processed hash for ${InputFile}: $($_.Exception.Message)" "ERROR"
            }
            Write-Log "Success: OCR'd file placed at $InputFile with watch-folder ACLs restored" "SUCCESS"
            return $true
        }

        Write-Log "No output file created - restoring backup" "ERROR"
        Copy-Item -Path $backupPath -Destination $InputFile -Force
        Write-Log "Restored backup to $InputFile" "INFO"
        return $false
    } catch {
        Write-Log "Error: $($_.Exception.Message)" "ERROR"
        $restored = $false
        if (Test-Path $backupPath) {
            Copy-Item -Path $backupPath -Destination $InputFile -Force
            $restored = $true
        }
        if ($restored) { Write-Log "Restored backup to $InputFile" "INFO" }
        else { Write-Log "Backup not found at $backupPath - file lost!" "CRITICAL" }
        return $false
    } finally {
        if (Test-Path $tempInput) { Remove-Item $tempInput -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue }
    }
}

if ($PythonExe -and (Test-Path $PythonExe)) {
    Write-Log "Python pinned at: $PythonExe"
} else {
    Write-Log "WARNING: Pinned Python executable missing - OCR processing will fail" "WARN"
}

Write-Log "Watcher started - monitoring $WatchFolder\*.pdf" "START"

$processedFiles = @{}
$retryCount = @{}
$MaxRetries = 3
$processedHashSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
Load-ProcessedHashSet -HashSet $processedHashSet
Write-Log "Loaded $($processedHashSet.Count) processed file hash(es) from $ProcessedHashesFile" "INFO"

try {
    while ($true) {
        $pdfFiles = Get-ChildItem -Path $WatchFolder -Filter "*.pdf" -File -ErrorAction SilentlyContinue

        foreach ($file in $pdfFiles) {
            try {
                if ($processedFiles.ContainsKey($file.FullName)) { continue }

                Start-Sleep -Milliseconds 500

                $size1 = $file.Length
                Start-Sleep -Milliseconds 500
                try {
                    $file.Refresh()
                    $size2 = $file.Length
                    if ($size1 -ne $size2) { continue }
                } catch {
                    continue
                }

                $inputHash = $null
                try {
                    $inputHash = Get-FileContentHash -Path $file.FullName
                } catch {
                    Write-Log "Failed to compute hash for $($file.FullName): $($_.Exception.Message)" "ERROR"
                    if (!$retryCount.ContainsKey($file.FullName)) { $retryCount[$file.FullName] = 0 }
                    $retryCount[$file.FullName]++
                    if ($retryCount[$file.FullName] -ge $MaxRetries) {
                        Write-Log "Max retries ($MaxRetries) for $($file.Name) after hash failures - abandoning (file left in place)" "ERROR"
                        $processedFiles[$file.FullName] = $true
                    }
                    continue
                }

                if ($processedHashSet.Contains($inputHash)) {
                    Write-Log "Skipping $($file.FullName) - content hash already processed" "INFO"
                    $processedFiles[$file.FullName] = $true
                    continue
                }

                $success = Invoke-OcrMyPdf -InputFile $file.FullName -ProcessedHashSet $processedHashSet

                if ($success) {
                    $processedFiles[$file.FullName] = $true
                } else {
                    if (!$retryCount.ContainsKey($file.FullName)) { $retryCount[$file.FullName] = 0 }
                    $retryCount[$file.FullName]++
                    if ($retryCount[$file.FullName] -ge $MaxRetries) {
                        Write-Log "Max retries ($MaxRetries) for $($file.Name) - abandoning (file left in place)" "ERROR"
                        $processedFiles[$file.FullName] = $true
                    }
                }
            } catch {
                $scriptLine = $_.InvocationInfo.ScriptLineNumber
                $lineText = $_.InvocationInfo.Line.Trim()
                Write-Log "Unhandled error while evaluating $($file.FullName) at line ${scriptLine}: $($_.Exception.Message)" "ERROR"
                if ($lineText) {
                    Write-Log "  Failing statement: $lineText" "DEBUG"
                }
                if ($_.ScriptStackTrace) {
                    Write-Log "  Stack: $($_.ScriptStackTrace)" "DEBUG"
                }
            }
        }

        $existingFiles = $pdfFiles | ForEach-Object { $_.FullName }
        $toRemove = $processedFiles.Keys | Where-Object { $_ -notin $existingFiles }
        foreach ($key in $toRemove) {
            $processedFiles.Remove($key)
            $retryCount.Remove($key)
        }

        Start-Sleep -Seconds 5
    }
} catch {
    $scriptLine = $_.InvocationInfo.ScriptLineNumber
    $lineText = $_.InvocationInfo.Line.Trim()
    Write-Log "Watcher crashed at line ${scriptLine}: $($_.Exception.Message)" "CRITICAL"
    if ($lineText) {
        Write-Log "  Failing statement: $lineText" "DEBUG"
    }
    if ($_.ScriptStackTrace) {
        Write-Log "  Stack: $($_.ScriptStackTrace)" "DEBUG"
    }
    throw
}
finally {
    Write-Log "Watcher stopped" "STOP"
}
