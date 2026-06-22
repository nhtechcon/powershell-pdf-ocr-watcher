# =============================================================================
# setup.ps1
#   One-time setup - hardened June 2026
#   - Installs machine-wide Python if needed
#   - Installs ocrmypdf and OCR dependencies
#   - Creates a dedicated low-privilege service account
#   - Locks down ACLs for scripts, logs, temp, backup, and watch folders
#   - Registers scheduled tasks under the service account
# =============================================================================

param(
    [string]$BaseDir = "C:\watcher-ocr",
    [string]$WatchFolder = "C:\Scans",
    [string]$ServiceAccountName = "OCRWatcherSvc",
    [string[]]$WatchFolderPrincipals = @()
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-ProgressInfo {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor DarkCyan
}

function Write-ProgressDone {
    param([string]$Message)
    Write-Host "  OK $Message" -ForegroundColor Green
}

function Get-ExistingSetupConfig {
    param([string]$ConfigPath)

    if (!(Test-Path $ConfigPath)) {
        return $null
    }

    $configData = & {
        . $ConfigPath
        [pscustomobject]@{
            BaseDir               = $BaseDir
            WatchFolder           = $WatchFolder
            TempFolder            = $TempFolder
            BackupFolder          = $BackupFolder
            LogFile               = $LogFile
            ProcessedHashesFile   = $ProcessedHashesFile
            Language              = $Language
            DaysToKeep            = $DaysToKeep
            TaskName              = $TaskName
            CleanupTaskName       = $CleanupTaskName
            ServiceAccountName    = $ServiceAccountName
            PythonExePath         = $PythonExePath
            WatchFolderPrincipals = @($WatchFolderPrincipals)
        }
    }

    return $configData
}

function New-StrongPassword {
    param([int]$Length = 28)

    $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ".ToCharArray()
    $lower = "abcdefghijkmnopqrstuvwxyz".ToCharArray()
    $digits = "23456789".ToCharArray()
    $special = "!@#$%^*-_+".ToCharArray()
    $all = $upper + $lower + $digits + $special

    $chars = @(
        (Get-Random -InputObject $upper),
        (Get-Random -InputObject $lower),
        (Get-Random -InputObject $digits),
        (Get-Random -InputObject $special)
    )

    while ($chars.Count -lt $Length) {
        $chars += Get-Random -InputObject $all
    }

    -join ($chars | Sort-Object { Get-Random })
}

function Resolve-PythonExe {
    $commonRoots = @(
        "$env:ProgramFiles\Python",
        "$env:ProgramFiles\Python313",
        "$env:ProgramFiles\Python312",
        "$env:LOCALAPPDATA\Programs\Python"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $commonRoots) {
        $found = Get-ChildItem -Path $root -Filter "python.exe" -Recurse -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    foreach ($commandName in @("py", "python")) {
        if (Get-Command $commandName -ErrorAction SilentlyContinue) {
            try {
                $resolved = (& $commandName -c "import sys; print(sys.executable)" 2>$null).Trim()
                if ($resolved -and (Test-Path $resolved)) {
                    return $resolved
                }
            } catch { }
        }
    }

    return $null
}

function Test-MachinePythonPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.Contains("`r") -or $Path.Contains("`n")) { return $false }
    if (!(Test-Path $Path)) { return $false }
    if ($Path -like "$env:SystemDrive\Users\*") { return $false }
    return $true
}

function Assert-MachinePythonPath {
    param([object]$PathValue)

    if ($PathValue -isnot [string]) {
        throw "Python resolution failed: expected a single string path, got $($PathValue.GetType().FullName)."
    }

    $resolvedPath = $PathValue.Trim()
    if ($resolvedPath.Contains("`r") -or $resolvedPath.Contains("`n")) {
        throw "Python resolution failed: resolved path contains unexpected extra output."
    }

    if (!(Test-Path $resolvedPath)) {
        throw "Python resolution failed: resolved path does not exist: $resolvedPath"
    }

    if ($resolvedPath -like "$env:SystemDrive\Users\*") {
        throw "Python resolution failed: resolved path points into a user profile, not a machine-wide install: $resolvedPath"
    }

    return $resolvedPath
}

