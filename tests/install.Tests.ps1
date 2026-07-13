Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$InstallScript = Join-Path $RepoRoot "install.ps1"
$InstallHelpers = Join-Path $RepoRoot "install.helpers.ps1"
if (Test-Path -LiteralPath $InstallHelpers -PathType Leaf) {
    . $InstallHelpers
}
$script:Failures = 0

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [string] $Message
    )
    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Get-RelativeFileList {
    param([string] $Root)
    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object {
            $_.FullName -notmatch "\\__pycache__\\" -and
            $_.Extension -ne ".pyc"
        } |
        ForEach-Object {
            $_.FullName.Substring($rootFull.Length + 1).Replace("\", "/")
        } |
        Sort-Object)
}

function Assert-FileTreesEqual {
    param(
        [string] $ExpectedRoot,
        [string] $ActualRoot,
        [string] $Message
    )

    $expected = @(Get-RelativeFileList $ExpectedRoot)
    $actual = @(Get-RelativeFileList $ActualRoot)
    Assert-Equal ($expected -join "|") ($actual -join "|") $Message

    foreach ($relative in $expected) {
        $expectedPath = Join-Path $ExpectedRoot ($relative -replace "/", "\")
        $actualPath = Join-Path $ActualRoot ($relative -replace "/", "\")
        $expectedBytes = [System.IO.File]::ReadAllBytes($expectedPath)
        $actualBytes = [System.IO.File]::ReadAllBytes($actualPath)
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($expectedBytes, $actualBytes)) "File content differs for $relative."
    }
}

function Assert-DirectoryClean {
    param(
        [string] $Root,
        [string] $Message
    )
    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $debris = @(Get-ChildItem -LiteralPath $Root -Force |
        Where-Object { $_.Name -match "\.(stage|backup)\.[0-9a-f]{32}$" })
    Assert-Equal 0 $debris.Count $Message
}

function Assert-NoBom {
    param(
        [string] $Path,
        [string] $Message
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Assert-True (-not $hasBom) $Message
}

function New-TestJunction {
    param(
        [string] $Path,
        [string] $Target
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path), $Target | Out-Null
    $cmd = Get-Command "cmd.exe" -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $false
    }
    & $cmd.Source /c "mklink /J `"$Path`" `"$Target`"" | Out-Null
    return ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Path))
}

function New-FakeVencord {
    param([string] $Root)
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "src/userplugins") | Out-Null
    Set-Content -LiteralPath (Join-Path $Root "package.json") -Value '{"packageManager":"pnpm@11.9.0"}' -Encoding UTF8
}

