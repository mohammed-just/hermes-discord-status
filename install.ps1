[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Mandatory = $true)]
    [string] $VencordPath,

    [string] $WslDistribution,

    [string] $HermesHome,

    [switch] $SkipVencordBuild,

    [switch] $SkipHermesCommands,

    [switch] $ShowToken
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "install.helpers.ps1")

$TokenKey = "HERMES_DISCORD_STATUS_TOKEN"
$PluginName = "hermesStatus"
$BridgeName = "discord-status"

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message"
}

function Resolve-FullPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path is empty."
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithin {
    param(
        [string] $Path,
        [string] $Parent
    )
    $fullPath = (Resolve-FullPath $Path).TrimEnd("\", "/")
    $fullParent = (Resolve-FullPath $Parent).TrimEnd("\", "/")
    return $fullPath.Equals($fullParent, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullParent + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullParent + [System.IO.Path]::AltDirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-HermesPathOverlap {
    param(
        [string] $First,
        [string] $Second
    )
    return (Test-PathWithin $First $Second) -or (Test-PathWithin $Second $First)
}

function Assert-NoPathOverlap {
    param(
        [object[]] $Entries
    )
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        for ($j = $i + 1; $j -lt $Entries.Count; $j++) {
            if (Test-HermesPathOverlap $Entries[$i].Path $Entries[$j].Path) {
                throw "Unsafe path overlap between $($Entries[$i].Label) and $($Entries[$j].Label): $($Entries[$i].Path) / $($Entries[$j].Path)"
            }
        }
    }
}

function Assert-WindowsPathNoReparsePoint {
    param(
        [string] $Path,
        [string] $ApprovedRoot,
        [string] $Description
    )
    $fullPath = Resolve-FullPath $Path
    $fullRoot = Resolve-FullPath $ApprovedRoot
    if (-not (Test-PathWithin $fullPath $fullRoot)) {
        throw "$Description escapes approved root: $fullPath"
    }

    $current = $fullPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Description must not contain a symlink, junction, or other reparse point: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) {
            break
        }
        $current = $parent
    }
}

function Assert-PathTreeNoReparsePoint {
    param(
        [string] $Path,
        [string] $Description
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue((Resolve-FullPath $Path))
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $currentItem = Get-Item -LiteralPath $current -Force
        if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description must not contain a symlink, junction, or other reparse point: $($currentItem.FullName)"
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Description must not contain a symlink, junction, or other reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $queue.Enqueue($item.FullName)
            }
        }
    }
}

function Assert-ExistingDirectory {
    param(
        [string] $Path,
        [string] $Description
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description does not exist or is not a directory: $Path"
    }
}

function Assert-NoReparsePoint {
    param(
        [string] $Path,
        [string] $Description
    )
    if ($Path -match '^\\\\wsl(\.localhost|\$)\\') {
        return
    }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description must not be a symlink, junction, or other reparse point: $Path"
        }
    }
}

function Assert-RegularFileOrAbsent {
    param(
        [string] $Path,
        [string] $Description
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description must be absent or a regular non-reparse file: $Path"
    }
    Assert-NoReparsePoint $Path $Description
}

function Assert-ManagedDirectoryOrAbsent {
    param(
        [string] $Path,
        [string] $Description
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description must be absent or an actual non-reparse managed directory destination: $Path"
    }
    Assert-NoReparsePoint $Path $Description
}

function Assert-SourceProject {
    param([string] $Root)
    Assert-ExistingDirectory $Root "Repository root"
    Assert-ExistingDirectory (Join-Path $Root "bridge") "Hermes bridge source"
    Assert-ExistingDirectory (Join-Path $Root "vencord-userplugin/hermesStatus") "Vencord userplugin source"

    foreach ($relative in @(
        "bridge/plugin.yaml",
        "bridge/server.py",
        "vencord-userplugin/hermesStatus/index.tsx",
        "vencord-userplugin/hermesStatus/settings.ts"
    )) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required source file is missing: $relative"
        }
    }
}

function Assert-VencordCheckout {
    param([string] $Root)
    Assert-ExistingDirectory $Root "Vencord checkout"
    if ($Root -match "\\AppData\\" -and $Root -match "\\dist(\\|$)") {
        throw "Refusing packaged AppData/dist path as a Vencord plugin source checkout: $Root"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root "package.json") -PathType Leaf)) {
        throw "Vencord checkout is missing package.json: $Root"
    }
    Assert-ExistingDirectory (Join-Path $Root "src/userplugins") "Vencord src/userplugins directory"
}

function Resolve-HermesHome {
    param(
        [string] $ExplicitHome,
        [string] $Distribution
    )
    if (-not [string]::IsNullOrWhiteSpace($ExplicitHome)) {
        return (Resolve-FullPath $ExplicitHome)
    }

    if (-not [string]::IsNullOrWhiteSpace($Distribution) -and -not (Test-HermesWslDistributionName $Distribution)) {
        throw "WSL distribution names may contain only letters, numbers, dot, underscore, and hyphen."
    }

    if ($WhatIfPreference) {
        Write-Host "WhatIf: would resolve Hermes home through WSL"
        return (Resolve-FullPath (Join-Path ([System.IO.Path]::GetTempPath()) "hermes-discord-status-whatif-home"))
    }

    $wsl = Resolve-HermesTrustedWslExe
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $args += @("-d", $Distribution)
    }
    $args += @("--", "sh", "-lc", 'wslpath -w "$HOME/.hermes"')
    $resolved = & $wsl @args
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve Hermes home through WSL."
    }
    $resolvedText = ($resolved | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($resolvedText)) {
        throw "WSL returned an empty Hermes home path."
    }
    return (Resolve-FullPath $resolvedText)
}

function Get-ManagedFiles {
    param([string] $Source)
    @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force |
        Where-Object {
            $_.FullName -notmatch "\\__pycache__\\" -and
            $_.Extension -ne ".pyc"
        })
}

function Get-ManagedDirectories {
    param([string] $Source)
    @(Get-ChildItem -LiteralPath $Source -Recurse -Directory -Force |
        Where-Object {
            $_.FullName -notmatch "\\__pycache__\\"
        })
}