function Ensure-MachinePython {
    $pythonExePath = Resolve-PythonExe
    if (Test-MachinePythonPath $pythonExePath) {
        Write-Host "Python found: $pythonExePath" -ForegroundColor Green
        return $pythonExePath
    }

    if ($pythonExePath) {
        Write-Warning "Python is installed inside a user profile ($pythonExePath). Installing a machine-wide Python so the service account can run it safely."
    } else {
        Write-Host "Python not found." -ForegroundColor Yellow
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installing Python via winget (machine scope)..." -ForegroundColor Yellow
        try {
            & winget install --id Python.Python.3.13 --exact --source winget --scope machine --silent --accept-package-agreements --accept-source-agreements *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "winget installation did not complete successfully (exit code $LASTEXITCODE). Trying python.org fallback if needed."
            }
        } catch {
            Write-Warning "winget installation failed: $($_.Exception.Message)"
        }
    }

    $pythonExePath = Resolve-PythonExe
    if (Test-MachinePythonPath $pythonExePath) {
        Write-Host "Python installed successfully: $pythonExePath" -ForegroundColor Green
        return $pythonExePath
    }

    Write-Host "Downloading machine-wide Python installer from python.org..." -ForegroundColor Yellow
    $pythonUrl = "https://www.python.org/ftp/python/3.13.4/python-3.13.4-amd64.exe"
    $installerPath = Join-Path $env:TEMP "python-installer.exe"
    Invoke-WebRequest -Uri $pythonUrl -OutFile $installerPath -UseBasicParsing
    Start-Process -FilePath $installerPath -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1 Include_launcher=1" -Wait
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    $pythonExePath = Resolve-PythonExe
    if (Test-MachinePythonPath $pythonExePath) {
        Write-Host "Python installed successfully: $pythonExePath" -ForegroundColor Green
        return $pythonExePath
    }

    throw "Could not find a machine-wide python.exe after installation."
}

function Ensure-ServiceAccount {
    param(
        [string]$UserName,
        [string]$Password
    )

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $existingUser = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($existingUser) {
        Write-Host "Updating existing local service account $UserName" -ForegroundColor Yellow
        Set-LocalUser -Name $UserName -Password $securePassword -PasswordNeverExpires $true
    } else {
        Write-Host "Creating local service account $UserName" -ForegroundColor Yellow
        New-LocalUser -Name $UserName -Password $securePassword -AccountNeverExpires -PasswordNeverExpires -Description "Runs OCRmyPDF watcher scheduled tasks" -FullName "OCR Watcher Service Account" | Out-Null
    }

    return ".\$UserName"
}

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
    $exportPath = Join-Path $env:TEMP "ocrwatch-secpol.inf"

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

function Test-AccountHasUserRight {
    param(
        [string]$Principal,
        [string]$RightName
    )

    try {
        $sidValue = Assert-ResolvableIdentity $Principal
        $assignments = Get-UserRightsAssignments
        $assigned = @($assignments[$RightName]) | ForEach-Object { $_.TrimStart('*') }
        return $assigned -contains $sidValue
    } catch {
        Write-Warning "Could not inspect local security policy for ${RightName}: $($_.Exception.Message)"
        return $false
    }
}

