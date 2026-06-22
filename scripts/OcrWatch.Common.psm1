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

function Test-MachinePythonPath {
    param(
        [string]$Path,
        [string]$SystemDrive = $env:SystemDrive
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.Contains("`r") -or $Path.Contains("`n")) { return $false }
    if (!(Test-Path $Path)) { return $false }
    if ($SystemDrive -and $Path -like "$SystemDrive\Users\*") { return $false }
    return $true
}

function Assert-MachinePythonPath {
    param(
        [object]$PathValue,
        [string]$SystemDrive = $env:SystemDrive
    )

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

    if ($SystemDrive -and $resolvedPath -like "$SystemDrive\Users\*") {
        throw "Python resolution failed: resolved path points into a user profile, not a machine-wide install: $resolvedPath"
    }

    return $resolvedPath
}

function Get-FileContentHash {
    param([string]$Path)

    if (!(Test-Path $Path)) {
        throw "File not found: $Path"
    }

    return (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function New-ProcessedHashSet {
    return New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
}

function Import-ProcessedHashes {
    param(
        [string]$Path,
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$HashSet,
        [scriptblock]$LogAction
    )

    if (!(Test-Path $Path)) {
        return
    }

    try {
        foreach ($line in Get-Content -Path $Path -ErrorAction Stop) {
            $normalized = $line.Trim().ToUpperInvariant()
            if ($normalized) {
                $null = $HashSet.Add($normalized)
            }
        }
    } catch {
        if ($LogAction) {
            & $LogAction "Failed to load processed hash state from ${Path}: $($_.Exception.Message)" "ERROR"
        } else {
            throw
        }
    }
}

function Add-ProcessedHash {
    param(
        [string]$Path,
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

    Add-Content -Path $Path -Value $normalized -ErrorAction Stop
    $null = $HashSet.Add($normalized)
    return $true
}

function Write-Log {
    param(
        [string]$Path,
        [string]$Message,
        [string]$Level = "INFO"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [$Level] $Message" | Tee-Object -FilePath $Path -Append | Write-Host
}

function Resolve-TaskSchedulerResultMessage {
    param([long]$Code)

    switch ($Code) {
        267011 { return "0x41303 SCHED_S_TASK_HAS_NOT_RUN: the task has not run yet." }
        2147943785 { return "0x80070569 ERROR_LOGON_TYPE_NOT_GRANTED: the account lacks the requested logon type on this computer." }
        default { return ("0x{0:X8}" -f $Code) }
    }
}

Export-ModuleMember -Function @(
    "New-StrongPassword",
    "Test-MachinePythonPath",
    "Assert-MachinePythonPath",
    "Get-FileContentHash",
    "New-ProcessedHashSet",
    "Import-ProcessedHashes",
    "Add-ProcessedHash",
    "Write-Log",
    "Resolve-TaskSchedulerResultMessage"
)