function New-FakeCommandDirectory {
    param(
        [string] $Root,
        [string] $PnpmExitCode,
        [string] $WslExitCode
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $log = Join-Path $Root "commands.log"
    $pnpm = Join-Path $Root "pnpm.cmd"
    $wsl = Join-Path $Root "wsl.exe"

    $pnpmScript = @"
@echo off
echo pnpm %*>>"$log"
exit /b $PnpmExitCode
"@
    $wslScript = @"
@echo off
echo wsl %*>>"$log"
exit /b $WslExitCode
"@
    Set-Content -LiteralPath $pnpm -Value $pnpmScript -Encoding ASCII
    Set-Content -LiteralPath $wsl -Value $wslScript -Encoding ASCII
    $systemRoot = Join-Path $Root "Windows"
    $system32 = Join-Path $systemRoot "System32"
    New-Item -ItemType Directory -Force -Path $system32 | Out-Null
    Copy-Item -LiteralPath $wsl -Destination (Join-Path $system32 "wsl.exe") -Force

    return @{
        Directory = $Root
        Log = $log
        SystemRoot = $systemRoot
    }
}

function New-FakeWslOnlyDirectory {
    param(
        [string] $Root,
        [int[]] $ExitCodes
    )

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $log = Join-Path $Root "commands.log"
    $state = Join-Path $Root "wsl-state.txt"
    Set-Content -LiteralPath $state -Value "0" -Encoding ASCII
    $exitList = ($ExitCodes | ForEach-Object { $_.ToString() }) -join ","
    $wsl = Join-Path $Root "wsl.exe"
    $className = "FakeWsl" + [guid]::NewGuid().ToString("N")
    $sourceTemplate = @'
using System;
using System.IO;

public static class __CLASS_NAME__
{
    public static int Main(string[] args)
    {
        string log = Environment.GetEnvironmentVariable("HERMES_FAKE_WSL_LOG");
        string state = Environment.GetEnvironmentVariable("HERMES_FAKE_WSL_STATE");
        string exitCodesText = Environment.GetEnvironmentVariable("HERMES_FAKE_WSL_EXIT_CODES") ?? "0";
        File.AppendAllText(log, "wsl " + string.Join(" ", args) + Environment.NewLine);
        string failChmodText = Environment.GetEnvironmentVariable("HERMES_FAKE_WSL_FAIL_CHMOD");
        if (!string.IsNullOrWhiteSpace(failChmodText) && Array.Exists(args, value => value.Contains("fchmod"))) {
            int failChmodCode = 1;
            int.TryParse(failChmodText, out failChmodCode);
            return failChmodCode;
        }
        string failHermesText = Environment.GetEnvironmentVariable("HERMES_FAKE_WSL_FAIL_HERMES");
        if (!string.IsNullOrWhiteSpace(failHermesText) && Array.IndexOf(args, "hermes") >= 0) {
            int failHermesCode = 1;
            int.TryParse(failHermesText, out failHermesCode);
            return failHermesCode;
        }

        int index = 0;
        if (File.Exists(state)) {
            int.TryParse(File.ReadAllText(state).Trim(), out index);
        }
        File.WriteAllText(state, (index + 1).ToString());

        string[] parts = exitCodesText.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
        int code = 0;
        if (index < parts.Length && int.TryParse(parts[index], out code)) {
            return code;
        }
        return 0;
    }
}
'@
    $source = $sourceTemplate.Replace("__CLASS_NAME__", $className)
    Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $wsl -OutputType ConsoleApplication
    $systemRoot = Join-Path $Root "Windows"
    $system32 = Join-Path $systemRoot "System32"
    New-Item -ItemType Directory -Force -Path $system32 | Out-Null
    Copy-Item -LiteralPath $wsl -Destination (Join-Path $system32 "wsl.exe") -Force

    return @{
        Directory = $Root
        Log = $log
        State = $state
        ExitCodes = $exitList
        SystemRoot = $systemRoot
    }
}

function Import-InstallerHelpers {
    if (-not (Test-Path -LiteralPath $InstallHelpers -PathType Leaf)) {
        throw "install.helpers.ps1 is missing."
    }
}

function Get-TestWslDistribution {
    $wsl = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
    if ($null -eq $wsl) {
        return $null
    }

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $wsl.Source -l -q 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        foreach ($line in $output) {
            $clean = ([string] $line).Replace(([char] 0).ToString(), "").Trim()
            if (-not [string]::IsNullOrWhiteSpace($clean) -and (Test-HermesWslDistributionName $clean)) {
                return $clean
            }
        }
        return $null
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

function New-TestWslTempDirectory {
    param([string] $Distribution)

    $wsl = (Get-Command "wsl.exe" -ErrorAction Stop).Source
    $linuxOutput = & $wsl -d $Distribution -- mktemp -d /tmp/hermes-install-test.XXXXXX
    $linuxExitCode = $LASTEXITCODE
    $linuxPath = ([string] (@($linuxOutput) | Select-Object -First 1)).Trim()
    if ($linuxExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($linuxPath)) {
        throw "Failed to create disposable WSL temp directory."
    }
    $windowsOutput = & $wsl -d $Distribution -- wslpath -w $linuxPath
    $windowsExitCode = $LASTEXITCODE
    $windowsPath = ([string] (@($windowsOutput) | Select-Object -First 1)).Trim()
    if ($windowsExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($windowsPath)) {
        & $wsl -d $Distribution -- rm -rf $linuxPath | Out-Null
        throw "Failed to convert disposable WSL temp directory to UNC."
    }
    return @{
        Distribution = $Distribution
        LinuxPath = $linuxPath
        WindowsPath = $windowsPath
    }
}

function Remove-TestWslTempDirectory {
    param([hashtable] $TempDirectory)

    if ($null -eq $TempDirectory) {
        return
    }
    $wsl = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
    if ($null -ne $wsl) {
        & $wsl.Source -d $TempDirectory.Distribution -- rm -rf $TempDirectory.LinuxPath | Out-Null
    }
}

function Invoke-Installer {
    param(
        [string] $VencordPath,
        [string] $HermesHome,
        [switch] $WhatIf,
        [switch] $RunVencordBuild,
        [switch] $RunHermesCommands,
        [string] $CommandDirectory,
        [switch] $OmitHermesHome,
        [switch] $ShowToken
    )

    $scriptArguments = @(
        "-VencordPath", $VencordPath
    )
    if (-not $OmitHermesHome) {
        $scriptArguments += @("-HermesHome", $HermesHome)
    }
    if (-not $RunVencordBuild) {
        $scriptArguments += "-SkipVencordBuild"
    }
    if (-not $RunHermesCommands) {
        $scriptArguments += "-SkipHermesCommands"
    }
    if ($WhatIf) {
        $scriptArguments += "-WhatIf"
    }
    if ($ShowToken) {
        $scriptArguments += "-ShowToken"
    }

    $oldPath = $env:PATH
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $fakeSystemRoot = $null
        if (-not [string]::IsNullOrWhiteSpace($CommandDirectory)) {
            $env:PATH = "$CommandDirectory;$oldPath"
            $fakeSystemRoot = Join-Path $CommandDirectory "Windows"
        }
        $ErrorActionPreference = "Continue"
        $needsFakeTrustedWsl = ($RunHermesCommands -or ((-not [string]::IsNullOrWhiteSpace($HermesHome)) -and $HermesHome.StartsWith("\\wsl", [System.StringComparison]::OrdinalIgnoreCase)))
        if ($needsFakeTrustedWsl -and -not [string]::IsNullOrWhiteSpace($fakeSystemRoot) -and (Test-Path -LiteralPath (Join-Path $fakeSystemRoot "System32\wsl.exe") -PathType Leaf)) {
            $quote = {
                param([string] $Value)
                "'" + $Value.Replace("'", "''") + "'"
            }
            $quotedArgs = @($scriptArguments | ForEach-Object {
                $argument = [string] $_
                if ($argument.StartsWith("-")) {
                    $argument
                } else {
                    & $quote $argument
                }
            })
            $fakeWsl = Join-Path $fakeSystemRoot "System32\wsl.exe"
            $command = "`$env:HERMES_INSTALLER_TESTING = '1'; `$script:HermesInstallerTestWslExecutable = $(& $quote $fakeWsl); . $(& $quote $InstallScript) $($quotedArgs -join ' ')"
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1
        } else {
            $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $InstallScript) + $scriptArguments
            $output = & powershell.exe @arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
        return @{
            ExitCode = $exitCode
            Output = ($output | Out-String)
        }
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        $env:PATH = $oldPath
    }
}

function Invoke-Test {
    param(
        [string] $Name,
        [scriptblock] $Body
    )
    Write-Host "RUN $Name"
    try {
        & $Body
        Write-Host "PASS $Name"
    } catch {
        $script:Failures += 1
        Write-Host "FAIL $Name"
        Write-Host $_.Exception.Message
    }
}

Invoke-Test "First install copies managed files and creates hidden strong token" {
    Assert-True (Test-Path -LiteralPath $InstallScript) "install.ps1 is missing."

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        Set-Content -LiteralPath (Join-Path $hermes ".env") -Value "KEEP_ME=1`r`n" -Encoding UTF8

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-Equal 0 $result.ExitCode $result.Output

        Assert-FileTreesEqual (Join-Path $RepoRoot "vencord-userplugin/hermesStatus") (Join-Path $vencord "src/userplugins/hermesStatus") "Vencord plugin files were not copied exactly."
        Assert-FileTreesEqual (Join-Path $RepoRoot "bridge") (Join-Path $hermes "plugins/discord-status") "Hermes bridge files were not copied exactly."

        $envText = Get-Content -LiteralPath (Join-Path $hermes ".env") -Raw
        Assert-True ($envText -match "(?m)^KEEP_ME=1\r?$") "Unrelated .env entry was not preserved."
        $tokenMatches = [regex]::Matches($envText, "(?m)^HERMES_DISCORD_STATUS_TOKEN=(.+?)\r?$")
        Assert-Equal 1 $tokenMatches.Count "Expected exactly one token line."
        $token = $tokenMatches[0].Groups[1].Value
        Assert-True ($token.Length -ge 43) "Token is too short."
        Assert-True ($token -match "^[A-Za-z0-9_-]+$") "Token is not URL-safe base64."
        Assert-True (-not $result.Output.Contains($token)) "Token leaked to normal output."
        Assert-NoBom (Join-Path $hermes ".env") ".env was not written as UTF-8 without BOM."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WSL UNC parser accepts only canonical roots and produces Linux absolute path" {
    Import-InstallerHelpers

    $localhost = ConvertFrom-HermesWslUncPath "\\wsl.localhost\Ubuntu-24.04\home\mohammed\.hermes\.env"
    Assert-Equal "Ubuntu-24.04" $localhost.Distribution "Unexpected distro from wsl.localhost UNC."
    Assert-Equal "/home/mohammed/.hermes/.env" $localhost.LinuxPath "Unexpected Linux path from wsl.localhost UNC."

    $dollar = ConvertFrom-HermesWslUncPath "\\wsl$\Ubuntu_24.04\home\mohammed\.hermes\.env" -WslDistribution "ubuntu_24.04"
    Assert-Equal "Ubuntu_24.04" $dollar.Distribution "Unexpected distro from wsl$ UNC."
    Assert-Equal "/home/mohammed/.hermes/.env" $dollar.LinuxPath "Unexpected Linux path from wsl$ UNC."
}

Invoke-Test "WSL UNC parser rejects malformed roots traversal distro names and distro mismatch" {
    Import-InstallerHelpers

    $badInputs = @(
        "\\wsl.localhost\Ubuntu-24.04",
        "\\wsl.localhost\\home\mohammed\.hermes",
        "\\wsl.localhost\Ubuntu 24.04\home\mohammed\.hermes",
        "\\wsl.localhost\Ubuntu-24.04\home\..\root\.hermes",
        "\\wsl.localhost\Ubuntu-24.04\home\.\mohammed\.hermes",
        "\\wsl.example\Ubuntu-24.04\home\mohammed\.hermes",
        "\\wsl.localhost.evil\Ubuntu-24.04\home\mohammed\.hermes",
        "\\wsl$\Ubuntu-24.04\home\\mohammed\.hermes"
    )
    foreach ($inputPath in $badInputs) {
        $failed = $false
        try {
            $null = ConvertFrom-HermesWslUncPath $inputPath
        } catch {
            $failed = $true
        }
        Assert-True $failed "Malformed WSL UNC was accepted: $inputPath"
    }

    $mismatchFailed = $false
    try {
        $null = ConvertFrom-HermesWslUncPath "\\wsl.localhost\Ubuntu-24.04\home\mohammed\.hermes" -WslDistribution "Debian"
    } catch {
        $mismatchFailed = $true
    }
    Assert-True $mismatchFailed "Supplied -WslDistribution mismatch was accepted."
}

Invoke-Test "WSL safety rejects FIFO where .env must be a regular file" {
    $distribution = Get-TestWslDistribution
    if ([string]::IsNullOrWhiteSpace($distribution)) {
        Write-Host "SKIP WSL safety rejects FIFO where .env must be a regular file (no WSL distro available)"
        return
    }
    $temp = $null
    try {
        $temp = New-TestWslTempDirectory $distribution
        $fifoLinux = "$($temp.LinuxPath)/.env"
        $wsl = (Get-Command "wsl.exe" -ErrorAction Stop).Source
        & $wsl -d $distribution -- mkfifo $fifoLinux
        Assert-Equal 0 $LASTEXITCODE "Could not create disposable WSL FIFO."
        $fifoWindows = Join-Path $temp.WindowsPath ".env"
        $parsed = ConvertFrom-HermesWslUncPath -Path $fifoWindows -WslDistribution $distribution
        $failed = $false
        try {
            Resolve-HermesWslSafePath -ParsedPath $parsed -ApprovedLinuxRoot $temp.LinuxPath -ExpectedKind File | Out-Null
        } catch {
            $failed = $true
        }
        Assert-True $failed "WSL safety accepted a FIFO as the Hermes .env file."
    } finally {
        Remove-TestWslTempDirectory $temp
    }
}

Invoke-Test "WSL managed-tree safety rejects nested FIFO entries" {
    $distribution = Get-TestWslDistribution
    if ([string]::IsNullOrWhiteSpace($distribution)) {
        Write-Host "SKIP WSL managed-tree safety rejects nested FIFO entries (no WSL distro available)"
        return
    }
    $temp = $null
    try {
        $temp = New-TestWslTempDirectory $distribution
        $managedLinux = "$($temp.LinuxPath)/managed"
        $fifoLinux = "$managedLinux/nested-fifo"
        $wsl = (Get-Command "wsl.exe" -ErrorAction Stop).Source
        & $wsl -d $distribution -- mkdir -p $managedLinux
        Assert-Equal 0 $LASTEXITCODE "Could not create disposable WSL managed directory."
        & $wsl -d $distribution -- mkfifo $fifoLinux
        Assert-Equal 0 $LASTEXITCODE "Could not create disposable nested WSL FIFO."
        $managedWindows = Join-Path $temp.WindowsPath "managed"
        $parsed = ConvertFrom-HermesWslUncPath -Path $managedWindows -WslDistribution $distribution
        $failed = $false
        try {
            Resolve-HermesWslSafePath -ParsedPath $parsed -ApprovedLinuxRoot $temp.LinuxPath -ExpectedKind Directory -RejectTreeSymlinks | Out-Null
        } catch {
            $failed = $true
        }
        Assert-True $failed "WSL managed-tree safety accepted a nested FIFO."
    } finally {
        Remove-TestWslTempDirectory $temp
    }
}

Invoke-Test "Automatically resolved Hermes home is revalidated as WSL UNC" {
    $installerText = Get-Content -LiteralPath $InstallScript -Raw
    Assert-True ($installerText -match 'Get-HermesWslUncPathInfo\s+-Path\s+\$HermesRoot') "Automatically resolved Hermes home is not parsed for distro inference and chmod hardening."
}

Invoke-Test "Directory fingerprint includes empty directories and root entry" {
    Import-InstallerHelpers

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $tree = Join-Path $root "tree"
        New-Item -ItemType Directory -Force -Path (Join-Path $tree "empty") | Out-Null
        $before = Get-HermesDirectoryFingerprint $tree
        Assert-True ($before -match "(?m)^D:\.$") "Directory fingerprint omitted the root directory entry."
        Assert-True ($before -match "(?m)^D:empty$") "Directory fingerprint omitted an empty child directory."
        Set-Content -LiteralPath (Join-Path $tree "empty/file.txt") -Value "x" -Encoding ASCII
        $after = Get-HermesDirectoryFingerprint $tree
        Assert-True ($before -ne $after) "Directory fingerprint did not change when an empty directory gained a file."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Named installer mutex fails second invocation before writes" {
    $mutex = New-Object System.Threading.Mutex($false, "Local\HermesDiscordStatusInstaller")
    $held = $false
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $held = $mutex.WaitOne(0)
        Assert-True $held "Test could not acquire installer mutex."
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-True ($result.ExitCode -ne 0) "Second installer invocation unexpectedly succeeded while mutex was held."
        Assert-True ($result.Output -match "already running") "Mutex failure did not explain concurrent installer instance."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "Second invocation wrote Vencord destination while mutex was held."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "Second invocation wrote Hermes destination while mutex was held."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes ".env"))) "Second invocation wrote .env while mutex was held."
    } finally {
        if ($held) {
            $mutex.ReleaseMutex() | Out-Null
        }
        $mutex.Dispose()
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Abandoned installer mutex is recovered safely" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        if (-not ("HermesInstallerAbandonedMutexProbe" -as [type])) {
            Add-Type -TypeDefinition @'
using System.Threading;
public static class HermesInstallerAbandonedMutexProbe {
    private static Mutex held;
    public static void Create(string name) {
        held = new Mutex(false, name);
        Thread thread = new Thread(() => { held.WaitOne(); });
        thread.Start();
        thread.Join();
    }
}
'@
        }
        [HermesInstallerAbandonedMutexProbe]::Create("Local\HermesDiscordStatusInstaller")

        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -WhatIf
        Assert-Equal 0 $result.ExitCode $result.Output
        Assert-True ($result.Output -match "abandoned installer mutex") "Installer did not report abandoned mutex recovery."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Second install is idempotent, preserves token, removes stale managed files, and collapses duplicate token lines" {
    Assert-True (Test-Path -LiteralPath $InstallScript) "install.ps1 is missing."

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null

        $first = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-Equal 0 $first.ExitCode $first.Output
        $envPath = Join-Path $hermes ".env"
        $firstToken = ([regex]::Match((Get-Content -LiteralPath $envPath -Raw), "(?m)^HERMES_DISCORD_STATUS_TOKEN=(.+?)\r?$")).Groups[1].Value

        New-Item -ItemType File -Force -Path (Join-Path $vencord "src/userplugins/hermesStatus/stale.txt") | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $hermes "plugins/discord-status/stale.txt") | Out-Null
        Set-Content -LiteralPath $envPath -Value "A=1`r`nHERMES_DISCORD_STATUS_TOKEN=$firstToken`r`nB=2`r`nHERMES_DISCORD_STATUS_TOKEN=discard-me`r`n" -Encoding UTF8

        $second = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-Equal 0 $second.ExitCode $second.Output

        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus/stale.txt"))) "Stale Vencord file was not removed."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status/stale.txt"))) "Stale Hermes file was not removed."

        $envText = Get-Content -LiteralPath $envPath -Raw
        $tokenMatches = [regex]::Matches($envText, "(?m)^HERMES_DISCORD_STATUS_TOKEN=(.+?)\r?$")
        Assert-Equal 1 $tokenMatches.Count "Duplicate token lines were not collapsed."
        Assert-Equal "discard-me" $tokenMatches[0].Groups[1].Value "Effective last token was not preserved."
        Assert-True ($envText -match "(?m)^A=1\r?$") "First unrelated entry was not preserved."
        Assert-True ($envText -match "(?m)^B=2\r?$") "Second unrelated entry was not preserved."
        Assert-True (-not $second.Output.Contains($firstToken)) "Existing token leaked to normal output."
        Assert-NoBom $envPath ".env was not kept as UTF-8 without BOM."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Invalid checkout fails before modifying either destination" {
    Assert-True (Test-Path -LiteralPath $InstallScript) "install.ps1 is missing."

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $badVencord = Join-Path $root "BadVencord"
        $hermes = Join-Path $root ".hermes"
        New-Item -ItemType Directory -Force -Path $badVencord, $hermes | Out-Null

        $result = Invoke-Installer -VencordPath $badVencord -HermesHome $hermes
        Assert-True ($result.ExitCode -ne 0) "Invalid checkout unexpectedly succeeded."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $badVencord "src/userplugins/hermesStatus"))) "Vencord destination was modified after validation failure."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "Hermes destination was modified after validation failure."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes ".env"))) ".env was modified after validation failure."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WhatIf makes no changes" {
    Assert-True (Test-Path -LiteralPath $InstallScript) "install.ps1 is missing."

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -WhatIf
        Assert-Equal 0 $result.ExitCode $result.Output
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "Vencord destination changed during WhatIf."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "Hermes destination changed during WhatIf."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes ".env"))) ".env changed during WhatIf."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WhatIf reports planned install summary and token intent" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $newHermes = Join-Path $root "new-hermes"
        $existingHermes = Join-Path $root "existing-hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $newHermes, $existingHermes | Out-Null
        Set-Content -LiteralPath (Join-Path $existingHermes ".env") -Value "HERMES_DISCORD_STATUS_TOKEN=kept-token`r`n" -Encoding ASCII

        $created = Invoke-Installer -VencordPath $vencord -HermesHome $newHermes -WhatIf
        Assert-Equal 0 $created.ExitCode $created.Output
        Assert-True ($created.Output -match "Planned install summary") "WhatIf did not label the summary as planned."
        Assert-True ($created.Output -match "Token:\s+would be created") "WhatIf did not report planned token creation."
        Assert-True (-not ($created.Output -match "Token:\s+created")) "WhatIf used completed token creation wording."

        $showTokenPlan = Invoke-Installer -VencordPath $vencord -HermesHome $newHermes -WhatIf -ShowToken
        Assert-Equal 0 $showTokenPlan.ExitCode $showTokenPlan.Output
        Assert-True ($showTokenPlan.Output -match "Token value:\s+not generated during WhatIf") "WhatIf -ShowToken did not suppress the unusable generated token."
        Assert-True (-not ($showTokenPlan.Output -match "Token value:\s+[A-Za-z0-9_-]{32,}")) "WhatIf -ShowToken printed a token that will never be installed."

        $preserved = Invoke-Installer -VencordPath $vencord -HermesHome $existingHermes -WhatIf
        Assert-Equal 0 $preserved.ExitCode $preserved.Output
        Assert-True ($preserved.Output -match "Token:\s+would preserve existing token") "WhatIf did not report planned token preservation."
        Assert-True (-not ($preserved.Output -match "Token:\s+existing token preserved")) "WhatIf used completed token preservation wording."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Ancestor junction above approved Vencord root is rejected" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $realParent = Join-Path $root "real-parent"
        $junctionParent = Join-Path $root "junction-parent"
        if (-not (New-TestJunction -Path $junctionParent -Target $realParent)) {
            Write-Host "SKIP ancestor junction rejection: junction creation is unavailable."
            return
        }
        $vencord = Join-Path $junctionParent "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-True ($result.ExitCode -ne 0) "Installer accepted Vencord path under an ancestor junction."
        Assert-True ($result.Output -match "reparse point|junction|symlink") "Ancestor junction failure did not identify reparse point risk."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Source tree junction is rejected before recursive copy" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    $sourceJunction = Join-Path (Join-Path $RepoRoot "bridge") ("junction-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $externalTarget = Join-Path $root "external-source"
        if (-not (New-TestJunction -Path $sourceJunction -Target $externalTarget)) {
            Write-Host "SKIP source tree junction rejection: junction creation is unavailable."
            return
        }
        Set-Content -LiteralPath (Join-Path $externalTarget "external.txt") -Value "must not copy`r`n" -Encoding ASCII
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-True ($result.ExitCode -ne 0) "Installer accepted a source-tree junction."
        Assert-True ($result.Output -match "source.*reparse|reparse.*source|junction|symlink") "Source junction failure did not identify reparse point risk."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status/external.txt"))) "Recursive copy followed the source-tree junction."
    } finally {
        if (Test-Path -LiteralPath $sourceJunction) {
            $cmd = Get-Command "cmd.exe" -ErrorAction SilentlyContinue
            if ($null -ne $cmd) {
                & $cmd.Source /c "rmdir `"$sourceJunction`"" | Out-Null
            }
            Remove-Item -LiteralPath $sourceJunction -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Managed-directory safety rejects a nested junction before recursive cleanup" {
    try {
        . $InstallScript -VencordPath "__never_exists__" -HermesHome "__never_exists__" -SkipHermesCommands -WhatIf -ErrorAction Stop 2>$null
    } catch {
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $managed = Join-Path $root "managed"
        $external = Join-Path $root "external"
        New-Item -ItemType Directory -Force -Path $managed, $external | Out-Null
        $junction = Join-Path $managed "nested-junction"
        if (-not (New-TestJunction -Path $junction -Target $external)) {
            Write-Host "SKIP nested junction cleanup rejection: junction creation is unavailable."
            return
        }
        $operation = @{ Safety = (New-WindowsPathSafetyCallback $root "test managed directory") }
        $failed = $false
        try {
            Invoke-HermesOperationSafety $operation $managed "recursive cleanup"
        } catch {
            $failed = $true
            Assert-True ($_.Exception.Message -match "reparse point|junction|symlink") "Nested junction rejection did not identify reparse risk."
        }
        Assert-True $failed "Managed-directory safety accepted a nested junction before recursive cleanup."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Empty token is replaced without leaking token" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        Set-Content -LiteralPath (Join-Path $hermes ".env") -Value "A=1`r`nHERMES_DISCORD_STATUS_TOKEN=   `r`nB=2`r`n" -Encoding UTF8

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-Equal 0 $result.ExitCode $result.Output

        $envText = Get-Content -LiteralPath (Join-Path $hermes ".env") -Raw
        $tokenMatches = [regex]::Matches($envText, "(?m)^HERMES_DISCORD_STATUS_TOKEN=(.+?)\r?$")
        Assert-Equal 1 $tokenMatches.Count "Expected one replacement token."
        $token = $tokenMatches[0].Groups[1].Value
        Assert-True ($token.Length -ge 43) "Replacement token is too short."
        Assert-True (-not $result.Output.Contains($token)) "Replacement token leaked to normal output."
        Assert-NoBom (Join-Path $hermes ".env") ".env was not written as UTF-8 without BOM."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Dotenv parser uses python-dotenv effective last assignment and normalizes token" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $envPath = Join-Path $hermes ".env"
        $envLines = @(
            "KEEP=1",
            "export HERMES_DISCORD_STATUS_TOKEN = first_token # ignored older value",
            "OTHER=2",
            "HERMES_DISCORD_STATUS_TOKEN='second-token'",
            "HERMES_DISCORD_STATUS_TOKEN = `"final_token-123`" # active value",
            "AFTER=3"
        )
        Set-Content -LiteralPath $envPath -Value ($envLines -join "`r`n") -Encoding UTF8

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-Equal 0 $result.ExitCode $result.Output

        $envText = Get-Content -LiteralPath $envPath -Raw
        $tokenMatches = [regex]::Matches($envText, "(?m)^HERMES_DISCORD_STATUS_TOKEN=(.+?)\r?$")
        Assert-Equal 1 $tokenMatches.Count "Expected exactly one normalized token line."
        Assert-Equal "final_token-123" $tokenMatches[0].Groups[1].Value "Installer did not preserve python-dotenv effective-last token value."
        Assert-True ($envText -match "(?m)^KEEP=1\r?$") "Unrelated preceding line was not preserved."
        Assert-True ($envText -match "(?m)^OTHER=2\r?$") "Unrelated middle line was not preserved."
        Assert-True ($envText -match "(?m)^AFTER=3\r?$") "Unrelated following line was not preserved."
        Assert-True (-not ($envText -match "export HERMES_DISCORD_STATUS_TOKEN")) "Old export token assignment was not removed."
        Assert-True (-not ($envText -match "# active value")) "Token comment was preserved as token material."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Malformed dotenv token assignment is rejected before writes" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        Set-Content -LiteralPath (Join-Path $hermes ".env") -Value "HERMES_DISCORD_STATUS_TOKEN='unterminated`r`n" -Encoding UTF8

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-True ($result.ExitCode -ne 0) "Malformed token assignment unexpectedly succeeded."
        Assert-True ($result.Output -match "malformed|ambiguous") "Malformed token failure did not explain the token parsing problem."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "Vencord destination changed after malformed .env validation."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "Hermes destination changed after malformed .env validation."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Unquoted inline hash token is rejected but spaced comments remain valid" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $envPath = Join-Path $hermes ".env"
        Set-Content -LiteralPath $envPath -Value "HERMES_DISCORD_STATUS_TOKEN=abc#def`r`n" -Encoding UTF8

        $bad = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-True ($bad.ExitCode -ne 0) "Unquoted inline hash token unexpectedly succeeded."
        Assert-True ($bad.Output -match "malformed|ambiguous") "Inline hash failure did not explain the token parsing problem."

        Set-Content -LiteralPath $envPath -Value "export HERMES_DISCORD_STATUS_TOKEN = older # comment`r`nHERMES_DISCORD_STATUS_TOKEN=final_token # comment`r`n" -Encoding UTF8
        $good = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-Equal 0 $good.ExitCode $good.Output
        $envText = Get-Content -LiteralPath $envPath -Raw
        Assert-True ($envText -match "(?m)^HERMES_DISCORD_STATUS_TOKEN=final_token\r?$") "Spaced dotenv comment was not accepted with effective last assignment."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test ".env directory is rejected before managed destinations are changed" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path (Join-Path $hermes ".env") | Out-Null

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-True ($result.ExitCode -ne 0) ".env directory unexpectedly succeeded."
        Assert-True ($result.Output -match "\.env.*regular.*file|regular.*file.*\.env") "Failure did not identify .env type confusion."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "Vencord destination changed after .env directory validation failure."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "Hermes destination changed after .env directory validation failure."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Managed destination file is rejected before writes" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path (Join-Path $hermes "plugins") | Out-Null
        Set-Content -LiteralPath (Join-Path $hermes "plugins/discord-status") -Value "not a directory`r`n" -Encoding ASCII

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-True ($result.ExitCode -ne 0) "Managed destination file unexpectedly succeeded."
        Assert-True ($result.Output -match "managed.*directory|directory.*destination") "Failure did not identify managed destination type confusion."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "Vencord destination changed after managed destination file validation."
        Assert-True (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status") -PathType Leaf) "Managed destination file was moved or replaced."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes ".env"))) ".env changed after managed destination file validation."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Installer makes one top-level ShouldProcess decision and rollback is fail-closed" {
    $installerText = Get-Content -LiteralPath $InstallScript -Raw
    $shouldProcessCount = ([regex]::Matches($installerText, '\$PSCmdlet\.ShouldProcess')).Count
    Assert-Equal 1 $shouldProcessCount "Installer must make one top-level ShouldProcess decision."
    $undoMatch = [regex]::Match($installerText, 'function Undo-InstallOperation \{(?<body>[\s\S]*?)\r?\n\}')
    Assert-True $undoMatch.Success "Undo-InstallOperation was not found."
    Assert-True (-not ($undoMatch.Groups["body"].Value -match 'SilentlyContinue')) "Rollback must not suppress restore or removal failures."
}

Invoke-Test "Trusted WSL resolution ignores process SystemRoot and PATH outside test mode" {
    Import-InstallerHelpers
    $oldSystemRoot = $env:SystemRoot
    $oldPath = $env:PATH
    try {
        $env:SystemRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fake-windows-" + [guid]::NewGuid().ToString("N"))
        $env:PATH = $env:SystemRoot
        Remove-Item Env:\HERMES_INSTALLER_TESTING -ErrorAction SilentlyContinue
        Remove-Variable -Name HermesInstallerTestWslExecutable -Scope Script -ErrorAction SilentlyContinue
        $expected = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) "wsl.exe"
        Assert-Equal ([System.IO.Path]::GetFullPath($expected)) ([System.IO.Path]::GetFullPath((Resolve-HermesTrustedWslExe))) "Trusted WSL resolution used process-controlled SystemRoot or PATH."
    } finally {
        $env:SystemRoot = $oldSystemRoot
        $env:PATH = $oldPath
    }
}

Invoke-Test "WSL mode helper invokes absolute python argv and is skipped by WhatIf" {
    Import-InstallerHelpers

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    $oldPath = $env:PATH
    $oldSystemRoot = $env:SystemRoot
    try {
        $fake = New-FakeWslOnlyDirectory -Root (Join-Path $root "bin") -ExitCodes @(0)
        $env:PATH = "$($fake.Directory);$oldPath"
        $env:SystemRoot = $fake.SystemRoot
        $env:HERMES_INSTALLER_TESTING = "1"
        $script:HermesInstallerTestWslExecutable = Join-Path $fake.SystemRoot "System32\wsl.exe"
        $env:HERMES_FAKE_WSL_LOG = $fake.Log
        $env:HERMES_FAKE_WSL_STATE = $fake.State
        $env:HERMES_FAKE_WSL_EXIT_CODES = $fake.ExitCodes

        Invoke-HermesWslChmod600 -ParsedPath ([pscustomobject]@{
            Distribution = "Ubuntu-24.04"
            LinuxPath = "/home/mohammed/.hermes/.env"
        }) -ApprovedLinuxRoot "/home/mohammed/.hermes" -WhatIf:$false

        $commandLog = Get-Content -LiteralPath $fake.Log -Raw
        Assert-True ($commandLog -match "^wsl -d Ubuntu-24\.04 -- /usr/bin/python3 -c ") "WSL mode helper did not use absolute /usr/bin/python3."
        Assert-True ($commandLog -match "/home/mohammed/\.hermes/\.env /home/mohammed/\.hermes\s*$") "WSL mode helper did not pass final path and approved root as argv."
        Assert-True (-not ($commandLog -match " chmod ")) "WSL mode helper must not invoke path-following chmod."

        Remove-Item -LiteralPath $fake.Log -Force
        Invoke-HermesWslChmod600 -ParsedPath ([pscustomobject]@{
            Distribution = "Ubuntu-24.04"
            LinuxPath = "/home/mohammed/.hermes/.env"
        }) -ApprovedLinuxRoot "/home/mohammed/.hermes" -WhatIf:$true
        Assert-True (-not (Test-Path -LiteralPath $fake.Log)) "WhatIf invoked wsl chmod."
    } finally {
        $env:PATH = $oldPath
        $env:SystemRoot = $oldSystemRoot
        Remove-Item Env:\HERMES_FAKE_WSL_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_STATE -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_EXIT_CODES -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_INSTALLER_TESTING -ErrorAction SilentlyContinue
        Remove-Variable -Name HermesInstallerTestWslExecutable -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Explicit local HermesHome with Hermes commands fails validation before writes" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 0 -WslExitCode 0

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -RunHermesCommands -CommandDirectory $fake.Directory
        Assert-True ($result.ExitCode -ne 0) "Explicit local HermesHome with Hermes commands unexpectedly succeeded."
        Assert-True ($result.Output -match "explicit non-WSL Windows path") "Failure did not explain explicit local HermesHome restriction."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "Vencord destination changed after validation failure."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "Hermes destination changed after validation failure."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes ".env"))) ".env changed after validation failure."
        Assert-True (-not (Test-Path -LiteralPath $fake.Log)) "Validation failure invoked external commands."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Vencord quality gates use tsx status test command sequence" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 0 -WslExitCode 0

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -RunVencordBuild -CommandDirectory $fake.Directory
        Assert-Equal 0 $result.ExitCode $result.Output

        $commands = @(Get-Content -LiteralPath $fake.Log)
        $expected = @(
            "pnpm install --frozen-lockfile",
            "pnpm exec eslint src/userplugins/hermesStatus",
            "pnpm testTsc",
            "pnpm exec tsx src/userplugins/hermesStatus/tests/statusLogic.test.ts",
            "pnpm build"
        )
        Assert-Equal ($expected -join "|") ($commands -join "|") "Unexpected pnpm quality-gate command sequence."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Failed quality gate restores previous plugin bridge and env byte-for-byte" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        $oldPlugin = Join-Path $vencord "src/userplugins/hermesStatus"
        $oldBridge = Join-Path $hermes "plugins/discord-status"
        New-Item -ItemType Directory -Force -Path $oldPlugin, $oldBridge | Out-Null
        Set-Content -LiteralPath (Join-Path $oldPlugin "old.txt") -Value "old plugin`r`n" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $oldBridge "old.txt") -Value "old bridge`r`n" -Encoding ASCII
        $envPath = Join-Path $hermes ".env"
        Set-Content -LiteralPath $envPath -Value "A=1`r`nHERMES_DISCORD_STATUS_TOKEN=old-token`r`n" -Encoding ASCII
        $expectedPlugin = Join-Path $root "expected-plugin"
        $expectedBridge = Join-Path $root "expected-bridge"
        Copy-Item -LiteralPath $oldPlugin -Destination $expectedPlugin -Recurse
        Copy-Item -LiteralPath $oldBridge -Destination $expectedBridge -Recurse
        $expectedEnv = [System.IO.File]::ReadAllBytes($envPath)
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 7 -WslExitCode 0

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -RunVencordBuild -CommandDirectory $fake.Directory
        Assert-True ($result.ExitCode -ne 0) "Failing pnpm command unexpectedly succeeded."
        Assert-FileTreesEqual $expectedPlugin $oldPlugin "Previous Vencord plugin was not restored."
        Assert-FileTreesEqual $expectedBridge $oldBridge "Previous Hermes bridge was not restored."
        $actualEnv = [System.IO.File]::ReadAllBytes($envPath)
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($expectedEnv, $actualEnv)) "Previous .env bytes were not restored."
        Assert-DirectoryClean (Join-Path $vencord "src/userplugins") "Vencord stage/backup debris was left behind."
        Assert-DirectoryClean (Join-Path $hermes "plugins") "Hermes stage/backup debris was left behind."
        Assert-True (-not $result.Output.Contains("old-token")) "Token leaked in failure output."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "First-time failed install removes new destinations and env" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 9 -WslExitCode 0

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -RunVencordBuild -CommandDirectory $fake.Directory
        Assert-True ($result.ExitCode -ne 0) "Failing first-time install unexpectedly succeeded."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "First-time failed install left Vencord plugin behind."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "First-time failed install left Hermes bridge behind."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes ".env"))) "First-time failed install left new .env behind."
        Assert-DirectoryClean (Join-Path $vencord "src/userplugins") "Vencord stage/backup debris was left behind."
        Assert-DirectoryClean (Join-Path $hermes "plugins") "Hermes stage/backup debris was left behind."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Managed directory first-install internal failure removes moved destination and journals transitions" {
    try {
        . $InstallScript -VencordPath "__never_exists__" -HermesHome "__never_exists__" -SkipHermesCommands -WhatIf -ErrorAction Stop 2>$null
    } catch {
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $source = Join-Path $root "source"
        $dest = Join-Path $root "dest"
        New-Item -ItemType Directory -Force -Path (Join-Path $source "empty") | Out-Null
        Set-Content -LiteralPath (Join-Path $source "file.txt") -Value "new`r`n" -Encoding ASCII
        $script:InstallExecute = $true
        $script:HermesInstallJournal = New-Object System.Collections.Generic.List[hashtable]
        $script:HermesInstallerFaultInjector = {
            param([string] $Point, [string] $Path)
            if ($Point -eq "test-after-destination-move") {
                throw "forced directory post-move failure"
            }
        }

        $failed = $false
        try {
            Start-ManagedDirectoryReplacement $source $dest "test" (New-WindowsPathSafetyCallback $root "test")
        } catch {
            $failed = $true
            Assert-True ($_.Exception.Message -match "forced directory") "Fault failure did not propagate original error."
        }
        Assert-True $failed "Injected directory failure unexpectedly succeeded."
        Assert-True (-not (Test-Path -LiteralPath $dest)) "First-install moved directory destination was not removed after internal failure."
        Assert-True (($script:HermesInstallJournal | ForEach-Object { $_.Operation }) -contains "test destination-installed") "Directory transition was not journaled."
    } finally {
        Remove-Variable -Name HermesInstallerFaultInjector -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name HermesInstallJournal -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Token first-install internal failure removes moved env destination" {
    try {
        . $InstallScript -VencordPath "__never_exists__" -HermesHome "__never_exists__" -SkipHermesCommands -WhatIf -ErrorAction Stop 2>$null
    } catch {
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $envPath = Join-Path $root ".env"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $script:InstallExecute = $true
        $script:HermesInstallerFaultInjector = {
            param([string] $Point, [string] $Path)
            if ($Point -eq ".env-after-destination-move") {
                throw "forced env post-move failure"
            }
        }

        $failed = $false
        try {
            Start-HermesTokenUpdate $envPath (New-WindowsPathSafetyCallback $root "env")
        } catch {
            $failed = $true
            Assert-True ($_.Exception.Message -match "forced env") "Fault failure did not propagate original .env error."
        }
        Assert-True $failed "Injected .env failure unexpectedly succeeded."
        Assert-True (-not (Test-Path -LiteralPath $envPath)) "First-install moved .env was not removed after internal failure."
    } finally {
        Remove-Variable -Name HermesInstallerFaultInjector -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WSL chmod failure rolls back disposable UNC install" {
    $distribution = Get-TestWslDistribution
    if ([string]::IsNullOrWhiteSpace($distribution)) {
        Write-Host "SKIP WSL chmod failure rollback probe: WSL is unavailable or no valid distro is registered."
        return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    $wslTemp = $null
    $oldPath = $env:PATH
    try {
        $wslTemp = New-TestWslTempDirectory -Distribution $distribution
        $vencord = Join-Path $root "Vencord"
        $expectedPlugin = Join-Path $root "expected-plugin"
        $expectedBridge = Join-Path $root "expected-bridge"
        New-FakeVencord $vencord

        $hermes = Join-Path $wslTemp.WindowsPath ".hermes"
        $oldPlugin = Join-Path $vencord "src/userplugins/hermesStatus"
        $oldBridge = Join-Path $hermes "plugins/discord-status"
        New-Item -ItemType Directory -Force -Path $oldPlugin, $oldBridge | Out-Null
        Set-Content -LiteralPath (Join-Path $oldPlugin "old.txt") -Value "old plugin`r`n" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $oldBridge "old.txt") -Value "old bridge`n" -Encoding ASCII
        $envPath = Join-Path $hermes ".env"
        Set-Content -LiteralPath $envPath -Value "A=1`nHERMES_DISCORD_STATUS_TOKEN=old-token`n" -Encoding ASCII
        Copy-Item -LiteralPath $oldPlugin -Destination $expectedPlugin -Recurse
        Copy-Item -LiteralPath $oldBridge -Destination $expectedBridge -Recurse
        $expectedEnv = [System.IO.File]::ReadAllBytes($envPath)

        $fake = New-FakeWslOnlyDirectory -Root (Join-Path $root "bin") -ExitCodes @(0)
        $env:PATH = "$($fake.Directory);$oldPath"
        $env:HERMES_FAKE_WSL_LOG = $fake.Log
        $env:HERMES_FAKE_WSL_STATE = $fake.State
        $env:HERMES_FAKE_WSL_EXIT_CODES = $fake.ExitCodes
        $env:HERMES_FAKE_WSL_FAIL_CHMOD = "23"

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -CommandDirectory $fake.Directory
        Assert-True ($result.ExitCode -ne 0) "Failing chmod unexpectedly succeeded."
        $commandLog = Get-Content -LiteralPath $fake.Log -Raw
        $expectedLinuxEnv = "$($wslTemp.LinuxPath)/.hermes/.env"
        Assert-True ($commandLog -match " /usr/bin/python3 -c ") "Failure did not reach mode hardening. Output: $($result.Output)"
        Assert-True ($commandLog -match [regex]::Escape("$expectedLinuxEnv $($wslTemp.LinuxPath)/.hermes")) "Unexpected mode helper argv during installer rollback probe."
        Assert-FileTreesEqual $expectedPlugin $oldPlugin "Previous Vencord plugin was not restored after chmod failure."
        Assert-FileTreesEqual $expectedBridge $oldBridge "Previous Hermes bridge was not restored after chmod failure."
        $actualEnv = [System.IO.File]::ReadAllBytes($envPath)
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($expectedEnv, $actualEnv)) "Previous .env bytes were not restored after chmod failure."
    } finally {
        $env:PATH = $oldPath
        Remove-Item Env:\HERMES_FAKE_WSL_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_STATE -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_EXIT_CODES -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_FAIL_CHMOD -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-TestWslTempDirectory $wslTemp
    }
}

