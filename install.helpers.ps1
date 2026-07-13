Set-StrictMode -Version 2.0

function Test-HermesWslDistributionName {
    param([string] $Distribution)

    return -not [string]::IsNullOrWhiteSpace($Distribution) -and
        $Distribution -match "^[A-Za-z0-9._-]+$" -and
        $Distribution -ne "." -and
        $Distribution -ne ".."
}

function Get-HermesWslUncPathInfo {
    param(
        [string] $Path,
        [string] $WslDistribution
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "WSL UNC path is empty."
    }

    if ($Path -notmatch "^\\\\([^\\]+)\\(.*)$") {
        return $null
    }

    $hostName = $Matches[1]
    $afterHost = $Matches[2]
    if ($hostName -ne "wsl.localhost" -and $hostName -ne "wsl$") {
        if ($hostName -like "wsl*") {
            throw "Only canonical WSL UNC hosts \\wsl.localhost and \\wsl$ are supported."
        }
        return $null
    }

    if ($afterHost -notmatch "^([^\\]+)\\(.+)$") {
        throw "WSL UNC path must include a distro and an absolute Linux path."
    }

    $distribution = $Matches[1]
    $relativePath = $Matches[2]
    if (-not (Test-HermesWslDistributionName $distribution)) {
        throw "WSL distribution names may contain only letters, numbers, dot, underscore, and hyphen."
    }
    if (-not [string]::IsNullOrWhiteSpace($WslDistribution) -and
        -not $distribution.Equals($WslDistribution, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Supplied -WslDistribution '$WslDistribution' does not match HermesHome WSL distro '$distribution'."
    }

    $segments = @($relativePath -split "\\", -1)
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq "." -or $segment -eq "..") {
            throw "WSL UNC path must not contain empty, dot, or dot-dot segments."
        }
        if ($segment.Contains("/")) {
            throw "WSL UNC path segments must not contain forward slashes."
        }
    }

    return [pscustomobject]@{
        Distribution = $distribution
        LinuxPath = "/" + ($segments -join "/")
    }
}

function ConvertFrom-HermesWslUncPath {
    param(
        [string] $Path,
        [string] $WslDistribution
    )

    $info = Get-HermesWslUncPathInfo -Path $Path -WslDistribution $WslDistribution
    if ($null -eq $info) {
        throw "Path is not a canonical WSL UNC path."
    }
    return $info
}

function Resolve-HermesTrustedWslExe {
    # Dependency injection is available only to the repository's disposable-path test harness.
    $testOverride = Get-Variable -Name HermesInstallerTestWslExecutable -Scope Script -ErrorAction SilentlyContinue
    if ($env:HERMES_INSTALLER_TESTING -eq "1" -and $null -ne $testOverride -and -not [string]::IsNullOrWhiteSpace([string] $testOverride.Value)) {
        $candidate = [System.IO.Path]::GetFullPath([string] $testOverride.Value)
        $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\", "/")
        if ($candidate -ne $tempRoot -and -not $candidate.StartsWith($tempRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Test WSL executable override must remain under the temporary directory."
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Test WSL executable override was not found: $candidate"
        }
        $testItem = Get-Item -LiteralPath $candidate -Force
        if (($testItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Test WSL executable override must not be a reparse point."
        }
        return $testItem.FullName
    }

    $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) {
        throw "Could not resolve the trusted Windows system directory."
    }
    $trusted = Join-Path $systemDirectory "wsl.exe"
    if (-not (Test-Path -LiteralPath $trusted -PathType Leaf)) {
        throw "Trusted WSL executable was not found at $trusted."
    }
    $item = Get-Item -LiteralPath $trusted -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Trusted WSL executable must not be a reparse point: $trusted"
    }
    return $item.FullName
}