function Get-FileFingerprint {
    param([string] $Path)
    return Get-HermesFileFingerprint $Path
}

function Get-DirectoryFingerprint {
    param([string] $Path)
    return Get-HermesDirectoryFingerprint $Path
}

function Assert-OperationDestinationUnchanged {
    param([hashtable] $Operation)
    if ($Operation.Kind -eq "Directory") {
        if (-not (Test-Path -LiteralPath $Operation.Destination -PathType Container)) {
            throw "Rollback refused to remove changed or missing directory destination: $($Operation.Destination)"
        }
        $actual = Get-DirectoryFingerprint $Operation.Destination
    } else {
        if (-not (Test-Path -LiteralPath $Operation.Destination -PathType Leaf)) {
            throw "Rollback refused to remove changed or missing file destination: $($Operation.Destination)"
        }
        $actual = Get-FileFingerprint $Operation.Destination
    }
    if ($actual -ne $Operation.ExpectedFingerprint) {
        throw "Rollback refused to remove destination because content changed unexpectedly: $($Operation.Destination)"
    }
}

function Invoke-InstallPathSafety {
    param(
        $Safety,
        [string] $Path,
        [string] $Description
    )
    if ($null -eq $Safety) {
        return
    }
    Invoke-HermesOperationSafety @{ Safety = $Safety } $Path $Description
}

function Add-HermesInstallJournal {
    param(
        [string] $Operation,
        [string] $Path
    )
    $journalVariable = Get-Variable -Name HermesInstallJournal -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $journalVariable -and $null -ne $journalVariable.Value) {
        $journalVariable.Value.Add(@{ Operation = $Operation; Path = $Path }) | Out-Null
    }
}

function Invoke-HermesInstallerFault {
    param(
        [string] $Point,
        [string] $Path
    )
    $faultVariable = Get-Variable -Name HermesInstallerFaultInjector -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $faultVariable -and $null -ne $faultVariable.Value) {
        & $faultVariable.Value $Point $Path
    }
}

function Assert-HermesBackupFingerprint {
    param(
        [string] $Kind,
        [string] $Backup,
        [string] $ExpectedFingerprint
    )
    if ([string]::IsNullOrEmpty($ExpectedFingerprint)) {
        return
    }
    $actual = Get-HermesOperationFingerprint $Kind $Backup
    if ($actual -ne $ExpectedFingerprint) {
        throw "Backup fingerprint changed before restore: $Backup"
    }
}

