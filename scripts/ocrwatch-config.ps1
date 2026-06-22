# ocrwatch-config.ps1
# Shared configuration - edit paths here instead of in each script

$BaseDir       = "C:\watcher-ocr"
$WatchFolder   = "C:\Scans"
$TempFolder    = "$BaseDir\temp"
$BackupFolder  = "$BaseDir\backup"
$LogFile       = "$BaseDir\ocr.log"
$ProcessedHashesFile = "$BaseDir\processed.hashes"
$Language      = "eng+deu"
$DaysToKeep    = 7

# Scheduled task names
$TaskName        = "OCRmyPDF Auto Watcher"
$CleanupTaskName = "OCRmyPDF Backup Cleanup"
$ServiceAccountName = ".\OCRWatcherSvc"
$PythonExePath      = "C:\Program Files\Python313\python.exe"
# setup.ps1 rewrites this in the generated runtime config under $BaseDir.
# Add any local or domain users that should be able to drop PDFs into $WatchFolder.
# Re-run setup.ps1 as Administrator after changing this list so ACLs are reapplied.
$WatchFolderPrincipals = @()
