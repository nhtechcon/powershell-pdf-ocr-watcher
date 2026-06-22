# OCRmyPDF Auto Watcher

Automated PDF OCR processing with file watching, backup management, and scheduled cleanup.

## Overview

This system automatically monitors a folder for new PDF files, adds OCR text layers, and manages backups. Original files are preserved with timestamps, and old backups are automatically cleaned up weekly.
Successfully processed file contents are remembered via a local hash list so unchanged PDFs are skipped across restarts and reboots.

The setup flow is designed for a one-time Administrator run that prepares a dedicated low-privilege runtime account and locks down the working folders automatically.

## Installation

### Prerequisites

- Windows 10/11
- Administrator access for setup and uninstall
- Internet access during setup if Python, OCR dependencies, or language data need to be installed

### Setup

Run the setup script:

```powershell
.\setup.ps1
```

Optional example with explicit folder principals:

```powershell
.\setup.ps1 -WatchFolder "C:\Scans" -WatchFolderPrincipals @("MYPC\Nicolas", "MYPC\ScannerUser")
```

`setup.ps1` is intended to be run once from an elevated Administrator PowerShell session.

This will:

1. Install Python (if missing) via winget
2. Install the `ocrmypdf` Python package
3. Install OCR dependencies such as Ghostscript, Tesseract, unpaper, and pngquant when available
4. Create a dedicated local service account (`.\OCRWatcherSvc` by default)
5. Copy scripts to `C:\watcher-ocr`
6. Generate a machine-specific runtime config under `C:\watcher-ocr`
7. Lock down ACLs on the watch, temp, backup, log, and script paths
8. Register two scheduled tasks
9. Start the watcher immediately

Depending on the machine state, setup may also download:

- a machine-wide Python installer from python.org if winget is unavailable or fails
- Chocolatey packages for OCR dependencies
- the German Tesseract language data file (`deu.traineddata`) if it is missing

## How It Works

1. **Drop PDF** into `C:\Scans`
2. **Watcher detects** the new file
3. **Processing** happens in `C:\watcher-ocr\temp`
4. **Original backed up** to `C:\watcher-ocr\backup\[timestamp]_filename.pdf`
5. **OCR'd version** replaces the original in `C:\Scans` and its ACL is reset so it inherits the watch-folder permissions again
6. **Weekly cleanup** removes backups older than 7 days (Sundays at 3am)

If OCR processing fails after the original file has been moved to backup, the watcher attempts to restore the backup back into the watch folder.

## Repo Structure

```text
setup.ps1                     # Root entrypoint for installation
scripts\
  ocrwatch-config.ps1         # Public source defaults
  ocrwatch-watcher.ps1
  ocrwatch-cleanup.ps1
  ocrwatch-logs.ps1
  ocrwatch-diagnose.ps1
  ocrwatch-list-principals.ps1
  ocrwatch-uninstall.ps1
```

## Installed Layout

```
C:\Scans                       # Watch folder - drop PDFs here

C:\watcher-ocr\
  ├── ocr.log                  # Processing log
  ├── processed.hashes         # One SHA-256 hash per final OCR-written PDF still present in the watch folder
  ├── temp\                    # Temporary processing folder
  ├── backup\                  # Timestamped original files
  ├── ocrwatch-config.ps1      # Shared configuration (edit paths here)
  ├── ocrwatch-watcher.ps1
  ├── ocrwatch-cleanup.ps1
  ├── ocrwatch-logs.ps1
  ├── ocrwatch-diagnose.ps1
  ├── ocrwatch-list-principals.ps1
  └── ocrwatch-uninstall.ps1
```

## Commands

### Watcher Status & Logs

```powershell
# Check if watcher is running
.\scripts\ocrwatch-watcher.ps1 -Status

# View all logs
.\scripts\ocrwatch-watcher.ps1 -Logs

# View last 50 log lines
.\scripts\ocrwatch-watcher.ps1 -Tail 50

# Show help
.\scripts\ocrwatch-watcher.ps1 -Help
```

### Log Viewer

```powershell
# View last 20 lines (default)
.\scripts\ocrwatch-logs.ps1

# View last 100 lines
.\scripts\ocrwatch-logs.ps1 -Tail 100

# View all logs
.\scripts\ocrwatch-logs.ps1 -All

# Follow logs in real-time (Ctrl+C to stop)
.\scripts\ocrwatch-logs.ps1 -Follow

# Diagnose why the task did or didn't start
.\scripts\ocrwatch-diagnose.ps1

# List suggested principals for WatchFolderPrincipals
.\scripts\ocrwatch-list-principals.ps1
```