function Remove-HermesDirectorySafely {
    param(
        [string] $Path,
        [string] $ExpectedFingerprint,
        $Safety,
        [string] $Description
    )
    if ($null -ne $Safety) {
        Invoke-InstallPathSafety $Safety $Path "$Description safety"
    }
    if ((Get-DirectoryFingerprint $Path) -ne $ExpectedFingerprint) {
        throw "$Description fingerprint changed"
    }
    if ($null -ne $Safety) {
        Invoke-InstallPathSafety $Safety $Path "$Description final safety"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Start-ManagedDirectoryReplacement {
    param(
        [string] $Source,
        [string] $Destination,
        [string] $Label,
        $Safety
    )

    $sourceFull = Resolve-FullPath $Source
    $destFull = Resolve-FullPath $Destination
    $parent = Split-Path -Parent $destFull

    if (-not $script:InstallExecute) {
        Write-Host "WhatIf: would replace $Label at $destFull"
        return @{ Kind = "Directory"; Label = $Label; Destination = $destFull; Stage = $null; Backup = $null; HadDestination = $false; Applied = $false; Safety = $Safety }
    }

    if ($null -ne $Safety) {
        Invoke-InstallPathSafety $Safety $parent "$Label parent before create"
    }
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if ($null -ne $Safety) {
        Invoke-InstallPathSafety $Safety $parent "$Label parent after create"
    }
    $stamp = [guid]::NewGuid().ToString("N")
    $stage = Join-Path $parent ".$([System.IO.Path]::GetFileName($destFull)).stage.$stamp"
    $backup = Join-Path $parent ".$([System.IO.Path]::GetFileName($destFull)).backup.$stamp"
    $backupCreated = $false
    $destReplaced = $false

    try {
        if ($null -ne $Safety) {
            Invoke-InstallPathSafety $Safety $stage "$Label stage"
        }
        New-Item -ItemType Directory -Path $stage | Out-Null
        Assert-PathTreeNoReparsePoint $sourceFull "$Label source"
        $directories = Get-ManagedDirectories $sourceFull
        foreach ($directory in $directories) {
            $relativeDirectory = $directory.FullName.Substring($sourceFull.TrimEnd("\", "/").Length + 1)
            New-Item -ItemType Directory -Force -Path (Join-Path $stage $relativeDirectory) | Out-Null
        }
        $files = Get-ManagedFiles $sourceFull
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($sourceFull.TrimEnd("\", "/").Length + 1)
            $target = Join-Path $stage $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }

        $stageFingerprint = Get-DirectoryFingerprint $stage
        $previousFingerprint = $null
        if (Test-Path -LiteralPath $destFull) {
            if ($null -ne $Safety) {
                Invoke-InstallPathSafety $Safety $destFull "$Label destination before fingerprint"
            }
            $previousFingerprint = Get-DirectoryFingerprint $destFull
            if ($null -ne $Safety) {
                Invoke-InstallPathSafety $Safety $destFull "$Label destination before backup"
                Invoke-InstallPathSafety $Safety $backup "$Label backup"
            }
            Move-Item -LiteralPath $destFull -Destination $backup
            Add-HermesInstallJournal "$Label backup-created" $backup
            $backupCreated = $true
        }
        if ($null -ne $Safety) {
            Invoke-InstallPathSafety $Safety $stage "$Label stage before install"
            Invoke-InstallPathSafety $Safety $destFull "$Label destination before install"
        }
        Move-Item -LiteralPath $stage -Destination $destFull
        Add-HermesInstallJournal "$Label destination-installed" $destFull
        $destReplaced = $true
        Invoke-HermesInstallerFault "$Label-after-destination-move" $destFull
        if (-not (Test-Path -LiteralPath $destFull -PathType Container)) {
            throw "$Label destination was not a directory after replacement: $destFull"
        }
        if ((Get-DirectoryFingerprint $destFull) -ne $stageFingerprint) {
            throw "$Label destination fingerprint did not match staged replacement: $destFull"
        }
        return @{ Kind = "Directory"; Label = $Label; Destination = $destFull; Stage = $stage; Backup = $backup; HadDestination = $backupCreated; Applied = $true; ExpectedFingerprint = $stageFingerprint; PreviousFingerprint = $previousFingerprint; Safety = $Safety }
    } catch {
        $restoreErrors = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $stage) {
            try {
                if ($null -ne $Safety) {
                    Invoke-InstallPathSafety $Safety $stage "$Label stage cleanup"
                }
                Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
            } catch {
                $restoreErrors.Add("failed to remove stage $stage`: $($_.Exception.Message)")
            }
        }
        if ($backupCreated) {
            if ($destReplaced -and (Test-Path -LiteralPath $destFull)) {
                try {
                    Remove-HermesDirectorySafely $destFull $stageFingerprint $Safety "$Label replacement cleanup"
                } catch {
                    $restoreErrors.Add("failed to remove replacement $destFull`: $($_.Exception.Message)")
                }
            } elseif ((-not $destReplaced) -and (Test-Path -LiteralPath $destFull)) {
                try {
                    Remove-HermesDirectorySafely $destFull $stageFingerprint $Safety "$Label partial destination cleanup"
                } catch {
                    $restoreErrors.Add("failed to remove partial destination $destFull`: $($_.Exception.Message)")
                }
            }
            if ((Test-Path -LiteralPath $backup) -and (-not (Test-Path -LiteralPath $destFull))) {
                try {
                    if ($null -ne $Safety) {
                        Invoke-InstallPathSafety $Safety $backup "$Label backup restore"
                        Invoke-InstallPathSafety $Safety $destFull "$Label destination restore"
                    }
                    Assert-HermesBackupFingerprint "Directory" $backup $previousFingerprint
                    if ($null -ne $Safety) {
                        Invoke-InstallPathSafety $Safety $backup "$Label backup restore final"
                        Invoke-InstallPathSafety $Safety $destFull "$Label destination restore final"
                    }
                    Move-Item -LiteralPath $backup -Destination $destFull -ErrorAction Stop
                    Add-HermesInstallJournal "$Label backup-restored" $destFull
                    if (-not (Test-Path -LiteralPath $destFull -PathType Container)) {
                        throw "restored path is not a directory"
                    }
                    if ((Get-DirectoryFingerprint $destFull) -ne $previousFingerprint) {
                        throw "restored backup fingerprint changed"
                    }
                } catch {
                    $restoreErrors.Add("failed to restore backup $backup to $destFull`: $($_.Exception.Message)")
                }
            } elseif ((Test-Path -LiteralPath $backup) -and (Test-Path -LiteralPath $destFull)) {
                $restoreErrors.Add("preserved backup $backup because destination could not be safely cleared: $destFull")
            }
        } elseif ($destReplaced -and (Test-Path -LiteralPath $destFull)) {
            try {
                Remove-HermesDirectorySafely $destFull $stageFingerprint $Safety "$Label first-install cleanup"
            } catch {
                $restoreErrors.Add("failed to remove first-install destination $destFull`: $($_.Exception.Message)")
            }
        }
        if ($restoreErrors.Count -gt 0) {
            throw "$($_.Exception.Message) Rollback uncertainty: $($restoreErrors -join '; ')"
        }
        throw
    }
}

function Complete-InstallOperation {
    param([hashtable] $Operation)
    Complete-HermesInstallOperation $Operation
}

function Undo-InstallOperation {
    param([hashtable] $Operation)
    if ($null -eq $Operation -or -not $Operation.Applied) {
        return
    }

    $rollbackErrors = New-Object System.Collections.Generic.List[string]

    if ($Operation.Kind -eq "Directory") {
        if (Test-Path -LiteralPath $Operation.Stage) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Stage "$($Operation.Label) stage rollback cleanup"
                Remove-Item -LiteralPath $Operation.Stage -Recurse -Force -ErrorAction Stop
            } catch { $rollbackErrors.Add("failed to remove stage $($Operation.Stage): $($_.Exception.Message)") }
        }
        if (Test-Path -LiteralPath $Operation.Destination) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Destination "$($Operation.Label) destination rollback cleanup"
                Assert-OperationDestinationUnchanged $Operation
                Invoke-HermesOperationSafety $Operation $Operation.Destination "$($Operation.Label) destination rollback cleanup final"
                Remove-Item -LiteralPath $Operation.Destination -Recurse -Force -ErrorAction Stop
            } catch {
                $rollbackErrors.Add($_.Exception.Message)
            }
        }
        if ($Operation.HadDestination -and (Test-Path -LiteralPath $Operation.Backup) -and (-not (Test-Path -LiteralPath $Operation.Destination))) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Backup "$($Operation.Label) backup rollback restore"
                Invoke-HermesOperationSafety $Operation $Operation.Destination "$($Operation.Label) destination rollback restore"
                if ($Operation.ContainsKey("PreviousFingerprint")) {
                    Assert-HermesBackupFingerprint "Directory" $Operation.Backup $Operation.PreviousFingerprint
                }
                Invoke-HermesOperationSafety $Operation $Operation.Backup "$($Operation.Label) backup rollback restore final"
                Invoke-HermesOperationSafety $Operation $Operation.Destination "$($Operation.Label) destination rollback restore final"
                Move-Item -LiteralPath $Operation.Backup -Destination $Operation.Destination -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $Operation.Destination -PathType Container)) {
                    throw "restored destination is not a directory: $($Operation.Destination)"
                }
                if ($Operation.ContainsKey("PreviousFingerprint") -and (Get-DirectoryFingerprint $Operation.Destination) -ne $Operation.PreviousFingerprint) {
                    throw "restored destination fingerprint changed: $($Operation.Destination)"
                }
            } catch {
                $rollbackErrors.Add("failed to restore backup $($Operation.Backup) to $($Operation.Destination): $($_.Exception.Message)")
            }
        } elseif ($Operation.HadDestination -and (Test-Path -LiteralPath $Operation.Backup) -and (Test-Path -LiteralPath $Operation.Destination)) {
            $rollbackErrors.Add("preserved backup $($Operation.Backup) because destination could not be safely cleared: $($Operation.Destination)")
        } elseif (Test-Path -LiteralPath $Operation.Backup) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Backup "$($Operation.Label) unused backup cleanup"
                if ($Operation.ContainsKey("PreviousFingerprint")) {
                    Assert-HermesBackupFingerprint "Directory" $Operation.Backup $Operation.PreviousFingerprint
                }
                Invoke-HermesOperationSafety $Operation $Operation.Backup "$($Operation.Label) unused backup cleanup final"
                Remove-Item -LiteralPath $Operation.Backup -Recurse -Force -ErrorAction Stop
            } catch { $rollbackErrors.Add("failed to remove unused backup $($Operation.Backup): $($_.Exception.Message)") }
        }
    } elseif ($Operation.Kind -eq "File") {
        if (Test-Path -LiteralPath $Operation.Temp) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Temp "file temp rollback cleanup"
                Remove-Item -LiteralPath $Operation.Temp -Force -ErrorAction Stop
            } catch { $rollbackErrors.Add("failed to remove temp file $($Operation.Temp): $($_.Exception.Message)") }
        }
        if (Test-Path -LiteralPath $Operation.Destination) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Destination "file destination rollback cleanup"
                Assert-OperationDestinationUnchanged $Operation
                Invoke-HermesOperationSafety $Operation $Operation.Destination "file destination rollback cleanup final"
                Remove-Item -LiteralPath $Operation.Destination -Force -ErrorAction Stop
            } catch {
                $rollbackErrors.Add($_.Exception.Message)
            }
        }
        if ($Operation.HadDestination -and (Test-Path -LiteralPath $Operation.Backup) -and (-not (Test-Path -LiteralPath $Operation.Destination))) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Backup "file backup rollback restore"
                Invoke-HermesOperationSafety $Operation $Operation.Destination "file destination rollback restore"
                if ($Operation.ContainsKey("PreviousFingerprint")) {
                    Assert-HermesBackupFingerprint "File" $Operation.Backup $Operation.PreviousFingerprint
                }
                Invoke-HermesOperationSafety $Operation $Operation.Backup "file backup rollback restore final"
                Invoke-HermesOperationSafety $Operation $Operation.Destination "file destination rollback restore final"
                Move-Item -LiteralPath $Operation.Backup -Destination $Operation.Destination -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $Operation.Destination -PathType Leaf)) {
                    throw "restored destination is not a file: $($Operation.Destination)"
                }
                if ($Operation.ContainsKey("PreviousFingerprint") -and (Get-FileFingerprint $Operation.Destination) -ne $Operation.PreviousFingerprint) {
                    throw "restored file fingerprint changed: $($Operation.Destination)"
                }
            } catch {
                $rollbackErrors.Add("failed to restore backup $($Operation.Backup) to $($Operation.Destination): $($_.Exception.Message)")
            }
        } elseif ($Operation.HadDestination -and (Test-Path -LiteralPath $Operation.Backup) -and (Test-Path -LiteralPath $Operation.Destination)) {
            $rollbackErrors.Add("preserved backup $($Operation.Backup) because destination could not be safely cleared: $($Operation.Destination)")
        } elseif (Test-Path -LiteralPath $Operation.Backup) {
            try {
                Invoke-HermesOperationSafety $Operation $Operation.Backup "file unused backup cleanup"
                if ($Operation.ContainsKey("PreviousFingerprint")) {
                    Assert-HermesBackupFingerprint "File" $Operation.Backup $Operation.PreviousFingerprint
                }
                Remove-Item -LiteralPath $Operation.Backup -Force -ErrorAction Stop
            } catch { $rollbackErrors.Add("failed to remove unused backup $($Operation.Backup): $($_.Exception.Message)") }
        }
    }

    if ($rollbackErrors.Count -gt 0) {
        throw "Rollback failed for $($Operation.Destination): $($rollbackErrors -join '; ')"
    }
}