function Wait-AccountUserRight {
    param(
        [string]$Principal,
        [string]$RightName,
        [int]$Attempts = 6,
        [int]$DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (Test-AccountHasUserRight -Principal $Principal -RightName $RightName) {
            return $true
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

function Grant-AccountBatchLogonRight {
    param([string]$Principal)

    $sidValue = Assert-ResolvableIdentity $Principal
    $batchRight = "SeBatchLogonRight"
    $denyBatchRight = "SeDenyBatchLogonRight"

    $assignments = Get-UserRightsAssignments
    $denied = @($assignments[$denyBatchRight])
    if ($denied -contains "*$sidValue") {
        throw "The account '$Principal' is explicitly assigned '$denyBatchRight'. Remove that deny right before continuing."
    }

    $currentAllowed = @($assignments[$batchRight])
    if ($currentAllowed -contains "*$sidValue") {
        return
    }

    $updatedAllowed = @($currentAllowed + "*$sidValue") | Select-Object -Unique
    $configPath = Join-Path $env:TEMP "ocrwatch-batchlogon.inf"
    $dbPath = Join-Path $env:TEMP "ocrwatch-batchlogon.sdb"
    $inf = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
$batchRight = $($updatedAllowed -join ',')
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
}

function Get-RecentTaskSchedulerEvents {
    param(
        [string]$TaskName,
        [int]$MaxEvents = 8
    )

    $taskPathFragment = "\$TaskName"
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

function Get-WatcherProcess {
    param([string]$WatcherScriptPath)

    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$WatcherScriptPath*" } |
        Select-Object -First 1
}

function Set-ExplicitPathAcl {
    param(
        [string]$Path,
        [bool]$IsDirectory,
        [string[]]$FullControlPrincipals,
        [string[]]$ModifyPrincipals,
        [string[]]$ReadExecutePrincipals
    )

    if (!(Test-Path $Path)) { return }

    if ($IsDirectory) {
        $acl = Get-Acl -Path $Path
        $inheritFlags = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    } else {
        $acl = Get-Acl -Path $Path
        $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::None
    }

    $acl.SetAccessRuleProtection($true, $false)
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None

    foreach ($existingRule in @($acl.Access)) {
        $null = $acl.RemoveAccessRuleAll($existingRule)
    }

    foreach ($principal in $FullControlPrincipals | Select-Object -Unique) {
        $identity = Resolve-IdentityReference $principal
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritFlags,
            $propagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule) | Out-Null
    }

    foreach ($principal in $ModifyPrincipals | Select-Object -Unique) {
        $identity = Resolve-IdentityReference $principal
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::Modify,
            $inheritFlags,
            $propagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule) | Out-Null
    }

    foreach ($principal in $ReadExecutePrincipals | Select-Object -Unique) {
        $identity = Resolve-IdentityReference $principal
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritFlags,
            $propagationFlags,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule) | Out-Null
    }

    Set-Acl -Path $Path -AclObject $acl
}

function Protect-Tree {
    param(
        [string]$RootPath,
        [string[]]$FullControlPrincipals,
        [string[]]$ModifyPrincipals,
        [string[]]$ReadExecutePrincipals
    )

    if (!(Test-Path $RootPath)) { return }

    Set-ExplicitPathAcl -Path $RootPath -IsDirectory $true -FullControlPrincipals $FullControlPrincipals -ModifyPrincipals $ModifyPrincipals -ReadExecutePrincipals $ReadExecutePrincipals

    Get-ChildItem -Path $RootPath -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ExplicitPathAcl -Path $_.FullName -IsDirectory $_.PSIsContainer -FullControlPrincipals $FullControlPrincipals -ModifyPrincipals $ModifyPrincipals -ReadExecutePrincipals $ReadExecutePrincipals
    }
}

function Protect-BaseDir {
    param(
        [string]$BaseDirPath,
        [string]$WatcherScriptPath,
        [string]$CleanupScriptPath,
        [string]$StatusScriptPath,
        [string]$UninstallScriptPath,
        [string]$ConfigFilePath,
        [string]$LogFilePath,
        [string]$ProcessedHashesFilePath,
        [string]$TempFolderPath,
        [string]$BackupFolderPath,
        [string]$WatchFolderPath,
        [string[]]$AdminPrincipals,
        [string]$ServicePrincipal,
        [string[]]$WatchFolderModifyPrincipals
    )

    Set-ExplicitPathAcl -Path $BaseDirPath -IsDirectory $true -FullControlPrincipals $AdminPrincipals -ModifyPrincipals @() -ReadExecutePrincipals @($ServicePrincipal)

    foreach ($filePath in @($WatcherScriptPath, $CleanupScriptPath, $StatusScriptPath, $UninstallScriptPath, $ConfigFilePath)) {
        Set-ExplicitPathAcl -Path $filePath -IsDirectory $false -FullControlPrincipals $AdminPrincipals -ModifyPrincipals @() -ReadExecutePrincipals @($ServicePrincipal)
    }

    Set-ExplicitPathAcl -Path $LogFilePath -IsDirectory $false -FullControlPrincipals $AdminPrincipals -ModifyPrincipals @($ServicePrincipal) -ReadExecutePrincipals @()
    Set-ExplicitPathAcl -Path $ProcessedHashesFilePath -IsDirectory $false -FullControlPrincipals $AdminPrincipals -ModifyPrincipals @($ServicePrincipal) -ReadExecutePrincipals @()
    Protect-Tree -RootPath $TempFolderPath -FullControlPrincipals $AdminPrincipals -ModifyPrincipals @($ServicePrincipal) -ReadExecutePrincipals @()
    Protect-Tree -RootPath $BackupFolderPath -FullControlPrincipals $AdminPrincipals -ModifyPrincipals @($ServicePrincipal) -ReadExecutePrincipals @()
    Protect-Tree -RootPath $WatchFolderPath -FullControlPrincipals $AdminPrincipals -ModifyPrincipals ($WatchFolderModifyPrincipals + $ServicePrincipal | Select-Object -Unique) -ReadExecutePrincipals @()
}

