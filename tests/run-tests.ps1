# Lightweight test runner that avoids external dependencies.
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CommonModule = Join-Path $RepoRoot "scripts/OcrWatch.Common.psm1"
Import-Module $CommonModule -Force

$script:Passed = 0
$script:Failed = 0

function Test-Case {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [string]$Message)
    if ($Actual -notmatch $Pattern) {
        throw "$Message Value '$Actual' did not match '$Pattern'."
    }
}

Test-Case "PowerShell files parse cleanly" {
    $files = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.ps1", "*.psm1" |
        Where-Object { $_.FullName -notmatch '\\.git\\' }
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-Equal $errors.Count 0 "Parse errors in $($file.FullName)."
    }
}

Test-Case "Public config has no machine-specific watch principals" {
    $configPath = Join-Path $RepoRoot "scripts/ocrwatch-config.ps1"
    $config = & {
        . $configPath
        [pscustomobject]@{
            BaseDir               = $BaseDir
            WatchFolder           = $WatchFolder
            WatchFolderPrincipals = @($WatchFolderPrincipals)
        }
    }

    Assert-Equal $config.BaseDir "C:\watcher-ocr" "Unexpected BaseDir default."
    Assert-Equal $config.WatchFolder "C:\Scans" "Unexpected WatchFolder default."
    Assert-Equal $config.WatchFolderPrincipals.Count 0 "Public config should not contain real principals."
}

Test-Case "Installer and uninstaller reference the shared module" {
    $setup = Get-Content -Path (Join-Path $RepoRoot "setup.ps1") -Raw
    $uninstall = Get-Content -Path (Join-Path $RepoRoot "scripts/ocrwatch-uninstall.ps1") -Raw

    Assert-Match $setup 'Import-Module.*OcrWatch\.Common\.psm1' "Setup should import the shared module."
    Assert-Match $uninstall 'OcrWatch\.Common\.psm1' "Uninstall should reference the shared module."
}

Test-Case "Strong password includes all required character classes" {
    $password = New-StrongPassword -Length 32

    Assert-Equal $password.Length 32 "Password length mismatch."
    Assert-Match $password "[A-Z]" "Password should include uppercase letters."
    Assert-Match $password "[a-z]" "Password should include lowercase letters."
    Assert-Match $password "[0-9]" "Password should include digits."
    Assert-Match $password "[!@#`$%\^\*\-_+]" "Password should include special characters."
}

Test-Case "Machine Python path validation rejects empty and profile paths" {
    Assert-True (!(Test-MachinePythonPath -Path "" -SystemDrive $env:SystemDrive)) "Empty path should be rejected."
    Assert-True (!(Test-MachinePythonPath -Path "C:\Users\Nicolas\AppData\Python\python.exe" -SystemDrive $env:SystemDrive)) "User-profile Python path should be rejected."
}

Test-Case "Machine Python path validation accepts an existing non-profile path" {
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("ocrwatch-tests-" + [guid]::NewGuid().ToString("N"))
    New-Item -Path $tmpDir -ItemType Directory -Force | Out-Null
    try {
        $fakePython = Join-Path $tmpDir "python.exe"
        Set-Content -Path $fakePython -Value "fake" -Encoding ASCII

        Assert-True (Test-MachinePythonPath -Path $fakePython -SystemDrive $env:SystemDrive) "Existing non-profile path should be accepted."
        Assert-Equal (Assert-MachinePythonPath -PathValue " $fakePython " -SystemDrive $env:SystemDrive) $fakePython "Assert should trim and return the resolved path."
    } finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case "File content hash is uppercase SHA-256" {
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) ("ocrwatch-hash-" + [guid]::NewGuid().ToString("N") + ".txt")
    try {
        Set-Content -Path $tmpFile -Value "hello" -NoNewline -Encoding ASCII
        $hash = Get-FileContentHash -Path $tmpFile

        Assert-Equal $hash "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824" "SHA-256 mismatch."
    } finally {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

Test-Case "Processed hash state normalizes and deduplicates entries" {
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) ("ocrwatch-processed-" + [guid]::NewGuid().ToString("N") + ".hashes")
    try {
        Set-Content -Path $tmpFile -Value @(" abc123 ", "", "ABC123") -Encoding ASCII
        $set = New-ProcessedHashSet
        Import-ProcessedHashes -Path $tmpFile -HashSet $set

        Assert-Equal $set.Count 1 "Import should deduplicate hashes case-insensitively."
        Assert-True ($set.Contains("ABC123")) "Hash should be normalized to uppercase."
        Assert-True (!(Add-ProcessedHash -Path $tmpFile -Hash "abc123" -HashSet $set)) "Duplicate hash should not be persisted."
        Assert-True (Add-ProcessedHash -Path $tmpFile -Hash "def456" -HashSet $set) "New hash should be persisted."
        Assert-True ($set.Contains("DEF456")) "New hash should be normalized."
    } finally {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

Test-Case "Task Scheduler result messages decode known and unknown codes" {
    Assert-Equal (Resolve-TaskSchedulerResultMessage -Code 267011) "0x41303 SCHED_S_TASK_HAS_NOT_RUN: the task has not run yet." "Unexpected not-run message."
    Assert-Equal (Resolve-TaskSchedulerResultMessage -Code 2147943785) "0x80070569 ERROR_LOGON_TYPE_NOT_GRANTED: the account lacks the requested logon type on this computer." "Unexpected logon-type message."
    Assert-Equal (Resolve-TaskSchedulerResultMessage -Code 1) "0x00000001" "Unexpected fallback message."
}

Write-Host ""
Write-Host "Tests passed: $script:Passed"
Write-Host "Tests failed: $script:Failed"

if ($script:Failed -gt 0) {
    exit 1
}