function New-BearerToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Read-HermesDotenvToken {
    param(
        [string[]] $Lines
    )
    $token = $null
    $tokenPattern = "^\s*(?:export\s+)?$([regex]::Escape($TokenKey))\s*=\s*(.*)$"
    foreach ($line in $Lines) {
        if ($line -notmatch $tokenPattern) {
            continue
        }
        $raw = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $token = $null
            continue
        }

        $value = $null
        if ($raw.StartsWith("'")) {
            $end = $raw.IndexOf("'", 1)
            if ($end -lt 1) {
                throw "Malformed or ambiguous $TokenKey assignment in .env."
            }
            $value = $raw.Substring(1, $end - 1)
            $tail = $raw.Substring($end + 1).Trim()
        } elseif ($raw.StartsWith('"')) {
            $end = $raw.IndexOf('"', 1)
            if ($end -lt 1) {
                throw "Malformed or ambiguous $TokenKey assignment in .env."
            }
            $value = $raw.Substring(1, $end - 1)
            $tail = $raw.Substring($end + 1).Trim()
        } else {
            $comment = [regex]::Match($raw, "\s#")
            if ($raw.Contains("#") -and -not $comment.Success) {
                throw "Malformed or ambiguous $TokenKey assignment in .env."
            }
            if ($comment.Success) {
                $value = $raw.Substring(0, $comment.Index).Trim()
                $tail = $raw.Substring($comment.Index + 1).Trim()
            } else {
                $value = $raw.Trim()
                $tail = ""
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($tail) -and -not $tail.StartsWith("#")) {
            throw "Malformed or ambiguous $TokenKey assignment in .env."
        }
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value -notmatch "^[A-Za-z0-9_-]+$") {
            throw "Malformed or ambiguous $TokenKey assignment in .env."
        }
        $token = $value
    }
    return $token
}