### Manual Cleanup

```powershell
# Run cleanup manually (removes old backups and rebuilds processed.hashes from current PDFs)
.\scripts\ocrwatch-cleanup.ps1
```

### Task Management

```powershell
# Stop watcher
Stop-ScheduledTask -TaskName "OCRmyPDF Auto Watcher"

# Start watcher
Start-ScheduledTask -TaskName "OCRmyPDF Auto Watcher"

# Run cleanup now
Start-ScheduledTask -TaskName "OCRmyPDF Backup Cleanup"

# View task status
Get-ScheduledTask -TaskName "OCRmyPDF Auto Watcher"
Get-ScheduledTask -TaskName "OCRmyPDF Backup Cleanup"
```

### Uninstall

```powershell
.\scripts\ocrwatch-uninstall.ps1
```

This will:

- Stop and remove both scheduled tasks
- Delete all scripts from `C:\watcher-ocr`
- Optionally delete the base folder
- Optionally delete the log file
- Optionally delete the dedicated local service account

The watch folder is preserved by default and is not deleted by the current uninstall script.

## Scheduled Tasks

### 1. OCRmyPDF Auto Watcher

- **Trigger**: At system startup — **no user login required**
- **Runs as**: dedicated local service account such as `.\OCRWatcherSvc`
- **Action**: Monitors `C:\Scans` for new PDFs
- **Window**: Hidden (no console window)
- **Auto-restart**: Yes (3 attempts, 1-minute intervals)
- **Availability**: Works whether **no one** is logged in or a **normal/non-admin user** is logged in
- **Privilege model**: least-privilege scheduled task, not `SYSTEM`

### 2. OCRmyPDF Backup Cleanup

- **Trigger**: Weekly on Sundays at 3:00 AM
- **Runs as**: the same dedicated local service account
- **Action**: Deletes backups older than 7 days

> **Note on network shares:** The hardened setup assumes local paths for the watch folder, backup folder, temp folder, and log file. If you need to process PDFs from a network location, copy them into the local watch folder first and keep OCR processing isolated to local disk.

## Security / Trust Model

- Setup is an Administrator action that modifies local users, ACLs, and scheduled tasks.
- The watcher itself is intended to run as a dedicated low-privilege local service account rather than `SYSTEM`.
- Setup may install software from upstream sources including winget, python.org, Chocolatey, PyPI, and the Tesseract tessdata repository.
- The generated config in `C:\watcher-ocr\ocrwatch-config.ps1` is machine-specific after setup because it records the resolved Python path and effective watch-folder principals.
- The watcher keeps local operational state in `C:\watcher-ocr\processed.hashes` so unchanged PDFs can be skipped across restarts.

## Troubleshooting

### Watcher not processing files

```powershell
# Check if watcher is running
.\scripts\ocrwatch-watcher.ps1 -Status

# If not running, start it
Start-ScheduledTask -TaskName "OCRmyPDF Auto Watcher"

# Check logs for errors
.\scripts\ocrwatch-logs.ps1 -Tail 50

# Inspect task state and recent Task Scheduler events
.\scripts\ocrwatch-diagnose.ps1
```

If a PDF stays in the watch folder after successful OCR, the watcher records the hash of the final OCR-written file in `C:\watcher-ocr\processed.hashes`.
On the next restart it will skip the unchanged file automatically, even if it was only renamed. If you replace the PDF with different content, it will be processed again.
The cleanup job periodically rebuilds this file from the PDFs still present in the watch folder, so removed files stop occupying dedupe state.

If the diagnostics show `2147943785` or `0x80070569`, Windows denied the task account the required logon type.
Grant the service account `Log on as a batch job` in `Local Security Policy > Local Policies > User Rights Assignment`,
and make sure it is not present in `Deny log on as a batch job`.

### OCR quality issues

Edit OCR settings in `C:\watcher-ocr\ocrwatch-config.ps1`:

```powershell
$Language        = "eng"  # Change language (e.g., "deu" for German)
```

OCRmyPDF arguments are set in `C:\watcher-ocr\ocrwatch-watcher.ps1`:

```powershell
$OcrmypdfArgs    = "--deskew --clean --optimize 3 --output-type pdfa --skip-text"
```