function Resolve-HermesWslSafePath {
    param(
        [psobject] $ParsedPath,
        [string] $ApprovedLinuxRoot,
        [switch] $RejectTreeSymlinks,
        [ValidateSet("Any", "File", "Directory")]
        [string] $ExpectedKind = "Any"
    )

    $python = @'
import json
import os
import stat
import sys

path = sys.argv[1]
root = sys.argv[2]
reject_tree_symlinks = sys.argv[3] == '1'
expected_kind = sys.argv[4]

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(2)

if not path.startswith('/') or not root.startswith('/'):
    fail('WSL paths must be absolute')

parts = [part for part in path.split('/') if part]
current = '/'
for part in parts:
    current = os.path.join(current, part)
    try:
        mode = os.lstat(current).st_mode
    except FileNotFoundError:
        break
    if stat.S_ISLNK(mode):
        fail('WSL path component is a symlink: ' + current)

real_path = os.path.realpath(path)
real_root = os.path.realpath(root)
if real_path != real_root and not real_path.startswith(real_root.rstrip('/') + '/'):
    fail('WSL path escapes approved Hermes home')

if os.path.lexists(path):
    final_mode = os.lstat(path).st_mode
    if expected_kind == 'File' and not stat.S_ISREG(final_mode):
        fail('WSL path is not a regular file')
    if expected_kind == 'Directory' and not stat.S_ISDIR(final_mode):
        fail('WSL path is not a directory')

if reject_tree_symlinks and os.path.isdir(path):
    for walk_root, dir_names, file_names in os.walk(path, followlinks=False):
        for name in dir_names:
            candidate = os.path.join(walk_root, name)
            candidate_mode = os.lstat(candidate).st_mode
            if stat.S_ISLNK(candidate_mode):
                fail('WSL managed tree contains a symlink: ' + candidate)
            if not stat.S_ISDIR(candidate_mode):
                fail('WSL managed tree contains a non-directory entry in its directory set: ' + candidate)
        for name in file_names:
            candidate = os.path.join(walk_root, name)
            candidate_mode = os.lstat(candidate).st_mode
            if stat.S_ISLNK(candidate_mode):
                fail('WSL managed tree contains a symlink: ' + candidate)
            if not stat.S_ISREG(candidate_mode):
                fail('WSL managed tree contains a non-regular file: ' + candidate)

print(json.dumps({'real_path': real_path, 'real_root': real_root}))
'@

    $wsl = Resolve-HermesTrustedWslExe
    $rejectTree = "0"
    if ($RejectTreeSymlinks) {
        $rejectTree = "1"
    }
    $arguments = @("-d", [string] $ParsedPath.Distribution, "--", "/usr/bin/python3", "-c", $python, [string] $ParsedPath.LinuxPath, [string] $ApprovedLinuxRoot, $rejectTree, $ExpectedKind)
    $output = & $wsl @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "WSL path safety validation failed for $($ParsedPath.LinuxPath) in distro $($ParsedPath.Distribution)."
    }
    return ($output | Out-String).Trim()
}

function Invoke-HermesWslChmod600 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $ParsedPath,

        [Parameter(Mandatory = $true)]
        [string] $ApprovedLinuxRoot,

        [switch] $WhatIf
    )

    if ($WhatIf) {
        Write-Host "WhatIf: would set mode 0600 on $($ParsedPath.LinuxPath) in WSL distro $($ParsedPath.Distribution)"
        return
    }

    $python = @'
import os
import stat
import sys

path = sys.argv[1]
root = sys.argv[2]

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(2)

if not path.startswith('/') or not root.startswith('/'):
    fail('WSL paths must be absolute')

parts = [part for part in path.split('/') if part]
current = '/'
for part in parts[:-1]:
    current = os.path.join(current, part)
    try:
        mode = os.lstat(current).st_mode
    except FileNotFoundError:
        fail('WSL path parent does not exist: ' + current)
    if stat.S_ISLNK(mode):
        fail('WSL path component is a symlink: ' + current)

real_path = os.path.realpath(path)
real_root = os.path.realpath(root)
if real_path != real_root and not real_path.startswith(real_root.rstrip('/') + '/'):
    fail('WSL path escapes approved Hermes home')