function Start-HermesTokenUpdate {
    param(
        [string] $EnvPath,
        $Safety
    )

    if ((-not $script:InstallExecute) -and $Safety -is [hashtable] -and $Safety.Type -eq "Wsl") {
        Write-Host "WhatIf: would inspect and update $TokenKey in $EnvPath during execution"
        return @{ Kind = "File"; Destination = $EnvPath; Temp = $null; Backup = $null; HadDestination = $false; Applied = $false; Token = $null; Created = $false; Written = $false; PlanUnknown = $true; Safety = $Safety }
    }
    if ($script:InstallExecute -and $null -ne $Safety) {
        Invoke-InstallPathSafety $Safety $EnvPath ".env before read"
    }
    $existingLines = @()
    $envExists = Test-Path -LiteralPath $EnvPath -PathType Leaf
    if ($envExists) {
        $existingLines = @([System.IO.File]::ReadAllLines($EnvPath))
    }

    $token = Read-HermesDotenvToken $existingLines

    $created = $false
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = New-BearerToken
        $created = $true
    }

    $keptLines = @($existingLines | Where-Object { $_ -notmatch "^\s*(?:export\s+)?$([regex]::Escape($TokenKey))\s*=" })
    $newLines = @()
    $newLines += $keptLines
    $newLines += "$TokenKey=$token"
    $text = ($newLines -join [Environment]::NewLine) + [Environment]::NewLine

    if (-not $script:InstallExecute) {
        Write-Host "WhatIf: would update $TokenKey in $EnvPath"
        return @{ Kind = "File"; Destination = $EnvPath; Temp = $null; Backup = $null; HadDestination = $envExists; Applied = $false; Token = $token; Created = $created; Written = $false; Safety = $Safety }
    }

    $envParent = Split-Path -Parent $EnvPath
    $envParentSafety = $Safety
    if ($Safety -is [hashtable] -and $Safety.Type -eq "Wsl") {
        $envParentSafety = $Safety.Clone()
        $envParentSafety.ExpectedKind = "Directory"
    }
    if ($null -ne $envParentSafety) {
        Invoke-InstallPathSafety $envParentSafety $envParent ".env parent before create"
    }
    New-Item -ItemType Directory -Force -Path $envParent | Out-Null
    if ($null -ne $envParentSafety) {
        Invoke-InstallPathSafety $envParentSafety $envParent ".env parent after create"
    }
    $stamp = [guid]::NewGuid().ToString("N")
    $tmp = "$EnvPath.tmp.$stamp"
    $backup = "$EnvPath.backup.$stamp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        if ($null -ne $Safety) {
            Invoke-InstallPathSafety $Safety $tmp ".env temp"
        }
        $wslTempHardened = $false
        if ($Safety -is [hashtable] -and $Safety.Type -eq "Wsl") {
            $stream = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $stream.Dispose()
            $parsedTmp = ConvertFrom-HermesWslUncPath -Path $tmp -WslDistribution $Safety.Distribution
            Invoke-HermesWslChmod600 -ParsedPath $parsedTmp -ApprovedLinuxRoot $Safety.ApprovedLinuxRoot
            $wslTempHardened = $true
            Invoke-HermesInstallerFault ".env-before-temp-write" $tmp
        }
        [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
        $newFingerprint = Get-FileFingerprint $tmp
        $previousFingerprint = $null
        if ($envExists) {
            if ($null -ne $Safety) {
                Invoke-InstallPathSafety $Safety $EnvPath ".env destination before fingerprint"
            }
            $previousFingerprint = Get-FileFingerprint $EnvPath
            if ($null -ne $Safety) {
                Invoke-InstallPathSafety $Safety $EnvPath ".env destination before backup"
                Invoke-InstallPathSafety $Safety $backup ".env backup"
            }
            Move-Item -LiteralPath $EnvPath -Destination $backup
            Add-HermesInstallJournal ".env backup-created" $backup
        }
        if ($null -ne $Safety) {
            Invoke-InstallPathSafety $Safety $tmp ".env temp before install"
            Invoke-InstallPathSafety $Safety $EnvPath ".env destination before install"
        }
        Move-Item -LiteralPath $tmp -Destination $EnvPath
        Add-HermesInstallJournal ".env destination-installed" $EnvPath
        Invoke-HermesInstallerFault ".env-after-destination-move" $EnvPath
        if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
            throw ".env was not a regular file after update: $EnvPath"
        }
        if ((Get-FileFingerprint $EnvPath) -ne $newFingerprint) {
            throw ".env fingerprint did not match staged update: $EnvPath"
        }
        return @{ Kind = "File"; Destination = $EnvPath; Temp = $tmp; Backup = $backup; HadDestination = $envExists; Applied = $true; Token = $token; Created = $created; Written = $true; ExpectedFingerprint = $newFingerprint; PreviousFingerprint = $previousFingerprint; Safety = $Safety }
    } catch {
        $originalError = $_.Exception.Message
        $restoreErrors = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $tmp) {
            try {
                if ($null -ne $Safety) {
                    Invoke-InstallPathSafety $Safety $tmp ".env temp cleanup"
                }
                Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop
            } catch {
                $restoreErrors.Add("failed to remove temp file $tmp`: $($_.Exception.Message)")
            }
        }
        if ($envExists -and (Test-Path -LiteralPath $backup)) {
            if (Test-Path -LiteralPath $EnvPath) {
                try {
                    if ((Get-FileFingerprint $EnvPath) -ne $newFingerprint) {
                        throw ".env destination fingerprint changed"
                    }
                    if ($null -ne $Safety) {
                        Invoke-InstallPathSafety $Safety $EnvPath ".env replacement cleanup"
                    }
                    Remove-Item -LiteralPath $EnvPath -Force -ErrorAction Stop
                } catch {
                    $restoreErrors.Add("failed to remove replacement $EnvPath`: $($_.Exception.Message)")
                }
            }
            if (-not (Test-Path -LiteralPath $EnvPath)) {
                try {
                    if ($null -ne $Safety) {
                        Invoke-InstallPathSafety $Safety $backup ".env backup restore"
                        Invoke-InstallPathSafety $Safety $EnvPath ".env destination restore"
                    }
                    Assert-HermesBackupFingerprint "File" $backup $previousFingerprint
                    if ($null -ne $Safety) {
                        Invoke-InstallPathSafety $Safety $backup ".env backup restore final"
                        Invoke-InstallPathSafety $Safety $EnvPath ".env destination restore final"
                    }
                    Move-Item -LiteralPath $backup -Destination $EnvPath -ErrorAction Stop
                    Add-HermesInstallJournal ".env backup-restored" $EnvPath
                    if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
                        throw "restored path is not a file"
                    }
                    if ((Get-FileFingerprint $EnvPath) -ne $previousFingerprint) {
                        throw "restored .env bytes changed"
                    }
                } catch {
                    $restoreErrors.Add("failed to restore backup $backup to $EnvPath`: $($_.Exception.Message)")
                }
            }
        } elseif ((-not $envExists) -and (Test-Path -LiteralPath $EnvPath)) {
            try {
                if ((Get-FileFingerprint $EnvPath) -ne $newFingerprint) {
                    throw ".env first-install destination fingerprint changed"
                }
                if ($null -ne $Safety) {
                    Invoke-InstallPathSafety $Safety $EnvPath ".env first-install cleanup"
                }
                Remove-Item -LiteralPath $EnvPath -Force -ErrorAction Stop
            } catch {
                $restoreErrors.Add("failed to remove first-install .env $EnvPath`: $($_.Exception.Message)")
            }
        }
        if ($restoreErrors.Count -gt 0) {
            throw "$originalError Rollback uncertainty: $($restoreErrors -join '; ')"
        }
        throw
    }
}