# Require administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator', then run setup.ps1 again." -ForegroundColor Yellow
    pause
    exit 1
}

$TempFolder = Join-Path $BaseDir "temp"
$BackupFolder = Join-Path $BaseDir "backup"
$LogFile = Join-Path $BaseDir "ocr.log"
$ProcessedHashesFile = Join-Path $BaseDir "processed.hashes"
$SourceScriptsDir = Join-Path $PSScriptRoot "scripts"
$SourceConfigFile = Join-Path $SourceScriptsDir "ocrwatch-config.ps1"
$ConfigFile = Join-Path $BaseDir "ocrwatch-config.ps1"
$WatcherScriptPath = Join-Path $BaseDir "ocrwatch-watcher.ps1"
$CleanupScriptPath = Join-Path $BaseDir "ocrwatch-cleanup.ps1"
$StatusScriptPath = Join-Path $BaseDir "ocrwatch-logs.ps1"
$UninstallScriptPath = Join-Path $BaseDir "ocrwatch-uninstall.ps1"
$PrincipalListScriptPath = Join-Path $BaseDir "ocrwatch-list-principals.ps1"
$DiagnoseScriptPath = Join-Path $BaseDir "ocrwatch-diagnose.ps1"
$TaskName = "OCRmyPDF Auto Watcher"
$CleanupTaskName = "OCRmyPDF Backup Cleanup"
$TaskDescription = "Watches $WatchFolder and OCRs new PDFs"
$CleanupTaskDesc = "Cleans up backup files older than 7 days"
$OperatorPrincipal = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$ServiceAccountQualified = ".\$ServiceAccountName"
$ServiceAccountAclPrincipal = "$env:COMPUTERNAME\$ServiceAccountName"
$ServiceAccountTaskPrincipal = "$env:COMPUTERNAME\$ServiceAccountName"
$AdminPrincipals = @("S-1-5-32-544", "S-1-5-18", $OperatorPrincipal) | Select-Object -Unique
$ExistingConfig = Get-ExistingSetupConfig -ConfigPath $SourceConfigFile
if ($WatchFolderPrincipals.Count -eq 0 -and $ExistingConfig -and $ExistingConfig.WatchFolderPrincipals.Count -gt 0) {
    Write-ProgressInfo "Using WatchFolderPrincipals from source config ${SourceConfigFile}: $($ExistingConfig.WatchFolderPrincipals -join ', ')"
    $WatchFolderModifyPrincipals = @($ExistingConfig.WatchFolderPrincipals)
} elseif ($WatchFolderPrincipals.Count -eq 0) {
    $WatchFolderModifyPrincipals = @($OperatorPrincipal)
} else {
    $WatchFolderModifyPrincipals = $WatchFolderPrincipals
}
$WatchFolderModifyPrincipals = $WatchFolderModifyPrincipals | Select-Object -Unique