After editing, restart the watcher to pick up changes. See [Configuration](#configuration).

### Log file not found

The log file is created when the watcher first runs. If missing:

```powershell
# Create empty log file
New-Item -Path "C:\watcher-ocr\ocr.log" -ItemType File -Force
```

### Force reprocessing of previously handled files

Delete or clear the processed-hash state file:

```powershell
Clear-Content -Path "C:\watcher-ocr\processed.hashes"
```

After that, unchanged PDFs still sitting in the watch folder become eligible for OCR again.

### Python/ocrmypdf not found

Re-run setup to regenerate the pinned Python path and ACLs:

```powershell
.\setup.ps1
```

The watcher no longer searches arbitrary user profiles for `python.exe`; it uses the exact `PythonExePath` stored in the generated config.

## Configuration

Public source defaults live in this repository's `scripts\ocrwatch-config.ps1`. After setup, the installed machine-specific runtime config lives in **`C:\watcher-ocr\ocrwatch-config.ps1`**:

| Variable             | Default                   | Description              |
| -------------------- | ------------------------- | ------------------------ |
| `$WatchFolder`       | `C:\Scans`         | Watch folder for PDFs    |
| `$TempFolder`        | `C:\watcher-ocr\temp`     | Temporary processing     |
| `$BackupFolder`      | `C:\watcher-ocr\backup`   | Original file backups    |
| `$LogFile`           | `C:\watcher-ocr\ocr.log`  | Processing log           |
| `$ProcessedHashesFile` | `C:\watcher-ocr\processed.hashes` | Final processed-file hashes for PDFs currently still present in the watch folder |
| `$Language`          | `eng+deu`                 | Tesseract OCR languages  |
| `$DaysToKeep`        | `7`                       | Backup retention (days)  |
| `$ServiceAccountName`| `.\OCRWatcherSvc`        | Scheduled-task identity  |
| `$PythonExePath`     | machine-specific         | Pinned Python executable |
| `$WatchFolderPrincipals` | current setup user   | Users allowed to write into the watch folder |

To change any of these, edit `scripts\ocrwatch-config.ps1` in this project, then re-run setup so the installed copy under `C:\watcher-ocr` is regenerated:

```powershell
.\setup.ps1
```

If you change `$WatchFolderPrincipals`, re-run `setup.ps1` as Administrator so the installed config and watch-folder ACLs are updated to match the new list.

Example:

```powershell
$WatchFolderPrincipals = @(
    "MYPC\Nicolas",
    "MYPC\ScannerUser",
    "CONTOSO\BackofficeUser"
)
```

OCRmyPDF arguments are set in `C:\watcher-ocr\ocrwatch-watcher.ps1` (`$OcrmypdfArgs`).

## Advanced Usage

### Manual watcher start (foreground)

For testing/debugging:

```powershell
cd C:\watcher-ocr
.\ocrwatch-watcher.ps1
```

Press Ctrl+C to stop.

## Files Reference

| File                       | Purpose                             |
| -------------------------- | ----------------------------------- |
| `setup.ps1`                | One-time installation script        |
| `scripts/ocrwatch-config.ps1`      | Shared source configuration template |
| `scripts/ocrwatch-watcher.ps1`     | Main file watcher and OCR processor |
| `scripts/ocrwatch-cleanup.ps1`     | Backup cleanup script (runs weekly) |
| `scripts/ocrwatch-logs.ps1`        | Log viewer utility                  |
| `scripts/ocrwatch-list-principals.ps1` | Lists suggested local principals |
| `scripts/ocrwatch-uninstall.ps1`   | Complete removal script             |

## Known Limitations

- Windows-only; this is built around PowerShell, Task Scheduler, Windows ACLs, and local service accounts.
- Optimized for local disk paths rather than direct OCR from network shares.
- Requires Administrator rights for setup and uninstall.
- No automated tests are included at the moment; validation is currently manual and operational.

## Support

For issues with:

- **Python/ocrmypdf**: Check ocrmypdf documentation
- **Scheduled tasks**: Run PowerShell as Administrator
- **File permissions**: Re-run `setup.ps1` as Administrator after changing folder paths so ACLs are reapplied for the service account

## License

This repository is released under the MIT License. See [LICENSE](LICENSE).

It also depends on upstream software with their own licenses:

- **ocrmypdf**: MPL-2.0 License
- **Python**: PSF License