function Invoke-NativeCommand {
    param(
        [string] $FilePath,
        [string[]] $Arguments,
        [string] $WorkingDirectory
    )
    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

function Resolve-PnpmCommand {
    $cmd = Get-Command "pnpm.cmd" -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $cmd = Get-Command "pnpm" -ErrorAction Stop
    }
    return $cmd.Source
}

function Invoke-VencordQualityGates {
    param([string] $Root)
    Write-Step "Running Vencord quality gates with Windows-native pnpm"
    $pnpm = Resolve-PnpmCommand
    $commands = @(
        @{ Arguments = @("install", "--frozen-lockfile") },
        @{ Arguments = @("exec", "eslint", "src/userplugins/hermesStatus") },
        @{ Arguments = @("testTsc") },
        @{ Arguments = @("exec", "tsx", "src/userplugins/hermesStatus/tests/statusLogic.test.ts") },
        @{ Arguments = @("build") }
    )
    foreach ($command in $commands) {
        $arguments = [string[]] $command.Arguments
        $commandText = "pnpm $($arguments -join ' ')"
        if ($script:InstallExecute) {
            Invoke-NativeCommand $pnpm $arguments $Root
        } else {
            Write-Host "WhatIf: would run $commandText in $Root"
        }
    }
}

function Invoke-HermesCommands {
    param([string] $Distribution)
    if (-not [string]::IsNullOrWhiteSpace($Distribution) -and -not (Test-HermesWslDistributionName $Distribution)) {
        throw "WSL distribution names may contain only letters, numbers, dot, underscore, and hyphen."
    }
    $wsl = Resolve-HermesTrustedWslExe
    $baseArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
        $baseArgs += @("-d", $Distribution)
    }

    Write-Step "Enabling Hermes discord-status plugin"
    if ($script:InstallExecute) {
        & $wsl @baseArgs -- hermes plugins enable discord-status
        if ($LASTEXITCODE -ne 0) {
            throw "Hermes plugin enable failed with exit code $LASTEXITCODE."
        }
    } else {
        Write-Host "WhatIf: would run hermes plugins enable discord-status"
    }

    Write-Host "A gateway-hosted plugin invocation cannot restart its own gateway, but this Windows installer can restart it from outside Hermes."
    Write-Step "Restarting Hermes gateway"
    if ($script:InstallExecute) {
        & $wsl @baseArgs -- hermes gateway restart
        if ($LASTEXITCODE -ne 0) {
            throw "Hermes gateway restart failed with exit code $LASTEXITCODE."
        }
    } else {
        Write-Host "WhatIf: would run hermes gateway restart"
    }
}

function New-WindowsPathSafetyCallback {
    param(
        [string] $ApprovedRoot,
        [string] $Label
    )
    $root = Resolve-FullPath $ApprovedRoot
    return @{
        Type = "Windows"
        ApprovedRoot = $root
        Label = $Label
    }
}

function New-WslPathSafetyCallback {
    param(
        [string] $WslDistribution,
        [string] $ApprovedLinuxRoot,
        [string] $Label,
        [ValidateSet("Any", "File", "Directory")]
        [string] $ExpectedKind = "Any"
    )
    return @{
        Type = "Wsl"
        Distribution = $WslDistribution
        ApprovedLinuxRoot = $ApprovedLinuxRoot
        Label = $Label
        ExpectedKind = $ExpectedKind
        RejectTreeSymlinks = ($ExpectedKind -eq "Directory")
    }
}

function Invoke-HermesOperationSafety {
    param(
        [hashtable] $Operation,
        [string] $Path,
        [string] $Description
    )
    if ($null -eq $Operation -or -not $Operation.ContainsKey("Safety") -or $null -eq $Operation.Safety) {
        return
    }
    $safety = $Operation.Safety
    if ($safety -is [scriptblock]) {
        & $safety $Path $Description
        return
    }
    if ($safety -is [hashtable]) {
        if ($safety.Type -eq "Windows") {
            Assert-WindowsPathNoReparsePoint $Path $safety.ApprovedRoot "$($safety.Label) $Description"
            if (Test-Path -LiteralPath $Path -PathType Container) {
                Assert-PathTreeNoReparsePoint $Path "$($safety.Label) $Description"
            }
            return
        }
        if ($safety.Type -eq "Wsl") {
            $parsed = ConvertFrom-HermesWslUncPath -Path $Path -WslDistribution $safety.Distribution
            $rejectTreeSymlinks = $false
            if ($safety.ContainsKey("RejectTreeSymlinks") -and $safety.RejectTreeSymlinks) {
                $rejectTreeSymlinks = Test-Path -LiteralPath $Path -PathType Container
            }
            Resolve-HermesWslSafePath -ParsedPath $parsed -ApprovedLinuxRoot $safety.ApprovedLinuxRoot -RejectTreeSymlinks:$rejectTreeSymlinks -ExpectedKind $safety.ExpectedKind | Out-Null
            return
        }
    }
    throw "Unknown install operation safety descriptor."
}