Write-Step "Step 1: Creating folders..."
foreach ($dir in @($BaseDir, $WatchFolder, $TempFolder, $BackupFolder)) {
    if (!(Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

foreach ($filePath in @($LogFile, $ProcessedHashesFile)) {
    if (!(Test-Path $filePath)) {
        New-Item -Path $filePath -ItemType File -Force | Out-Null
    }
}

Write-Step "Step 2: Ensuring a machine-wide Python installation..."
$PythonExePath = Ensure-MachinePython
$PythonExePath = Assert-MachinePythonPath $PythonExePath

Write-Step "Step 3: Installing ocrmypdf..."
& $PythonExePath -m pip install --upgrade pip
& $PythonExePath -m pip install ocrmypdf

$PythonScriptsPath = (& $PythonExePath -c "import os, sys; print(os.path.join(os.path.dirname(sys.executable), 'Scripts'))").Trim()
if (!(Test-Path (Join-Path $PythonScriptsPath "ocrmypdf.exe"))) {
    throw "ocrmypdf.exe was not found under $PythonScriptsPath after installation."
}

Write-Host "ocrmypdf ready via $PythonExePath" -ForegroundColor Green

Write-Step "Step 4: Installing OCR dependencies..."
if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey package manager..." -ForegroundColor Yellow
    try {
        Set-ExecutionPolicy RemoteSigned -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    } catch {
        Write-Warning "Chocolatey installation failed: $($_.Exception.Message)"
        Write-Warning "OCR will work only if Ghostscript, Tesseract, unpaper, and pngquant are already installed."
    }
}

if (Get-Command choco -ErrorAction SilentlyContinue) {
    foreach ($package in @("ghostscript", "tesseract", "unpaper", "pngquant")) {
        try {
            Write-Host "Installing $package..." -ForegroundColor Cyan
            choco install $package -y --no-progress 2>&1 | Out-Null
        } catch {
            Write-Warning "$package installation failed: $($_.Exception.Message)"
        }
    }

    Write-Host "Note: jbig2enc is not available via Chocolatey on Windows." -ForegroundColor Yellow

    try {
        $tesseractPath = @(
            "C:\Program Files\Tesseract-OCR",
            "C:\Program Files (x86)\Tesseract-OCR"
        ) | Where-Object { Test-Path (Join-Path $_ "tesseract.exe") } | Select-Object -First 1

        if ($tesseractPath) {
            $deuFile = Join-Path (Join-Path $tesseractPath "tessdata") "deu.traineddata"
            if (!(Test-Path $deuFile)) {
                Write-Host "Downloading German language data..." -ForegroundColor Yellow
                Invoke-WebRequest -Uri "https://github.com/tesseract-ocr/tessdata/raw/main/deu.traineddata" -OutFile $deuFile -UseBasicParsing
            }
        }
    } catch {
        Write-Warning "German language pack installation failed: $($_.Exception.Message)"
    }
}

Write-Step "Step 5: Copying scripts..."
$ScriptDir = $SourceScriptsDir
$scriptsToCopy = @(
    @{ Source = "ocrwatch-watcher.ps1"; Dest = $WatcherScriptPath },
    @{ Source = "ocrwatch-cleanup.ps1"; Dest = $CleanupScriptPath },
    @{ Source = "ocrwatch-logs.ps1"; Dest = $StatusScriptPath },
    @{ Source = "ocrwatch-diagnose.ps1"; Dest = $DiagnoseScriptPath },
    @{ Source = "ocrwatch-uninstall.ps1"; Dest = $UninstallScriptPath },
    @{ Source = "ocrwatch-list-principals.ps1"; Dest = $PrincipalListScriptPath }
)

foreach ($script in $scriptsToCopy) {
    $sourcePath = Join-Path $ScriptDir $script.Source
    if (!(Test-Path $sourcePath)) {
        throw "Source script not found: $sourcePath"
    }
    Copy-Item -Path $sourcePath -Destination $script.Dest -Force
    Write-Host "Copied: $($script.Source) -> $($script.Dest)" -ForegroundColor Green
}

Write-Step "Step 6: Creating local service account..."
$ServiceAccountPassword = New-StrongPassword
Write-ProgressInfo "Generating service-account password..."
$ServiceAccountQualified = Ensure-ServiceAccount -UserName $ServiceAccountName -Password $ServiceAccountPassword
Write-ProgressDone "Service account ready: $ServiceAccountQualified"
Write-ProgressInfo "Ensuring 'Log on as a batch job' for $ServiceAccountTaskPrincipal..."
Grant-AccountBatchLogonRight -Principal $ServiceAccountTaskPrincipal
$hasBatchLogonRight = Wait-AccountUserRight -Principal $ServiceAccountTaskPrincipal -RightName "SeBatchLogonRight"
if ($hasBatchLogonRight) {
    Write-ProgressDone "Service account has 'Log on as a batch job'"
} else {
    Write-Warning "Could not confirm 'Log on as a batch job' immediately for $ServiceAccountTaskPrincipal."
    Write-Warning "Proceeding with setup and validating by attempting to start the task."
}

Write-Step "Step 7: Writing shared configuration..."
Write-ProgressInfo "Writing config to $ConfigFile..."
@"
# ocrwatch-config.ps1 - generated by setup.ps1
# Edit paths here to reconfigure the watcher. Re-run setup.ps1 after changing
# folder paths so scheduled tasks and ACLs stay in sync.

`$BaseDir               = "$BaseDir"
`$WatchFolder           = "$WatchFolder"
`$TempFolder            = "$TempFolder"
`$BackupFolder          = "$BackupFolder"
`$LogFile               = "$LogFile"
`$ProcessedHashesFile   = "$ProcessedHashesFile"
`$Language              = "eng+deu"
`$DaysToKeep            = 7
`$TaskName              = "$TaskName"
`$CleanupTaskName       = "$CleanupTaskName"
`$ServiceAccountName    = "$ServiceAccountQualified"
`$PythonExePath         = "$PythonExePath"
`$WatchFolderPrincipals = @("$($WatchFolderModifyPrincipals -join '","')")
"@ | Out-File -FilePath $ConfigFile -Encoding ASCII
Write-ProgressDone "Configuration written"

Write-Step "Step 8: Applying ACL lockdown..."
Write-ProgressInfo "Applying ACLs to base directory, scripts, log, temp, backup, and watch folder..."
Write-Host "  Admin principals     -> $($AdminPrincipals -join ', ')" -ForegroundColor DarkCyan
Write-Host "  Service principal    -> $ServiceAccountAclPrincipal" -ForegroundColor DarkCyan
Write-Host "  Watch-folder users   -> $($WatchFolderModifyPrincipals -join ', ')" -ForegroundColor DarkCyan
Protect-BaseDir `
    -BaseDirPath $BaseDir `
    -WatcherScriptPath $WatcherScriptPath `
    -CleanupScriptPath $CleanupScriptPath `
    -StatusScriptPath $StatusScriptPath `
    -UninstallScriptPath $UninstallScriptPath `
    -ConfigFilePath $ConfigFile `
    -LogFilePath $LogFile `
    -ProcessedHashesFilePath $ProcessedHashesFile `
    -TempFolderPath $TempFolder `
    -BackupFolderPath $BackupFolder `
    -WatchFolderPath $WatchFolder `
    -AdminPrincipals $AdminPrincipals `
    -ServicePrincipal $ServiceAccountAclPrincipal `
    -WatchFolderModifyPrincipals $WatchFolderModifyPrincipals
Write-ProgressDone "ACL lockdown complete"

Write-Step "Step 9: Registering Scheduled Tasks..."
$watcherAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$WatcherScriptPath`""
$watcherTrigger = New-ScheduledTaskTrigger -AtStartup
$watcherSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Hours 0)

Write-ProgressInfo "Verifying scheduled-task identity '$ServiceAccountTaskPrincipal'..."
$serviceAccountSid = Assert-ResolvableIdentity $ServiceAccountTaskPrincipal
Write-ProgressDone "Scheduled-task identity resolves to SID $serviceAccountSid"

Write-ProgressInfo "Registering watcher task '$TaskName'..."
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $watcherAction -Trigger $watcherTrigger -User $ServiceAccountTaskPrincipal -Password $ServiceAccountPassword -RunLevel Limited -Settings $watcherSettings -Description $TaskDescription -Force -ErrorAction Stop | Out-Null
Write-ProgressDone "Watcher task registered"

$cleanupAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$CleanupScriptPath`""
$cleanupTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am
$cleanupSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Write-ProgressInfo "Registering cleanup task '$CleanupTaskName'..."
Unregister-ScheduledTask -TaskName $CleanupTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $CleanupTaskName -Action $cleanupAction -Trigger $cleanupTrigger -User $ServiceAccountTaskPrincipal -Password $ServiceAccountPassword -RunLevel Limited -Settings $cleanupSettings -Description $CleanupTaskDesc -Force -ErrorAction Stop | Out-Null
Write-ProgressDone "Cleanup task registered"

Write-Step "Step 10: Starting watcher task..."
Write-ProgressInfo "Starting watcher task..."
Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Start-Sleep -Seconds 5
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
$watcherProcess = Get-WatcherProcess -WatcherScriptPath $WatcherScriptPath
$recentTaskEvents = Get-RecentTaskSchedulerEvents -TaskName $TaskName
Write-ProgressDone "Watcher start requested"

if ($watcherProcess) {
    Write-ProgressDone "Watcher process detected (PID $($watcherProcess.ProcessId))"
} else {
    Write-Warning "The watcher task is registered, but no watcher process was detected after startup."
    Write-Warning "This usually means Windows refused to launch the task or the script exited immediately."
    Write-Host "Recent Task Scheduler events for '$TaskName':" -ForegroundColor Yellow
    if ($recentTaskEvents.Count -gt 0) {
        foreach ($event in $recentTaskEvents) {
            $message = ($event.Message -replace '\s+', ' ').Trim()
            Write-Host "  [$($event.TimeCreated)] Id=$($event.Id) $message" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  (No matching Task Scheduler operational events could be read.)" -ForegroundColor DarkYellow
    }
    Write-Host "Run diagnostics: powershell -File `"$DiagnoseScriptPath`"" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "Security defaults applied:"
Write-Host "  Service account   -> $ServiceAccountQualified"
Write-Host "  Python pinned     -> $PythonExePath"
Write-Host "  Watch folder ACL  -> $WatchFolder"
Write-Host "  Script ACLs       -> $BaseDir"
Write-Host ""
Write-Host "Locations:"
Write-Host "  Config file       -> $ConfigFile"
Write-Host "  Watcher script    -> $WatcherScriptPath"
Write-Host "  Cleanup script    -> $CleanupScriptPath"
Write-Host "  Log checker       -> $StatusScriptPath"
Write-Host "  Diagnostics       -> $DiagnoseScriptPath"
Write-Host "  Principal helper  -> $PrincipalListScriptPath"
Write-Host "  Watch folder      -> $WatchFolder"
Write-Host "  Backup folder     -> $BackupFolder"
Write-Host "  Log file          -> $LogFile"
Write-Host "  Processed hashes  -> $ProcessedHashesFile"
Write-Host ""
Write-Host "Commands:"
Write-Host "  Check watcher status -> powershell -File `"$WatcherScriptPath`" -Status"
Write-Host "  View logs            -> powershell -File `"$WatcherScriptPath`" -Logs"
Write-Host "  View last 50 lines   -> powershell -File `"$WatcherScriptPath`" -Tail 50"
Write-Host "  Follow logs live     -> powershell -File `"$StatusScriptPath`" -Follow"
Write-Host "  Diagnose task        -> powershell -File `"$DiagnoseScriptPath`""
Write-Host "  List principals      -> powershell -File `"$PrincipalListScriptPath`""
Write-Host "  Manual cleanup       -> powershell -File `"$CleanupScriptPath`""
Write-Host ""
Write-Host "Manage tasks:"
Write-Host "  Stop watcher     -> Stop-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Start watcher    -> Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  Run cleanup now  -> Start-ScheduledTask -TaskName '$CleanupTaskName'"
Write-Host "  Uninstall        -> powershell -File `"$UninstallScriptPath`""
Write-Host ""
Write-Host "Task result: $($taskInfo.LastTaskResult)"
Write-Host ""
Write-Host "If you change watch-folder paths later, re-run setup.ps1 as Administrator so ACLs and task settings are updated too." -ForegroundColor Yellow