flags = os.O_RDONLY
if hasattr(os, 'O_NOFOLLOW'):
    flags |= os.O_NOFOLLOW

try:
    fd = os.open(path, flags)
except OSError as exc:
    fail('failed to open WSL file without following symlinks: ' + str(exc))

try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        fail('WSL path is not a regular file')
    os.fchmod(fd, 0o600)
    after = os.fstat(fd)
    if stat.S_IMODE(after.st_mode) != 0o600:
        fail('WSL file mode did not become 0600')
finally:
    os.close(fd)
'@
    $wsl = Resolve-HermesTrustedWslExe
    $arguments = @("-d", [string] $ParsedPath.Distribution, "--", "/usr/bin/python3", "-c", $python, [string] $ParsedPath.LinuxPath, [string] $ApprovedLinuxRoot)
    & $wsl @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set mode 0600 on $($ParsedPath.LinuxPath) in WSL distro $($ParsedPath.Distribution); wsl.exe exited with $LASTEXITCODE."
    }
}

function Get-HermesFileFingerprint {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
}

function Get-HermesDirectoryFingerprint {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }
    $rootFull = [System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $items = @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    $entries = @($items | Sort-Object FullName | ForEach-Object {
        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Directory fingerprint refused reparse entry: $($_.FullName)"
        }
        if ($_.FullName.Length -eq $rootFull.Length) {
            $relative = "."
        } else {
            $relative = $_.FullName.Substring($rootFull.Length + 1).Replace("\", "/")
        }
        if ($_.PSIsContainer) {
            "D:$relative"
        } else {
            "F:$relative=$([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($_.FullName)))"
        }
    })
    return ($entries -join "`n")
}

function Invoke-HermesOperationSafety {
    param(
        [hashtable] $Operation,
        [string] $Path,
        [string] $Description
    )
    if ($null -ne $Operation -and $Operation.ContainsKey("Safety") -and $null -ne $Operation.Safety) {
        & $Operation.Safety $Path $Description
    }
}

function Get-HermesOperationFingerprint {
    param(
        [string] $Kind,
        [string] $Path
    )
    if ($Kind -eq "Directory") {
        return Get-HermesDirectoryFingerprint $Path
    }
    if ($Kind -eq "File") {
        return Get-HermesFileFingerprint $Path
    }
    return $null
}

function Complete-HermesInstallOperation {
    [CmdletBinding()]
    param([hashtable] $Operation)

    if ($null -eq $Operation -or -not $Operation.Applied) {
        return
    }

    $isDirectory = $Operation.Kind -eq "Directory"
    $isFile = $Operation.Kind -eq "File"
    if ((-not $isDirectory) -and (-not $isFile)) {
        return
    }
    if (-not $Operation.HadDestination -or -not (Test-Path -LiteralPath $Operation.Backup)) {
        return
    }

    try {
        Invoke-HermesOperationSafety $Operation $Operation.Backup "backup cleanup"
        if ($Operation.ContainsKey("PreviousFingerprint")) {
            $actualPrevious = Get-HermesOperationFingerprint $Operation.Kind $Operation.Backup
            if ($actualPrevious -ne $Operation.PreviousFingerprint) {
                throw "previous backup fingerprint changed"
            }
        }
        Invoke-HermesOperationSafety $Operation $Operation.Backup "backup cleanup final"
        if ($isDirectory) {
            Remove-Item -LiteralPath $Operation.Backup -Recurse -Force -ErrorAction Stop
        } else {
            Remove-Item -LiteralPath $Operation.Backup -Force -ErrorAction Stop
        }
    } catch {
        $label = ".env"
        if ($isDirectory) {
            $label = $Operation.Label
        }
        Write-Warning "Install succeeded, but the previous $label backup could not be removed: $($Operation.Backup). $($_.Exception.Message) Remove it manually after checking that no process is using it."
    }
}