$script:HermesInstallerMutex = New-Object System.Threading.Mutex($false, "Local\HermesDiscordStatusInstaller")
$script:HermesInstallerMutexAcquired = $false
try {
    try {
        $script:HermesInstallerMutexAcquired = $script:HermesInstallerMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $script:HermesInstallerMutexAcquired = $true
        Write-Warning "Recovered an abandoned installer mutex from a previously terminated installer process."
    }
    if (-not $script:HermesInstallerMutexAcquired) {
        throw "Another Hermes Discord Status installer instance is already running. Retry after it exits."
    }

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-FullPath $RepoRoot
$VencordRoot = Resolve-FullPath $VencordPath

$explicitHermesHome = -not [string]::IsNullOrWhiteSpace($HermesHome)
$EffectiveWslDistribution = $WslDistribution
if ($explicitHermesHome) {
    $explicitHermesWsl = Get-HermesWslUncPathInfo -Path $HermesHome -WslDistribution $WslDistribution
    if ($null -eq $explicitHermesWsl -and -not $SkipHermesCommands) {
        throw "Explicit non-WSL Windows path -HermesHome is supported only with -SkipHermesCommands; otherwise Hermes CLI operations target WSL while files are installed elsewhere."
    }
}

$HermesRoot = Resolve-HermesHome -ExplicitHome $HermesHome -Distribution $WslDistribution
$resolvedHermesWsl = Get-HermesWslUncPathInfo -Path $HermesRoot -WslDistribution $WslDistribution
if ($null -ne $resolvedHermesWsl) {
    $EffectiveWslDistribution = $resolvedHermesWsl.Distribution
} elseif ((-not $explicitHermesHome) -and (-not $WhatIfPreference)) {
    throw "WSL returned a non-canonical Hermes home path. Expected a \\wsl.localhost or \\wsl$ UNC path."
}

$VencordUserplugins = Join-Path $VencordRoot "src/userplugins"
$VencordDestination = Join-Path $VencordUserplugins $PluginName
$HermesPlugins = Join-Path $HermesRoot "plugins"
$HermesDestination = Join-Path $HermesPlugins $BridgeName
$EnvPath = Join-Path $HermesRoot ".env"
$EnvWslInfo = $null
$HermesRootWslInfo = $null
if ($null -ne $resolvedHermesWsl) {
    $EnvWslInfo = ConvertFrom-HermesWslUncPath -Path $EnvPath -WslDistribution $EffectiveWslDistribution
    $HermesRootWslInfo = ConvertFrom-HermesWslUncPath -Path $HermesRoot -WslDistribution $EffectiveWslDistribution
}

Write-Step "Validating source project and destinations"
Assert-SourceProject $RepoRoot
Assert-VencordCheckout $VencordRoot
Assert-WindowsPathNoReparsePoint $RepoRoot $RepoRoot "Repository root"
Assert-WindowsPathNoReparsePoint (Join-Path $RepoRoot "bridge") (Join-Path $RepoRoot "bridge") "Hermes bridge source"
Assert-WindowsPathNoReparsePoint (Join-Path $RepoRoot "vencord-userplugin/hermesStatus") (Join-Path $RepoRoot "vencord-userplugin/hermesStatus") "Vencord userplugin source"
Assert-PathTreeNoReparsePoint (Join-Path $RepoRoot "bridge") "Hermes bridge source"
Assert-PathTreeNoReparsePoint (Join-Path $RepoRoot "vencord-userplugin/hermesStatus") "Vencord userplugin source"
Assert-WindowsPathNoReparsePoint $VencordRoot $VencordRoot "Vencord checkout"
Assert-WindowsPathNoReparsePoint $VencordUserplugins $VencordRoot "Vencord src/userplugins"
Assert-NoPathOverlap @(
    @{ Label = "repository root"; Path = $RepoRoot },
    @{ Label = "Vencord root"; Path = $VencordRoot },
    @{ Label = "Hermes root"; Path = $HermesRoot }
)
Assert-NoPathOverlap @(
    @{ Label = "Vencord source"; Path = (Join-Path $RepoRoot "vencord-userplugin/hermesStatus") },
    @{ Label = "Hermes source"; Path = (Join-Path $RepoRoot "bridge") },
    @{ Label = "Vencord destination"; Path = $VencordDestination },
    @{ Label = "Hermes destination"; Path = $HermesDestination }
)
Assert-ManagedDirectoryOrAbsent $VencordDestination "Vencord plugin destination"
if (Test-Path -LiteralPath $HermesRoot) {
    Assert-NoReparsePoint $HermesRoot "Hermes home"
}
Assert-ManagedDirectoryOrAbsent $HermesDestination "Hermes plugin destination"
Assert-RegularFileOrAbsent $EnvPath "Hermes .env"
if (-not (Test-PathWithin $VencordDestination $VencordUserplugins)) {
    throw "Resolved Vencord destination escapes src/userplugins: $VencordDestination"
}
if (-not (Test-PathWithin $HermesDestination $HermesPlugins)) {
    throw "Resolved Hermes destination escapes Hermes plugins directory: $HermesDestination"
}
Assert-WindowsPathNoReparsePoint $VencordDestination $VencordUserplugins "Vencord plugin destination"
if ($null -ne $resolvedHermesWsl -and -not $WhatIfPreference) {
    Resolve-HermesWslSafePath -ParsedPath $HermesRootWslInfo -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath -ExpectedKind Directory | Out-Null
    Resolve-HermesWslSafePath -ParsedPath (ConvertFrom-HermesWslUncPath -Path $HermesDestination -WslDistribution $EffectiveWslDistribution) -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath -ExpectedKind Directory | Out-Null
    Resolve-HermesWslSafePath -ParsedPath $EnvWslInfo -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath -ExpectedKind File | Out-Null
} else {
    Assert-WindowsPathNoReparsePoint $HermesRoot $HermesRoot "Hermes home"
    Assert-WindowsPathNoReparsePoint $HermesDestination $HermesPlugins "Hermes plugin destination"
    Assert-WindowsPathNoReparsePoint $EnvPath $HermesRoot "Hermes .env"
}

$vencordSafety = New-WindowsPathSafetyCallback $VencordUserplugins "Vencord userplugin"
$hermesSafety = $null
$envSafety = $null
if ($null -ne $resolvedHermesWsl) {
    $hermesSafety = New-WslPathSafetyCallback $EffectiveWslDistribution $HermesRootWslInfo.LinuxPath "Hermes bridge" "Directory"
    $envSafety = New-WslPathSafetyCallback $EffectiveWslDistribution $HermesRootWslInfo.LinuxPath "Hermes .env" "File"
} else {
    $hermesSafety = New-WindowsPathSafetyCallback $HermesPlugins "Hermes bridge"
    $envSafety = New-WindowsPathSafetyCallback $HermesRoot "Hermes .env"
}

$script:InstallExecute = $false
if ($PSCmdlet.ShouldProcess("Vencord $VencordDestination and Hermes $HermesDestination", "Install Hermes Discord Status")) {
    $script:InstallExecute = $true
} elseif ($WhatIfPreference) {
    $script:InstallExecute = $false
} else {
    throw "Installation declined before making changes."
}

$operations = @()
$tokenResult = $null
$managedCommitted = $false
try {
    Write-Step "Installing Vencord userplugin"
    Assert-WindowsPathNoReparsePoint $VencordDestination $VencordUserplugins "Vencord plugin destination"
    $operations += Start-ManagedDirectoryReplacement (Join-Path $RepoRoot "vencord-userplugin/hermesStatus") $VencordDestination "Vencord userplugin" $vencordSafety

    Write-Step "Installing Hermes bridge plugin"
    if ($null -ne $resolvedHermesWsl -and $script:InstallExecute) {
        Resolve-HermesWslSafePath -ParsedPath (ConvertFrom-HermesWslUncPath -Path $HermesDestination -WslDistribution $EffectiveWslDistribution) -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath -ExpectedKind Directory | Out-Null
    } else {
        Assert-WindowsPathNoReparsePoint $HermesDestination $HermesPlugins "Hermes plugin destination"
    }
    $operations += Start-ManagedDirectoryReplacement (Join-Path $RepoRoot "bridge") $HermesDestination "Hermes bridge" $hermesSafety

    Write-Step "Updating Hermes bearer token"
    if ($null -ne $resolvedHermesWsl -and $script:InstallExecute) {
        Resolve-HermesWslSafePath -ParsedPath $EnvWslInfo -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath -ExpectedKind File | Out-Null
    } else {
        Assert-WindowsPathNoReparsePoint $EnvPath $HermesRoot "Hermes .env"
    }
    $tokenResult = Start-HermesTokenUpdate $EnvPath $envSafety
    $operations += $tokenResult

    if ($null -ne $EnvWslInfo -and ($tokenResult.Written -or $WhatIfPreference)) {
        Write-Step "Hardening Hermes bearer token file permissions"
        if ($script:InstallExecute) {
            Resolve-HermesWslSafePath -ParsedPath $EnvWslInfo -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath -ExpectedKind File | Out-Null
            Write-Host "Running chmod 600 for Hermes .env in WSL distro $($EnvWslInfo.Distribution)"
            Invoke-HermesWslChmod600 -ParsedPath $EnvWslInfo -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath
        } else {
            Invoke-HermesWslChmod600 -ParsedPath $EnvWslInfo -ApprovedLinuxRoot $HermesRootWslInfo.LinuxPath -WhatIf
        }
    }

    if ($SkipVencordBuild) {
        Write-Host "Skipped Vencord pnpm quality gates because -SkipVencordBuild was supplied."
    } else {
        Invoke-VencordQualityGates $VencordRoot
    }

    for ($i = 0; $i -lt $operations.Count; $i++) {
        Complete-InstallOperation $operations[$i]
    }
    $managedCommitted = $true

    if ($SkipHermesCommands) {
        Write-Host "Skipped Hermes CLI enable/restart because -SkipHermesCommands was supplied."
    } else {
        try {
            Invoke-HermesCommands -Distribution $EffectiveWslDistribution
        } catch {
            Write-Host "Managed files were installed and verified, but Hermes command failed. Rerun: wsl.exe -d $EffectiveWslDistribution -- hermes plugins enable discord-status; wsl.exe -d $EffectiveWslDistribution -- hermes gateway restart"
            Write-Error "Hermes command failed after managed file commit: $($_.Exception.Message)"
            throw
        }
    }
} catch {
    $originalError = $_.Exception.Message
    if (-not $managedCommitted) {
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        for ($i = $operations.Count - 1; $i -ge 0; $i--) {
            try {
                Undo-InstallOperation $operations[$i]
            } catch {
                $rollbackErrors.Add($_.Exception.Message)
            }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "$originalError Rollback failures: $($rollbackErrors -join '; ')"
        }
    }
    throw
}

Write-Host ""
if ($script:InstallExecute) {
    Write-Host "Install summary"
} else {
    Write-Host "Planned install summary"
}
Write-Host "  Vencord plugin: $VencordDestination"
Write-Host "  Hermes bridge:  $HermesDestination"
Write-Host "  Token file:     $EnvPath"
if (-not $script:InstallExecute) {
    if ($tokenResult.ContainsKey("PlanUnknown") -and $tokenResult.PlanUnknown) {
        Write-Host "  Token:          would inspect existing token and create one only if missing"
    } elseif ($tokenResult.Created) {
        Write-Host "  Token:          would be created"
    } else {
        Write-Host "  Token:          would preserve existing token"
    }
} elseif ($tokenResult.Created) {
    Write-Host "  Token:          created"
} else {
    Write-Host "  Token:          existing token preserved"
}
if ($ShowToken -and $script:InstallExecute) {
    Write-Host "  Token value:    $($tokenResult.Token)"
} elseif ($ShowToken) {
    Write-Host "  Token value:    not generated during WhatIf; run the installer to create or preserve the real value"
} else {
    Write-Host "  Token value:    hidden; rerun with -ShowToken or read $TokenKey from $EnvPath"
}
Write-Host ""
Write-Host "Discord/Vencord injection is intentionally separate. After a successful build, explicitly run Vencord's installer in development-install mode and restart Discord."
} finally {
    if ($script:HermesInstallerMutexAcquired) {
        $script:HermesInstallerMutex.ReleaseMutex() | Out-Null
    }
    if ($null -ne $script:HermesInstallerMutex) {
        $script:HermesInstallerMutex.Dispose()
    }
}