Invoke-Test "Disposable WSL UNC env install ends with Linux mode 600" {
    $distribution = Get-TestWslDistribution
    if ([string]::IsNullOrWhiteSpace($distribution)) {
        Write-Host "SKIP WSL chmod integration probe: WSL is unavailable or no valid distro is registered."
        return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    $wslTemp = $null
    try {
        $wslTemp = New-TestWslTempDirectory -Distribution $distribution
        $vencord = Join-Path $root "Vencord"
        New-FakeVencord $vencord

        $hermes = Join-Path $wslTemp.WindowsPath ".hermes"
        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes
        Assert-Equal 0 $result.ExitCode $result.Output

        $wsl = (Get-Command "wsl.exe" -ErrorAction Stop).Source
        $linuxEnv = "$($wslTemp.LinuxPath)/.hermes/.env"
        $mode = (& $wsl -d $distribution -- stat -c "%a" $linuxEnv | Select-Object -First 1).Trim()
        Assert-Equal "600" $mode "Disposable WSL UNC .env did not end with mode 600."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-TestWslTempDirectory $wslTemp
    }
}

Invoke-Test "Disposable WSL token temp is mode 600 before secret write" {
    $distribution = Get-TestWslDistribution
    if ([string]::IsNullOrWhiteSpace($distribution)) {
        Write-Host "SKIP WSL temp pre-write mode probe: WSL is unavailable or no valid distro is registered."
        return
    }

    try {
        . $InstallScript -VencordPath "__never_exists__" -HermesHome "__never_exists__" -SkipHermesCommands -WhatIf -ErrorAction Stop 2>$null
    } catch {
    }

    $wslTemp = $null
    try {
        $wslTemp = New-TestWslTempDirectory -Distribution $distribution
        $hermes = Join-Path $wslTemp.WindowsPath ".hermes"
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $envPath = Join-Path $hermes ".env"
        $script:InstallExecute = $true
        $script:HermesInstallerFaultInjector = {
            param([string] $Point, [string] $Path)
            if ($Point -ne ".env-before-temp-write") {
                return
            }
            $parsed = ConvertFrom-HermesWslUncPath -Path $Path -WslDistribution $distribution
            $wsl = (Get-Command "wsl.exe" -ErrorAction Stop).Source
            $mode = (& $wsl -d $distribution -- stat -c "%a" $parsed.LinuxPath | Select-Object -First 1).Trim()
            $size = (& $wsl -d $distribution -- stat -c "%s" $parsed.LinuxPath | Select-Object -First 1).Trim()
            Assert-Equal "600" $mode "WSL token temp was not mode 600 before WriteAllText."
            Assert-Equal "0" $size "WSL token temp contained bytes before WriteAllText."
        }

        $result = Start-HermesTokenUpdate $envPath (New-WslPathSafetyCallback $distribution "$($wslTemp.LinuxPath)/.hermes" "env")
        Assert-True $result.Written "Token update did not write .env."
    } finally {
        Remove-Variable -Name HermesInstallerFaultInjector -Scope Script -ErrorAction SilentlyContinue
        Remove-TestWslTempDirectory $wslTemp
    }
}

Invoke-Test "Hermes command failure leaves committed managed files installed" {
    $distribution = Get-TestWslDistribution
    if ([string]::IsNullOrWhiteSpace($distribution)) {
        Write-Host "SKIP Hermes failure commit-boundary probe: WSL is unavailable or no valid distro is registered."
        return
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    $wslTemp = $null
    $oldPath = $env:PATH
    try {
        $wslTemp = New-TestWslTempDirectory -Distribution $distribution
        $vencord = Join-Path $root "Vencord"
        New-FakeVencord $vencord
        $hermes = Join-Path $wslTemp.WindowsPath ".hermes"

        $fake = New-FakeWslOnlyDirectory -Root (Join-Path $root "bin") -ExitCodes @(0)
        $env:PATH = "$($fake.Directory);$oldPath"
        $env:HERMES_FAKE_WSL_LOG = $fake.Log
        $env:HERMES_FAKE_WSL_STATE = $fake.State
        $env:HERMES_FAKE_WSL_EXIT_CODES = $fake.ExitCodes
        $env:HERMES_FAKE_WSL_FAIL_HERMES = "41"

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -RunHermesCommands -CommandDirectory $fake.Directory
        Assert-True ($result.ExitCode -ne 0) "Failing Hermes command unexpectedly succeeded."
        Assert-True ($result.Output -match "Managed files were installed and verified") "Failure did not report committed managed files."
        Assert-FileTreesEqual (Join-Path $RepoRoot "vencord-userplugin/hermesStatus") (Join-Path $vencord "src/userplugins/hermesStatus") "Vencord plugin was rolled back after Hermes command failure."
        Assert-FileTreesEqual (Join-Path $RepoRoot "bridge") (Join-Path $hermes "plugins/discord-status") "Hermes bridge was rolled back after Hermes command failure."
        Assert-True (Test-Path -LiteralPath (Join-Path $hermes ".env") -PathType Leaf) ".env was rolled back after Hermes command failure."
        Assert-DirectoryClean (Join-Path $vencord "src/userplugins") "Vencord backup debris remained after committed Hermes command failure."
        Assert-DirectoryClean (Join-Path $hermes "plugins") "Hermes backup debris remained after committed Hermes command failure."
        $commands = @(Get-Content -LiteralPath $fake.Log | Where-Object { $_ -match " hermes plugins enable " })
        Assert-True ($commands.Count -eq 1) "Hermes enable command was not invoked exactly once."
    } finally {
        $env:PATH = $oldPath
        Remove-Item Env:\HERMES_FAKE_WSL_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_STATE -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_EXIT_CODES -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_FAKE_WSL_FAIL_HERMES -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-TestWslTempDirectory $wslTemp
    }
}

Invoke-Test "Backup cleanup failure warns without rolling back successful install" {
    Import-InstallerHelpers

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $dest = Join-Path $root ".env"
        $backup = Join-Path $root ".env.backup.leftover"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Set-Content -LiteralPath $dest -Value "new`r`n" -Encoding ASCII
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        Set-Content -LiteralPath (Join-Path $backup "locked.txt") -Value "old`r`n" -Encoding ASCII
        $operation = @{
            Kind = "File"
            Destination = $dest
            Backup = $backup
            HadDestination = $true
            Applied = $true
        }

        $warning = $null
        Complete-HermesInstallOperation $operation -WarningVariable warning 3>$null

        Assert-True (Test-Path -LiteralPath $dest) "Successful destination was rolled back during cleanup."
        Assert-True (Test-Path -LiteralPath $backup) "Failed cleanup did not preserve leftover backup."
        Assert-True (($warning | Out-String) -match "Install succeeded") "Cleanup failure did not warn."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Complete verifies previous fingerprint and invokes safety before cleanup" {
    Import-InstallerHelpers

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $dest = Join-Path $root "dest"
        $backup = Join-Path $root "backup"
        New-Item -ItemType Directory -Force -Path $dest, $backup | Out-Null
        Set-Content -LiteralPath (Join-Path $dest "new.txt") -Value "new`r`n" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $backup "old.txt") -Value "old`r`n" -Encoding ASCII
        $calls = New-Object System.Collections.Generic.List[string]
        $operation = @{
            Kind = "Directory"
            Label = "test"
            Destination = $dest
            Backup = $backup
            HadDestination = $true
            Applied = $true
            PreviousFingerprint = "different"
            Safety = { param([string] $Path, [string] $Description) $calls.Add("$Description|$Path") }
        }

        $warning = $null
        Complete-HermesInstallOperation $operation -WarningVariable warning 3>$null

        Assert-True (Test-Path -LiteralPath $backup) "Backup with unexpected fingerprint was removed."
        Assert-True (($warning | Out-String) -match "fingerprint|changed") "Fingerprint mismatch did not warn."
        Assert-True (($calls -join "`n") -match [regex]::Escape($backup)) "Safety callback was not invoked before cleanup."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Undo verifies restored backup fingerprint and invokes safety before removals" {
    try {
        . $InstallScript -VencordPath "__never_exists__" -HermesHome "__never_exists__" -SkipHermesCommands -WhatIf -ErrorAction Stop 2>$null
    } catch {
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $dest = Join-Path $root "dest"
        $backup = Join-Path $root "backup"
        New-Item -ItemType Directory -Force -Path $dest, $backup | Out-Null
        Set-Content -LiteralPath (Join-Path $dest "new.txt") -Value "new`r`n" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $backup "old.txt") -Value "old`r`n" -Encoding ASCII
        $expectedNew = Get-DirectoryFingerprint $dest
        $calls = New-Object System.Collections.Generic.List[string]
        $operation = @{
            Kind = "Directory"
            Label = "test"
            Destination = $dest
            Stage = (Join-Path $root "stage")
            Backup = $backup
            HadDestination = $true
            Applied = $true
            ExpectedFingerprint = $expectedNew
            PreviousFingerprint = "different"
            Safety = { param([string] $Path, [string] $Description) $calls.Add("$Description|$Path") }
        }

        $failed = $false
        try {
            Undo-InstallOperation $operation
        } catch {
            $failed = $true
            Assert-True ($_.Exception.Message -match "fingerprint|restore") "Undo failure did not identify restored fingerprint mismatch."
        }
        Assert-True $failed "Undo accepted a restored backup with the wrong fingerprint."
        Assert-True (Test-Path -LiteralPath $backup) "Undo moved a backup with the wrong fingerprint live."
        Assert-True (-not (Test-Path -LiteralPath $dest)) "Undo restored destination despite backup fingerprint mismatch."
        Assert-True (($calls -join "`n") -match [regex]::Escape($dest)) "Safety callback was not invoked before destination removal or restore."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "Changed destination during rollback is preserved with backup and aggregated error" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        $oldPlugin = Join-Path $vencord "src/userplugins/hermesStatus"
        New-Item -ItemType Directory -Force -Path $oldPlugin, $hermes | Out-Null
        Set-Content -LiteralPath (Join-Path $oldPlugin "old.txt") -Value "old plugin`r`n" -Encoding ASCII
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 17 -WslExitCode 0
        $pnpmScript = @"
@echo off
echo pnpm %*>>"$($fake.Log)"
echo changed during rollback>"$oldPlugin\changed.txt"
exit /b 17
"@
        Set-Content -LiteralPath (Join-Path $fake.Directory "pnpm.cmd") -Value $pnpmScript -Encoding ASCII

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -RunVencordBuild -CommandDirectory $fake.Directory

        Assert-True ($result.ExitCode -ne 0) "Failing install unexpectedly succeeded."
        Assert-True ($result.Output -match "Rollback failures|Rollback failed|changed unexpectedly|uncertainty") "Rollback did not aggregate uncertainty."
        Assert-True (Test-Path -LiteralPath (Join-Path $oldPlugin "changed.txt")) "Changed replacement destination was not preserved."
        $backup = @(Get-ChildItem -LiteralPath (Join-Path $vencord "src/userplugins") -Force | Where-Object { $_.Name -match "\.backup\." })
        Assert-True ($backup.Count -gt 0) "Previous backup was not preserved after rollback uncertainty."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WhatIf validates but does not invoke pnpm or WSL commands" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $hermes = Join-Path $root ".hermes"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        New-Item -ItemType Directory -Force -Path $hermes | Out-Null
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 11 -WslExitCode 12

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $hermes -RunVencordBuild -WhatIf -CommandDirectory $fake.Directory
        Assert-Equal 0 $result.ExitCode $result.Output
        Assert-True (-not (Test-Path -LiteralPath $fake.Log)) "WhatIf invoked an external command."
        Assert-True ($result.Output -match "What if:|WhatIf:") "WhatIf did not report planned actions."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $vencord "src/userplugins/hermesStatus"))) "Vencord destination changed during WhatIf."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes "plugins/discord-status"))) "Hermes destination changed during WhatIf."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $hermes ".env"))) ".env changed during WhatIf."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WSL WhatIf reports chmod hardening without invoking WSL" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 11 -WslExitCode 12
        $fakeWslHome = "\\wsl.localhost\TestDistro\home\tester\.hermes"

        $result = Invoke-Installer -VencordPath $vencord -HermesHome $fakeWslHome -WhatIf -CommandDirectory $fake.Directory
        Assert-Equal 0 $result.ExitCode $result.Output
        Assert-True ($result.Output -match "mode 0600.* /home/tester/\.hermes/\.env|0600 on /home/tester/\.hermes/\.env") "WhatIf did not report WSL mode hardening."
        Assert-True (-not (Test-Path -LiteralPath $fake.Log)) "WhatIf invoked WSL chmod."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WhatIf without HermesHome does not invoke WSL home resolution" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-install-test-" + [guid]::NewGuid().ToString("N"))
    try {
        $vencord = Join-Path $root "Vencord"
        $fakeBin = Join-Path $root "bin"
        New-FakeVencord $vencord
        $fake = New-FakeCommandDirectory -Root $fakeBin -PnpmExitCode 11 -WslExitCode 12

        $result = Invoke-Installer -VencordPath $vencord -OmitHermesHome -RunVencordBuild -RunHermesCommands -WhatIf -CommandDirectory $fake.Directory
        Assert-Equal 0 $result.ExitCode $result.Output
        Assert-True (-not (Test-Path -LiteralPath $fake.Log)) "WhatIf invoked WSL while resolving Hermes home."
        Assert-True ($result.Output -match "would resolve Hermes home through WSL") "WhatIf did not report planned WSL home resolution."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures -gt 0) {
    throw "$script:Failures installer test(s) failed."
}

Write-Host "All installer tests passed."
