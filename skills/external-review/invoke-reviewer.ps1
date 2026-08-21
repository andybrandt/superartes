param(
    [string]$Operation = '--help'
)

$Remaining = @($args)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:ValidatedRun = ''
$script:ReviewRoot = ''
$script:RegistryOwned = $false
$script:RegistryOwnerPid = ''
$script:RegistryOwnerStart = ''
$script:CancelLockOwned = $false
$script:CancelLockDirectory = ''
$script:CancelOwnerPid = ''
$script:CancelOwnerStart = ''
$script:ReviewerCommandExitCode = 1
$script:Artifacts = @(
    'marker', 'run-path', 'review-key', 'profile', 'provider', 'run-id',
    'provider-session', 'work-dir', 'scope-kind', 'scope-value', 'state',
    'started-at', 'completed-at', 'supervisor-pid', 'supervisor-start',
    'reviewer-pid', 'reviewer-start', 'reviewer-pgid', 'exit-code', 'prompt',
    'result', 'reviewer-output', 'reviewer-log', 'supervisor-output',
    'supervisor-log', 'previous-run', 'cancel-requested'
)

function Show-Usage {
    param([Parameter()][switch]$ErrorStream)
    $usage = @'
Usage:
  invoke-reviewer.ps1 check <claude-prompt|codex-prompt|codex-review>
  invoke-reviewer.ps1 start [--after-terminal RUN] PROFILE REVIEW_KEY WORK_DIR PROFILE_ARGS...
  invoke-reviewer.ps1 start claude-prompt REVIEW_KEY WORK_DIR PROMPT_FILE
  invoke-reviewer.ps1 start codex-prompt REVIEW_KEY WORK_DIR PROMPT_FILE
  invoke-reviewer.ps1 start codex-review REVIEW_KEY WORK_DIR uncommitted
  invoke-reviewer.ps1 start codex-review REVIEW_KEY WORK_DIR base BASE_REF
  invoke-reviewer.ps1 start codex-review REVIEW_KEY WORK_DIR commit COMMIT_SHA
  invoke-reviewer.ps1 status RUN
  invoke-reviewer.ps1 wait RUN TIMEOUT_SECONDS
  invoke-reviewer.ps1 cancel RUN
  invoke-reviewer.ps1 cleanup RUN

Exit codes:
  0   terminal state or accepted operation
  2   required CLI capability missing
  3   reviewer still running
  4   lifecycle indeterminate; inspect evidence, do not retry immediately
  12  matching review remains outstanding; attach to printed RUN_DIR
  64  usage or invalid profile arguments
  65  invalid or unsafe run directory
  66  cleanup refused because artifacts remain
  75  registry lock unavailable
  127 reviewer CLI unavailable
'@
    if ($ErrorStream) { [Console]::Error.WriteLine($usage) }
    else { [Console]::Out.WriteLine($usage) }
}

function Get-EpochSeconds {
    $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01T00:00:00', [DateTimeKind]::Utc)
    $seconds = [Math]::Floor(([DateTime]::UtcNow - $epoch).TotalSeconds)
    return $seconds.ToString()
}

function Get-TestDelay {
    param([Parameter(Mandatory = $true)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    $delay = 0
    if ($value -and [int]::TryParse($value, [ref]$delay) -and $delay -ge 0) {
        return $delay
    }
    return 0
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter()][switch]$NoNewline
    )
    if (Test-Path -LiteralPath $Path) {
        if ((Test-ReparsePoint $Path) -or
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Refusing to replace unsafe artifact: $Path"
        }
    }
    $temporary = Join-Path (Split-Path $Path -Parent) ('.{0}.tmp-{1}' -f (Split-Path $Path -Leaf), [Guid]::NewGuid())
    $content = $Value
    if (-not $NoNewline) { $content += [Environment]::NewLine }
    [IO.File]::WriteAllText($temporary, $content, $script:Utf8NoBom)
    try {
        if ([IO.File]::Exists($Path)) {
            if ((Test-ReparsePoint $Path) -or
                -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "Refusing to replace unsafe artifact: $Path"
            }
            [IO.File]::Replace($temporary, $Path, $null)
        }
        else {
            try { [IO.File]::Move($temporary, $Path) }
            catch {
                if ([IO.File]::Exists($Path)) {
                    if ((Test-ReparsePoint $Path) -or
                        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                        throw "Refusing to replace unsafe artifact: $Path"
                    }
                    [IO.File]::Replace($temporary, $Path, $null)
                }
                else { throw }
            }
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Copy-AtomicFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) {
        if ((Test-ReparsePoint $Destination) -or
            -not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            throw "Refusing to replace unsafe artifact: $Destination"
        }
    }
    $temporary = Join-Path (Split-Path $Destination -Parent) ('.{0}.tmp-{1}' -f (Split-Path $Destination -Leaf), [Guid]::NewGuid())
    [IO.File]::Copy($Source, $temporary, $false)
    try {
        if ([IO.File]::Exists($Destination)) {
            if ((Test-ReparsePoint $Destination) -or
                -not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
                throw "Refusing to replace unsafe artifact: $Destination"
            }
            [IO.File]::Replace($temporary, $Destination, $null)
        }
        else { [IO.File]::Move($temporary, $Destination) }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Add-SafeLogText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $parent = Split-Path $Path -Parent
    if (-not (Test-SafeDirectory $parent)) {
        throw "Refusing to append under unsafe directory: $parent"
    }
    if (Test-Path -LiteralPath $Path) {
        if ((Test-ReparsePoint $Path) -or
            -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Refusing to append to unsafe artifact: $Path"
        }
    }
    [IO.File]::AppendAllText($Path, $Value, $script:Utf8NoBom)
}

function Read-Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [IO.File]::ReadAllText($Path).TrimEnd("`r", "`n")
    }
    return ''
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    }
    catch { return $false }
}

function Normalize-CanonicalDirectoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    if ($root.Length -gt 0 -and $Path.Equals(
            $root, [StringComparison]::OrdinalIgnoreCase)) {
        return $root
    }
    $separators = [char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    return $Path.TrimEnd($separators)
}

function Test-SafeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][AllowEmptyString()][string]$ExpectedParent = ''
    )
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        $canonical = Normalize-CanonicalDirectoryPath $resolvedPath
        if ($ExpectedParent.Length -gt 0) {
            $parentItem = Get-Item -LiteralPath $ExpectedParent -Force -ErrorAction Stop
            if (-not $parentItem.PSIsContainer -or
                ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $false
            }
            $resolvedParent = (Resolve-Path -LiteralPath $ExpectedParent -ErrorAction Stop).ProviderPath
            $canonicalParent = Normalize-CanonicalDirectoryPath $resolvedParent
            if (-not (Split-Path $canonical -Parent).Equals(
                    $canonicalParent, [StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
        }
        return $true
    }
    catch { return $false }
}

function Get-CanonicalDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    return Normalize-CanonicalDirectoryPath $resolvedPath
}

function Resolve-ReviewRootDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    $visited = @{}
    for ($depth = 0; $depth -lt 32; $depth += 1) {
        $key = $current.ToUpperInvariant()
        if ($visited.ContainsKey($key)) {
            throw "Review root reparse cycle detected: $current"
        }
        $visited[$key] = $true
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "Review root is not a directory: $current"
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            $resolvedCurrent = (Resolve-Path -LiteralPath $current -ErrorAction Stop).ProviderPath
            return Normalize-CanonicalDirectoryPath $resolvedCurrent
        }
        $targets = @($item.Target)
        if ($targets.Count -ne 1 -or $null -eq $targets[0] -or
            ([string]$targets[0]).Length -eq 0) {
            throw "Review root reparse target is unavailable: $current"
        }
        $target = [string]$targets[0]
        if ($target.StartsWith('\??\', [StringComparison]::Ordinal)) {
            $target = $target.Substring(4)
        }
        elseif ($target.StartsWith('\\?\', [StringComparison]::Ordinal)) {
            $target = $target.Substring(4)
        }
        if (-not [IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path $current -Parent) $target
        }
        $current = [IO.Path]::GetFullPath($target)
        if (-not (Test-Path -LiteralPath $current -PathType Container)) {
            throw "Review root reparse target is missing or not a directory: $current"
        }
    }
    throw 'Review root reparse depth exceeds 32 components'
}

function Initialize-ReviewRoot {
    $rawRoot = $env:SUPERARTES_REVIEW_TMPDIR
    if (-not $rawRoot) {
        $temporaryRoot = $env:TEMP
        if (-not $temporaryRoot) { $temporaryRoot = [IO.Path]::GetTempPath() }
        $temporaryRoot = Get-CanonicalDirectory $temporaryRoot
        $rawRoot = Join-Path $temporaryRoot 'superartes-external-review'
    }
    if (-not (Test-Path -LiteralPath $rawRoot)) {
        [void][IO.Directory]::CreateDirectory($rawRoot)
    }
    $resolvedRoot = Resolve-ReviewRootDirectory $rawRoot
    if (-not (Test-SafeDirectory $resolvedRoot)) {
        throw "Review root target is not a safe ordinary directory: $resolvedRoot"
    }
    return $resolvedRoot
}

function ConvertTo-CimCreationToken {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($null -eq $Value) { throw 'CIM CreationDate is missing' }
    if ($Value -is [DateTime]) {
        $creationDate = [DateTime]$Value
    }
    else {
        $text = [string]$Value
        if ($text.Length -eq 0) { throw 'CIM CreationDate is missing' }
        $creationDate = [Management.ManagementDateTimeConverter]::ToDateTime($text)
    }
    return $creationDate.ToUniversalTime().Ticks.ToString(
        [Globalization.CultureInfo]::InvariantCulture)
}

function Get-ProcessStartToken {
    param([Parameter(Mandatory = $true)][int]$Id)
    try {
        $process = Get-Process -Id $Id -ErrorAction Stop
        return ConvertTo-CimCreationToken $process.StartTime
    }
    catch { return '' }
}

function Test-ProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ExpectedStart
    )
    $numericId = 0
    if (-not [int]::TryParse($ProcessId, [ref]$numericId) -or $numericId -le 0 -or
        $ExpectedStart.Length -eq 0) { return $false }
    $actual = Get-ProcessStartToken $numericId
    return $actual.Length -gt 0 -and $actual -ceq $ExpectedStart
}

function Get-ProcessIdentityState {
    param(
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ExpectedStart
    )
    $numericId = 0
    if (-not [int]::TryParse($ProcessId, [ref]$numericId) -or $numericId -le 0 -or
        $ExpectedStart.Length -eq 0) { return 'Unverifiable' }
    if ($env:SUPERARTES_REVIEW_TEST_FORCE_UNVERIFIABLE_PID -ceq $ProcessId) {
        return 'Unverifiable'
    }
    try {
        $process = Get-Process -Id $numericId -ErrorAction Stop
        $actual = ConvertTo-CimCreationToken $process.StartTime
        if ($actual -ceq $ExpectedStart) { return 'Match' }
        return 'Mismatch'
    }
    catch {
        try {
            $processes = @(Get-CimInstance Win32_Process -Filter "ProcessId = $numericId" -ErrorAction Stop)
            if ($processes.Count -eq 0) { return 'Absent' }
            $actual = ConvertTo-CimCreationToken $processes[0].CreationDate
            if ($actual -ceq $ExpectedStart) { return 'Match' }
            return 'Mismatch'
        }
        catch { return 'Unverifiable' }
    }
}

function Get-CimProcessIdentityState {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ExpectedCreationToken
    )
    if ($ExpectedCreationToken.Length -eq 0) { return 'Unverifiable' }
    try {
        $records = @(Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop)
        if ($records.Count -eq 0) { return 'Absent' }
        if ($records.Count -ne 1 -or $null -eq $records[0].CreationDate) {
            return 'Unverifiable'
        }
        $actual = ConvertTo-CimCreationToken $records[0].CreationDate
        if ($actual -ceq $ExpectedCreationToken) { return 'Match' }
        return 'Mismatch'
    }
    catch { return 'Unverifiable' }
}

function Test-ReviewerIdentity {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    return Test-ProcessIdentity (Read-Artifact (Join-Path $RunDirectory 'reviewer-pid')) (Read-Artifact (Join-Path $RunDirectory 'reviewer-start'))
}

function Test-SupervisorIdentity {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    return Test-ProcessIdentity (Read-Artifact (Join-Path $RunDirectory 'supervisor-pid')) (Read-Artifact (Join-Path $RunDirectory 'supervisor-start'))
}

function Test-TerminalState {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$State)
    return @('exited', 'launch-failed', 'cancelled') -contains $State
}

function Test-RegularArtifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Test-ReparsePoint $Path)
}

function Test-ArtifactAccessibleForRemoval {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-RegularArtifact $Path)) { return $false }
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::None)
        return $true
    }
    catch { return $false }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-RunDirectory {
    param([Parameter(Mandatory = $true)][string]$Requested)
    $script:ValidatedRun = ''
    if (-not (Test-SafeDirectory $script:ReviewRoot) -or
        -not (Test-Path -LiteralPath $Requested -PathType Container) -or
        (Test-ReparsePoint $Requested)) { return 65 }
    try { $canonical = Get-CanonicalDirectory $Requested }
    catch { return 65 }
    $parent = Split-Path $canonical -Parent
    $leaf = Split-Path $canonical -Leaf
    if (-not $parent.Equals($script:ReviewRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $leaf.StartsWith('run-', [StringComparison]::Ordinal)) { return 65 }
    foreach ($required in @('run-path', 'run-id', 'marker')) {
        if (-not (Test-RegularArtifact (Join-Path $canonical $required))) { return 65 }
    }
    if ((Read-Artifact (Join-Path $canonical 'run-path')) -cne $canonical) { return 65 }
    $runId = Read-Artifact (Join-Path $canonical 'run-id')
    if ((Read-Artifact (Join-Path $canonical 'marker')) -cne "superartes-external-review:$runId") { return 65 }
    $script:ValidatedRun = $canonical
    return 0
}

function Resolve-ReviewerCommand {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Source
}

function Test-RequiredText {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Required
    )
    if ($Value.Contains($Required)) { return 0 }
    [Console]::Error.WriteLine("Required capability missing: $Required")
    return 2
}

function Invoke-ReviewerCommandCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][AllowEmptyCollection()][string[]]$Arguments = @()
    )
    $captureId = [Guid]::NewGuid().ToString('N')
    $standardOutputPath = Join-Path $script:ReviewRoot (
        ".preflight-$PID-$captureId.stdout")
    $standardErrorPath = Join-Path $script:ReviewRoot (
        ".preflight-$PID-$captureId.stderr")
    $capture = New-Object PSObject -Property @{
        ExitCode = 1
        StandardOutput = ''
        StandardError = ''
    }
    try {
        foreach ($path in @($standardOutputPath, $standardErrorPath)) {
            $stream = [IO.File]::Open(
                $path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
                [IO.FileShare]::None)
            $stream.Dispose()
        }
        Invoke-ReviewerCommand -Command $Command -Arguments $Arguments `
            -StandardOutputPath $standardOutputPath `
            -StandardErrorPath $standardErrorPath
        $capture.ExitCode = [int]$script:ReviewerCommandExitCode
        $capture.StandardOutput = [IO.File]::ReadAllText($standardOutputPath)
        $capture.StandardError = [IO.File]::ReadAllText($standardErrorPath)
        return $capture
    }
    finally {
        foreach ($path in @($standardOutputPath, $standardErrorPath)) {
            if (Test-RegularArtifact $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Test-Profile {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -ne 1) { return 64 }
    $profile = $Arguments[0]
    if ($profile -eq 'claude-prompt') {
        $launcher = Resolve-ReviewerCommand 'claude'
        $helpArguments = @('--help')
        $flags = @('--safe-mode', '--permission-mode', '--output-format', '--session-id', '--tools', '--allowedTools')
    }
    elseif ($profile -eq 'codex-prompt') {
        $launcher = Resolve-ReviewerCommand 'codex'
        $helpArguments = @('exec', '--help')
        $flags = @('--sandbox', '--skip-git-repo-check', '--output-last-message')
    }
    elseif ($profile -eq 'codex-review') {
        $launcher = Resolve-ReviewerCommand 'codex'
        $helpArguments = @('exec', 'review', '--help')
        $flags = @('--uncommitted', '--base', '--commit', '--skip-git-repo-check', '--output-last-message')
    }
    else {
        [Console]::Error.WriteLine("Unknown profile: $profile")
        return 64
    }
    if ($null -eq $launcher) { return 127 }
    $versionCapture = Invoke-ReviewerCommandCapture `
        -Command $launcher -Arguments @('--version')
    if ($versionCapture.ExitCode -ne 0) { return 2 }
    [void]$versionCapture.StandardOutput.Length
    [void]$versionCapture.StandardError.Length
    $helpCapture = Invoke-ReviewerCommandCapture `
        -Command $launcher -Arguments $helpArguments
    if ($helpCapture.ExitCode -ne 0) { return 2 }
    $help = $helpCapture.StandardOutput + [Environment]::NewLine +
        $helpCapture.StandardError
    foreach ($flag in $flags) {
        $result = Test-RequiredText $help $flag
        if ($result -ne 0) { return $result }
    }
    return 0
}

function Release-Registry {
    if (-not $script:RegistryOwned) { return }
    $lock = Join-Path $script:ReviewRoot '.registry-lock'
    if ((Test-SafeDirectory $lock $script:ReviewRoot) -and
        (Read-Artifact (Join-Path $lock 'owner-pid')) -ceq $script:RegistryOwnerPid -and
        (Test-SafeDirectory $lock $script:ReviewRoot) -and
        (Read-Artifact (Join-Path $lock 'owner-start')) -ceq $script:RegistryOwnerStart) {
        [void](Remove-OwnedLock $lock $script:ReviewRoot $script:RegistryOwnerPid $script:RegistryOwnerStart)
    }
    $script:RegistryOwned = $false
}

function Get-LockOwner {
    param(
        [Parameter(Mandatory = $true)][string]$LockDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedParent
    )
    if (-not (Test-SafeDirectory $LockDirectory $ExpectedParent)) { return $null }
    $pidPath = Join-Path $LockDirectory 'owner-pid'
    $startPath = Join-Path $LockDirectory 'owner-start'
    if (-not (Test-SafeDirectory $LockDirectory $ExpectedParent) -or
        -not (Test-RegularArtifact $pidPath)) { return $null }
    $ownerPid = Read-Artifact $pidPath
    if (-not (Test-SafeDirectory $LockDirectory $ExpectedParent) -or
        -not (Test-RegularArtifact $startPath)) { return $null }
    $ownerStart = Read-Artifact $startPath
    $owner = New-Object PSObject -Property @{
        ProcessId = $ownerPid
        Start = $ownerStart
    }
    $numeric = 0
    $numericStart = 0L
    if (-not [int]::TryParse($owner.ProcessId, [ref]$numeric) -or $numeric -le 0 -or
        -not [long]::TryParse($owner.Start, [ref]$numericStart) -or
        $numericStart -le 0) { return $null }
    return $owner
}

function Remove-StaleLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedParent
    )
    $owner = Get-LockOwner $LockDirectory $ExpectedParent
    if ($null -eq $owner) { return $false }
    $identityState = Get-ProcessIdentityState $owner.ProcessId $owner.Start
    if (@('Match', 'Unverifiable') -contains $identityState) { return $false }
    return Remove-OwnedLock $LockDirectory $ExpectedParent $owner.ProcessId $owner.Start
}

function Remove-OwnedLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        [Parameter(Mandatory = $true)][string]$ExpectedPid,
        [Parameter(Mandatory = $true)][string]$ExpectedStart
    )
    try {
        foreach ($entry in @(@('owner-pid', $ExpectedPid), @('owner-start', $ExpectedStart))) {
            if (-not (Test-SafeDirectory $LockDirectory $ExpectedParent)) { return $false }
            $path = Join-Path $LockDirectory $entry[0]
            if (-not (Test-RegularArtifact $path) -or (Read-Artifact $path) -cne $entry[1]) {
                return $false
            }
        }
        foreach ($name in @('owner-pid', 'owner-start')) {
            if (-not (Test-SafeDirectory $LockDirectory $ExpectedParent)) { return $false }
            $path = Join-Path $LockDirectory $name
            if (-not (Test-RegularArtifact $path)) { return $false }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        if (-not (Test-SafeDirectory $LockDirectory $ExpectedParent)) { return $false }
        if (@(Get-ChildItem -LiteralPath $LockDirectory -Force -ErrorAction Stop).Count -ne 0) {
            return $false
        }
        if (-not (Test-SafeDirectory $LockDirectory $ExpectedParent)) { return $false }
        [IO.Directory]::Delete($LockDirectory, $false)
        return $true
    }
    catch { return $false }
}

function Acquire-Registry {
    $lock = Join-Path $script:ReviewRoot '.registry-lock'
    $script:RegistryOwnerPid = $PID.ToString()
    $script:RegistryOwnerStart = Get-ProcessStartToken $PID
    if ($script:RegistryOwnerStart.Length -eq 0) { return 75 }
    for ($attempt = 0; $attempt -lt 100; $attempt += 1) {
        try {
            [void](New-Item -ItemType Directory -Path $lock -ErrorAction Stop)
            $script:RegistryOwned = $true
            if (-not (Test-SafeDirectory $lock $script:ReviewRoot)) { return 75 }
            Write-AtomicText (Join-Path $lock 'owner-pid') $script:RegistryOwnerPid
            if (-not (Test-SafeDirectory $lock $script:ReviewRoot)) { return 75 }
            Write-AtomicText (Join-Path $lock 'owner-start') $script:RegistryOwnerStart
            return 0
        }
        catch {
            if ((Test-Path -LiteralPath $lock) -and
                -not (Test-SafeDirectory $lock $script:ReviewRoot)) {
                [Console]::Error.WriteLine("Registry lock is not a safe ordinary directory: $lock")
                return 75
            }
            $owner = Get-LockOwner $lock $script:ReviewRoot
            if ($null -eq $owner) {
                if ($attempt -ge 99) {
                    [Console]::Error.WriteLine("Registry lock owner metadata is missing or malformed: $lock")
                    return 75
                }
            }
            else {
                $ownerState = Get-ProcessIdentityState $owner.ProcessId $owner.Start
                if (@('Absent', 'Mismatch') -contains $ownerState -and
                    (Remove-StaleLock $lock $script:ReviewRoot)) {
                    [Console]::Error.WriteLine("Reclaimed stale registry lock: $lock")
                }
            }
            Start-Sleep -Milliseconds 10
        }
    }
    [Console]::Error.WriteLine("Registry lock unavailable: $lock")
    return 75
}

function Get-MatchingRuns {
    param([Parameter(Mandatory = $true)][string]$ReviewKey)
    $matches = @()
    foreach ($candidate in @(Get-ChildItem -LiteralPath $script:ReviewRoot -Directory -Filter 'run-*' -ErrorAction SilentlyContinue)) {
        if (($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $keyPath = Join-Path $candidate.FullName 'review-key'
        if (-not (Test-Path -LiteralPath $keyPath)) { continue }
        if (-not (Test-RegularArtifact $keyPath)) {
            throw "Published review key is not a regular file: $keyPath"
        }
        if ((Read-Artifact $keyPath) -ceq $ReviewKey) {
            $validation = Test-RunDirectory $candidate.FullName
            if ($validation -ne 0) { throw "Matching review run failed validation: $($candidate.FullName)" }
            $matches += $script:ValidatedRun
        }
    }
    return @($matches)
}

function Set-LaunchFailed {
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$Diagnostic,
        [Parameter()][switch]$SkipDiagnosticLog
    )
    $logPath = Join-Path $RunDirectory 'supervisor-log'
    if ($SkipDiagnosticLog) {
        [Console]::Error.WriteLine("Unsafe supervisor log; diagnostic was not written: $logPath")
        [Console]::Error.WriteLine($Diagnostic)
    }
    else {
        Add-SafeLogText $logPath ($Diagnostic + [Environment]::NewLine)
    }
    Write-AtomicText (Join-Path $RunDirectory 'completed-at') (Get-EpochSeconds)
    Write-AtomicText (Join-Path $RunDirectory 'state') 'launch-failed'
}

function Reconcile-AbandonedRuns {
    param([Parameter()][AllowEmptyCollection()][string[]]$MatchingRuns = @())
    $guard = Get-TestDelay 'SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS'
    if (-not $env:SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS) { $guard = 10 }
    foreach ($candidate in $MatchingRuns) {
        $state = Read-Artifact (Join-Path $candidate 'state')
        if ($state.Length -gt 0 -or (Test-SupervisorIdentity $candidate)) { continue }
        $output = Join-Path $candidate 'supervisor-output'
        $log = Join-Path $candidate 'supervisor-log'
        if (-not (Test-RegularArtifact $output) -or -not (Test-RegularArtifact $log)) {
            $unsafeLog = (Test-Path -LiteralPath $log) -and -not (Test-RegularArtifact $log)
            Set-LaunchFailed $candidate 'Reconciled abandoned pre-launch run after registry owner death' `
                -SkipDiagnosticLog:$unsafeLog
            continue
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($guard)
        while ([DateTime]::UtcNow -lt $deadline -and
            (Read-Artifact (Join-Path $candidate 'state')).Length -eq 0 -and
            -not (Test-SupervisorIdentity $candidate)) {
            Start-Sleep -Milliseconds 100
        }
        if ((Read-Artifact (Join-Path $candidate 'state')).Length -eq 0 -and
            -not (Test-SupervisorIdentity $candidate)) {
            Set-LaunchFailed $candidate 'Reconciled launch intent without supervisor publication'
        }
    }
}

function Quote-WindowsArgument {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter()][switch]$AlwaysQuote
    )
    if (-not $AlwaysQuote -and $Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes += 1; continue }
        if ($character -eq '"') {
            [void]$builder.Append((('\' * ($slashes * 2 + 1)) -join ''))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append((('\' * $slashes) -join '')); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append((('\' * ($slashes * 2)) -join '')) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Test-SafeReviewerCommandValue {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return $Value.IndexOf([char]0) -lt 0 -and
        $Value.IndexOf("`r", [StringComparison]::Ordinal) -lt 0 -and
        $Value.IndexOf("`n", [StringComparison]::Ordinal) -lt 0 -and
        $Value.IndexOf('"', [StringComparison]::Ordinal) -lt 0
}

function Invoke-ReviewerCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [Parameter(Mandatory = $true)][string]$StandardErrorPath,
        [Parameter()][AllowEmptyString()][string]$StandardInputPath = ''
    )
    $script:ReviewerCommandExitCode = 1
    if (-not (Test-SafeReviewerCommandValue $Command)) {
        throw 'Reviewer command path contains a character that cannot be safely dispatched'
    }
    foreach ($argument in $Arguments) {
        if (-not (Test-SafeReviewerCommandValue $argument)) {
            throw 'Reviewer argument contains a character that cannot be safely dispatched'
        }
    }
    $extension = [IO.Path]::GetExtension($Command)
    $isBatch = $extension.Equals('.cmd', [StringComparison]::OrdinalIgnoreCase) -or
        $extension.Equals('.bat', [StringComparison]::OrdinalIgnoreCase)
    $processParameters = @{
        FilePath = $Command
        RedirectStandardOutput = $StandardOutputPath
        RedirectStandardError = $StandardErrorPath
        WindowStyle = 'Hidden'
        PassThru = $true
    }
    if ($StandardInputPath.Length -gt 0) {
        $processParameters.RedirectStandardInput = $StandardInputPath
    }
    if (-not $isBatch) {
        $quotedArguments = @()
        foreach ($argument in $Arguments) {
            $quotedArguments += Quote-WindowsArgument $argument -AlwaysQuote
        }
        $processParameters.ArgumentList = $quotedArguments -join ' '
        $process = Start-Process @processParameters
        $process.WaitForExit()
        $script:ReviewerCommandExitCode = [int]$process.ExitCode
        return
    }

    $commandValues = @($Command) + @($Arguments)
    $environmentNames = @()
    $previousValues = @{}
    $previouslyPresent = @{}
    $placeholders = New-Object 'Collections.Generic.List[string]'
    $processEnvironment = [Environment]::GetEnvironmentVariables('Process')
    try {
        for ($index = 0; $index -lt $commandValues.Count; $index += 1) {
            $name = "SUPERARTES_REVIEW_COMMAND_$index"
            $environmentNames += $name
            $previouslyPresent[$name] = $processEnvironment.Contains($name)
            $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $commandValues[$index], 'Process')
            [void]$placeholders.Add(('"%{0}%"' -f $name))
        }
        $commandTemplate = '"' + ($placeholders -join ' ') + '"'
        [string]$comSpec = [Environment]::GetEnvironmentVariable('ComSpec', 'Process')
        if ($comSpec.Length -eq 0) { throw 'ComSpec is unavailable for batch reviewer dispatch' }
        $comSpecArguments = '/d /s /v:off /c ' + $commandTemplate
        $processParameters.FilePath = $comSpec
        $processParameters.ArgumentList = $comSpecArguments
        $process = Start-Process @processParameters
        $process.WaitForExit()
        $script:ReviewerCommandExitCode = [int]$process.ExitCode
    }
    finally {
        foreach ($name in $environmentNames) {
            if ($previouslyPresent[$name]) {
                [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
            }
            else {
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }
        }
    }
}

function Start-ReviewerProcess {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    $profile = Read-Artifact (Join-Path $RunDirectory 'profile')
    $workDirectory = Read-Artifact (Join-Path $RunDirectory 'work-dir')
    if (-not (Test-Path -LiteralPath $workDirectory -PathType Container)) { return $null }
    if (@('claude-prompt', 'codex-prompt', 'codex-review') -notcontains $profile) {
        return $null
    }
    $powerShellExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
    $argumentLine = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Quote-WindowsArgument $PSCommandPath -AlwaysQuote),
        'RunReviewer', (Quote-WindowsArgument $RunDirectory -AlwaysQuote)
    ) -join ' '
    $parameters = @{
        FilePath = $powerShellExecutable
        ArgumentList = $argumentLine
        WorkingDirectory = $workDirectory
        RedirectStandardInput = 'NUL'
        WindowStyle = 'Hidden'
        PassThru = $true
    }
    $previousClaudeTool = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_USE_POWERSHELL_TOOL', 'Process')
    try {
        if ($profile -eq 'claude-prompt') {
            [Environment]::SetEnvironmentVariable('CLAUDE_CODE_USE_POWERSHELL_TOOL', '1', 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable('CLAUDE_CODE_USE_POWERSHELL_TOOL', $null, 'Process')
        }
        return Start-Process @parameters
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            'CLAUDE_CODE_USE_POWERSHELL_TOOL', $previousClaudeTool, 'Process')
    }
}

function Invoke-RunReviewer {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -ne 1) { return 64 }
    $validation = Test-RunDirectory $Arguments[0]
    if ($validation -ne 0) { return $validation }
    $runDirectory = $script:ValidatedRun
    $profile = Read-Artifact (Join-Path $runDirectory 'profile')
    $standardInput = ''
    $standardOutput = Join-Path $runDirectory 'reviewer-output'
    $standardError = Join-Path $runDirectory 'reviewer-log'
    if ($profile -eq 'claude-prompt') {
        $standardInput = Join-Path $runDirectory 'prompt'
        $standardOutput = Join-Path $runDirectory 'result'
        $reviewerCommand = Resolve-ReviewerCommand 'claude'
        $session = Read-Artifact (Join-Path $runDirectory 'provider-session')
        $reviewerArguments = @(
            '-p', '--safe-mode', '--permission-mode', 'dontAsk',
            '--tools', 'Read,Glob,Grep,PowerShell',
            '--allowedTools', 'Read,Glob,Grep,PowerShell(git diff *),PowerShell(git status *),PowerShell(git rev-parse *),PowerShell(git cat-file *),PowerShell(git show *),PowerShell(git log *)',
            '--output-format', 'json', '--session-id', $session
        )
    }
    elseif ($profile -eq 'codex-prompt') {
        $standardInput = Join-Path $runDirectory 'prompt'
        $reviewerCommand = Resolve-ReviewerCommand 'codex'
        $reviewerArguments = @(
            'exec', '-', '-s', 'read-only', '--skip-git-repo-check',
            '-o', (Join-Path $runDirectory 'result')
        )
    }
    elseif ($profile -eq 'codex-review') {
        $reviewerCommand = Resolve-ReviewerCommand 'codex'
        $scope = Read-Artifact (Join-Path $runDirectory 'scope-kind')
        if (@('uncommitted', 'base', 'commit') -notcontains $scope) { return 64 }
        $reviewerArguments = @('exec', 'review', "--$scope")
        if ($scope -ne 'uncommitted') {
            $scopeValue = Read-Artifact (Join-Path $runDirectory 'scope-value')
            if ($scopeValue.Length -eq 0) { return 64 }
            $reviewerArguments += $scopeValue
        }
        $reviewerArguments += @(
            '--skip-git-repo-check', '-o', (Join-Path $runDirectory 'result')
        )
    }
    else { return 64 }
    if ($null -eq $reviewerCommand) { return 127 }
    Invoke-ReviewerCommand -Command $reviewerCommand -Arguments $reviewerArguments `
        -StandardInputPath $standardInput -StandardOutputPath $standardOutput `
        -StandardErrorPath $standardError
    return $script:ReviewerCommandExitCode
}

function Wait-ForCancellationTerminalState {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    $cancelPath = Join-Path $RunDirectory 'cancel-requested'
    $lockDirectory = Join-Path $RunDirectory '.cancel-lock'
    while ($true) {
        $cancel = Read-Artifact $cancelPath
        if ($cancel.StartsWith('accepted:')) { return 'cancelled' }
        if ($cancel.Length -eq 0 -or $cancel.StartsWith('rejected:')) { return 'exited' }
        if (-not $cancel.StartsWith('pending:')) {
            Start-Sleep -Milliseconds 100
            continue
        }
        if (-not (Test-Path -LiteralPath $lockDirectory) -or
            -not (Test-SafeDirectory $lockDirectory $RunDirectory)) {
            Start-Sleep -Milliseconds 100
            continue
        }
        $owner = Get-LockOwner $lockDirectory $RunDirectory
        if ($null -eq $owner) {
            Start-Sleep -Milliseconds 100
            continue
        }
        $ownerState = Get-ProcessIdentityState $owner.ProcessId $owner.Start
        if (@('Match', 'Unverifiable') -contains $ownerState) {
            Start-Sleep -Milliseconds 100
            continue
        }
        if (Remove-StaleLock $lockDirectory $RunDirectory) {
            Write-AtomicText $cancelPath ("rejected:abandoned:" + (Get-EpochSeconds))
            return 'exited'
        }
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-Supervise {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -ne 1) { return 64 }
    $validation = Test-RunDirectory $Arguments[0]
    if ($validation -ne 0) { return $validation }
    $runDirectory = $script:ValidatedRun
    $supervisorStart = Get-ProcessStartToken $PID
    if ($supervisorStart.Length -eq 0) {
        [Console]::Error.WriteLine('Could not establish supervisor identity')
        return 0
    }
    Write-AtomicText (Join-Path $runDirectory 'supervisor-pid') $PID.ToString()
    Write-AtomicText (Join-Path $runDirectory 'supervisor-start') $supervisorStart
    $ready = $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE
    if ($ready) { Write-AtomicText $ready $PID.ToString() }
    $delay = Get-TestDelay 'SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_DELAY'
    if ($delay -gt 0) { Start-Sleep -Seconds $delay }
    $lockResult = Acquire-Registry
    if ($lockResult -ne 0) { return $lockResult }
    try {
        $validation = Test-RunDirectory $runDirectory
        if ($validation -ne 0) { return $validation }
        $state = Read-Artifact (Join-Path $runDirectory 'state')
        if (Test-TerminalState $state) { return 0 }
        $delay = Get-TestDelay 'SUPERARTES_REVIEW_TEST_SETUP_DELAY'
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        try { $reviewer = Start-ReviewerProcess $runDirectory }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            $reviewer = $null
        }
        if ($null -eq $reviewer) {
            Write-AtomicText (Join-Path $runDirectory 'completed-at') (Get-EpochSeconds)
            Write-AtomicText (Join-Path $runDirectory 'state') 'launch-failed'
            return 0
        }
        $rawReviewerStart = ''
        $reviewerStartTime = $null
        try {
            $reviewerStartTime = $reviewer.StartTime
            $rawReviewerStart = ConvertTo-CimCreationToken $reviewerStartTime
        }
        catch { $rawReviewerStart = '' }
        $reviewerStart = $rawReviewerStart
        if ($env:SUPERARTES_REVIEW_TEST_FORCE_IDENTITY_FAILURE -eq '1') { $reviewerStart = '' }
        if ($reviewerStart.Length -eq 0) {
            $unpublishedDescendants = @()
            $safeToSignal = $false
            if ($null -ne $reviewerStartTime) {
                try {
                    $unpublishedDescendants = @(Get-DescendantSnapshot $reviewer.Id $reviewerStartTime)
                    Confirm-DescendantSnapshot $reviewer.Id $reviewerStartTime `
                        $unpublishedDescendants
                    $safeToSignal = (Get-ProcessStartToken $reviewer.Id) -ceq $rawReviewerStart
                }
                catch {
                    [Console]::Error.WriteLine($_.Exception.Message)
                    $unpublishedDescendants = @()
                }
            }
            if ($safeToSignal) {
                Stop-Process -Id $reviewer.Id -Force -ErrorAction SilentlyContinue
                foreach ($child in @($unpublishedDescendants | Sort-Object Depth -Descending)) {
                    if ((Get-CimProcessIdentityState $child.Id $child.CimCreationToken) -eq 'Match') {
                        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            $reviewer.WaitForExit()
            Write-AtomicText (Join-Path $runDirectory 'completed-at') (Get-EpochSeconds)
            Write-AtomicText (Join-Path $runDirectory 'state') 'launch-failed'
            return 0
        }
        Write-AtomicText (Join-Path $runDirectory 'reviewer-pid') $reviewer.Id.ToString()
        Write-AtomicText (Join-Path $runDirectory 'reviewer-start') $reviewerStart
        Write-AtomicText (Join-Path $runDirectory 'reviewer-pgid') 'not-applicable'
        Write-AtomicText (Join-Path $runDirectory 'started-at') (Get-EpochSeconds)
        Write-AtomicText (Join-Path $runDirectory 'state') 'running'
    }
    finally { Release-Registry }
    $reviewer.WaitForExit()
    Write-AtomicText (Join-Path $runDirectory 'exit-code') $reviewer.ExitCode.ToString()
    Write-AtomicText (Join-Path $runDirectory 'completed-at') (Get-EpochSeconds)
    $terminalState = Wait-ForCancellationTerminalState $runDirectory
    Write-AtomicText (Join-Path $runDirectory 'state') $terminalState
    return 0
}

function Start-HiddenSupervisor {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    if ($env:SUPERARTES_REVIEW_TEST_FORCE_SUPERVISOR_START_EXCEPTION -eq '1') {
        throw 'Forced hidden supervisor Start-Process exception'
    }
    $powerShellExecutable = (Get-Process -Id $PID).Path
    $argumentLine = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Quote-WindowsArgument $PSCommandPath -AlwaysQuote),
        'Supervise', (Quote-WindowsArgument $RunDirectory -AlwaysQuote)
    ) -join ' '
    return Start-Process -FilePath $powerShellExecutable -ArgumentList $argumentLine `
        -RedirectStandardInput 'NUL' `
        -RedirectStandardOutput (Join-Path $RunDirectory 'supervisor-output') `
        -RedirectStandardError (Join-Path $RunDirectory 'supervisor-log') `
        -WindowStyle Hidden -PassThru
}

function Invoke-Start {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -lt 1) { return 64 }
    $afterTerminal = ''
    if ($Arguments[0] -ceq '--after-terminal') {
        if ($Arguments.Count -lt 3) { return 64 }
        $afterTerminal = $Arguments[1]
        $Arguments = @($Arguments[2..($Arguments.Count - 1)])
    }
    $profile = $Arguments[0]
    $promptFile = ''
    $scopeKind = ''
    $scopeValue = ''
    if ($profile -eq 'claude-prompt' -or $profile -eq 'codex-prompt') {
        if ($Arguments.Count -ne 4) { return 64 }
        $reviewKey = $Arguments[1]
        $requestedWorkDirectory = $Arguments[2]
        $promptFile = $Arguments[3]
        if (-not (Test-Path -LiteralPath $promptFile -PathType Leaf)) { return 64 }
        try {
            $promptStream = [IO.File]::Open($promptFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $promptStream.Dispose()
        }
        catch { return 64 }
    }
    elseif ($profile -eq 'codex-review') {
        if ($Arguments.Count -lt 4) { return 64 }
        $reviewKey = $Arguments[1]
        $requestedWorkDirectory = $Arguments[2]
        $scopeKind = $Arguments[3]
        if ($scopeKind -eq 'uncommitted') {
            if ($Arguments.Count -ne 4) { return 64 }
        }
        elseif ($scopeKind -eq 'base' -or $scopeKind -eq 'commit') {
            if ($Arguments.Count -ne 5 -or $Arguments[4].Length -eq 0 -or
                -not (Test-SafeReviewerCommandValue $Arguments[4])) { return 64 }
            $scopeValue = $Arguments[4]
        }
        else { return 64 }
    }
    else {
        [Console]::Error.WriteLine("Unknown profile: $profile")
        return 64
    }
    if ($reviewKey.Length -eq 0 -or -not (Test-Path -LiteralPath $requestedWorkDirectory -PathType Container)) { return 64 }
    try { $workDirectory = Get-CanonicalDirectory $requestedWorkDirectory }
    catch { return 64 }
    $preflight = Test-Profile @($profile)
    if ($preflight -ne 0) { return $preflight }
    if ($profile -eq 'claude-prompt') { $provider = 'claude'; $providerSession = [Guid]::NewGuid().ToString() }
    else { $provider = 'codex'; $providerSession = 'not-applicable' }
    $runId = [Guid]::NewGuid().ToString()
    $runDirectory = Join-Path $script:ReviewRoot "run-$runId"
    $lockResult = Acquire-Registry
    if ($lockResult -ne 0) { return $lockResult }
    try {
        try { $matching = @(Get-MatchingRuns $reviewKey) }
        catch { [Console]::Error.WriteLine($_.Exception.Message); return 4 }
        Reconcile-AbandonedRuns $matching
        $nonterminal = @()
        foreach ($candidate in $matching) {
            if (-not (Test-TerminalState (Read-Artifact (Join-Path $candidate 'state')))) { $nonterminal += $candidate }
        }
        if ($nonterminal.Count -gt 1) {
            [Console]::Error.WriteLine(
                'Invariant corruption: multiple nonterminal matching runs: ' + ($nonterminal -join ', '))
            return 4
        }
        if ($nonterminal.Count -eq 1) {
            [Console]::Out.WriteLine('STATE=outstanding')
            [Console]::Out.WriteLine("RUN_DIR=$($nonterminal[0])")
            return 12
        }
        $tail = ''
        if ($matching.Count -gt 0) {
            $tails = @()
            foreach ($candidate in $matching) {
                $named = $false
                foreach ($other in $matching) {
                    if ((Read-Artifact (Join-Path $other 'previous-run')) -ceq $candidate) { $named = $true; break }
                }
                if (-not $named) { $tails += $candidate }
            }
            if ($tails.Count -ne 1) {
                [Console]::Error.WriteLine(
                    'Invariant corruption: matching chain does not have one tail. Matching runs: ' + ($matching -join ', '))
                return 4
            }
            $tail = $tails[0]
            if ($afterTerminal.Length -eq 0) {
                [Console]::Out.WriteLine('STATE=outstanding')
                [Console]::Out.WriteLine("RUN_DIR=$tail")
                return 12
            }
            $validation = Test-RunDirectory $afterTerminal
            if ($validation -ne 0) { return $validation }
            if (-not $script:ValidatedRun.Equals($tail, [StringComparison]::OrdinalIgnoreCase)) {
                [Console]::Error.WriteLine("Requested previous run is not the unique chain tail: $tail")
                return 4
            }
        }
        elseif ($afterTerminal.Length -gt 0) { [Console]::Error.WriteLine('No retained matching terminal run for --after-terminal'); return 4 }

        [void](New-Item -ItemType Directory -Path $runDirectory)
        $runDirectory = Get-CanonicalDirectory $runDirectory
        Write-AtomicText (Join-Path $runDirectory 'run-id') $runId
        Write-AtomicText (Join-Path $runDirectory 'run-path') $runDirectory
        Write-AtomicText (Join-Path $runDirectory 'marker') "superartes-external-review:$runId"
        Write-AtomicText (Join-Path $runDirectory 'profile') $profile
        Write-AtomicText (Join-Path $runDirectory 'provider') $provider
        Write-AtomicText (Join-Path $runDirectory 'provider-session') $providerSession
        Write-AtomicText (Join-Path $runDirectory 'work-dir') $workDirectory
        if ($promptFile.Length -gt 0) { Copy-AtomicFile $promptFile (Join-Path $runDirectory 'prompt') }
        else {
            Write-AtomicText (Join-Path $runDirectory 'scope-kind') $scopeKind
            if ($scopeKind -eq 'uncommitted') { Write-AtomicText (Join-Path $runDirectory 'scope-value') '' -NoNewline }
            else { Write-AtomicText (Join-Path $runDirectory 'scope-value') $scopeValue }
        }
        if ($afterTerminal.Length -gt 0) { Write-AtomicText (Join-Path $runDirectory 'previous-run') $tail }
        $pause = $env:SUPERARTES_REVIEW_TEST_PRE_REVIEW_KEY_PAUSE_FILE
        if ($pause) {
            Write-AtomicText $pause $PID.ToString()
            while (Test-Path -LiteralPath $pause) { Start-Sleep -Milliseconds 50 }
        }
        # review-key is the commit marker and is deliberately published last.
        Write-AtomicText (Join-Path $runDirectory 'review-key') $reviewKey
        $pause = $env:SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE
        if ($pause) {
            Write-AtomicText $pause $PID.ToString()
            while (Test-Path -LiteralPath $pause) { Start-Sleep -Milliseconds 50 }
        }
        Write-AtomicText (Join-Path $runDirectory 'supervisor-output') '' -NoNewline
        Write-AtomicText (Join-Path $runDirectory 'supervisor-log') '' -NoNewline
        $pause = $env:SUPERARTES_REVIEW_TEST_POST_INTENT_PAUSE_FILE
        if ($pause) {
            Write-AtomicText $pause $PID.ToString()
            while (Test-Path -LiteralPath $pause) { Start-Sleep -Milliseconds 50 }
        }
        try { [void](Start-HiddenSupervisor $runDirectory) }
        catch {
            $diagnostic = "Could not start hidden supervisor: $($_.Exception.Message)"
            Set-LaunchFailed $runDirectory $diagnostic
            [Console]::Out.WriteLine('STATE=launch-failed')
            [Console]::Out.WriteLine("RUN_DIR=$runDirectory")
            [Console]::Out.WriteLine("RUN_ID=$runId")
            return 0
        }
    }
    finally { Release-Registry }
    for ($waited = 0; $waited -lt 10; $waited += 1) {
        $state = Read-Artifact (Join-Path $runDirectory 'state')
        if (@('running', 'exited', 'launch-failed', 'cancelled') -contains $state) {
            [Console]::Out.WriteLine("STATE=$state")
            [Console]::Out.WriteLine("RUN_DIR=$runDirectory")
            [Console]::Out.WriteLine("RUN_ID=$runId")
            return 0
        }
        Start-Sleep -Seconds 1
    }
    if (Test-SupervisorIdentity $runDirectory) {
        [Console]::Out.WriteLine('STATE=indeterminate')
        [Console]::Out.WriteLine("RUN_DIR=$runDirectory")
        return 4
    }
    Set-LaunchFailed $runDirectory 'Supervisor disappeared before publishing state'
    [Console]::Out.WriteLine('STATE=launch-failed')
    [Console]::Out.WriteLine("RUN_DIR=$runDirectory")
    [Console]::Out.WriteLine("RUN_ID=$runId")
    return 0
}

function Write-Status {
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string]$ReportedState
    )
    $started = Read-Artifact (Join-Path $RunDirectory 'started-at')
    $completed = Read-Artifact (Join-Path $RunDirectory 'completed-at')
    $elapsed = 0
    $startedValue = 0L
    $endValue = 0L
    if ([long]::TryParse($started, [ref]$startedValue)) {
        if (-not [long]::TryParse($completed, [ref]$endValue)) { [void][long]::TryParse((Get-EpochSeconds), [ref]$endValue) }
        if ($endValue -ge $startedValue) { $elapsed = $endValue - $startedValue }
    }
    [Console]::Out.WriteLine("STATE=$ReportedState")
    [Console]::Out.WriteLine("RUN_DIR=$RunDirectory")
    [Console]::Out.WriteLine("PROFILE=$(Read-Artifact (Join-Path $RunDirectory 'profile'))")
    [Console]::Out.WriteLine("PROVIDER=$(Read-Artifact (Join-Path $RunDirectory 'provider'))")
    [Console]::Out.WriteLine("STARTED_AT=$started")
    [Console]::Out.WriteLine("ELAPSED_SECONDS=$elapsed")
    [Console]::Out.WriteLine("RESULT=$(Join-Path $RunDirectory 'result')")
    [Console]::Out.WriteLine("REVIEWER_OUTPUT=$(Join-Path $RunDirectory 'reviewer-output')")
    [Console]::Out.WriteLine("REVIEWER_LOG=$(Join-Path $RunDirectory 'reviewer-log')")
    [Console]::Out.WriteLine("SUPERVISOR_OUTPUT=$(Join-Path $RunDirectory 'supervisor-output')")
    [Console]::Out.WriteLine("SUPERVISOR_LOG=$(Join-Path $RunDirectory 'supervisor-log')")
    foreach ($field in @(@('reviewer-pid', 'REVIEWER_PID'), @('exit-code', 'EXIT_CODE'), @('completed-at', 'COMPLETED_AT'))) {
        $path = Join-Path $RunDirectory $field[0]
        if (Test-Path -LiteralPath $path -PathType Leaf) { [Console]::Out.WriteLine("$($field[1])=$(Read-Artifact $path)") }
    }
}

function Invoke-Status {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -ne 1) { return 64 }
    $validation = Test-RunDirectory $Arguments[0]
    if ($validation -ne 0) { return $validation }
    $runDirectory = $script:ValidatedRun
    $state = Read-Artifact (Join-Path $runDirectory 'state')
    if (Test-TerminalState $state) { Write-Status $runDirectory $state; return 0 }
    if ($state -eq 'running' -and (Test-ReviewerIdentity $runDirectory) -and (Test-SupervisorIdentity $runDirectory)) {
        Write-Status $runDirectory 'running'; return 3
    }
    if (Test-SupervisorIdentity $runDirectory) {
        for ($grace = 0; $grace -lt 4; $grace += 1) {
            Start-Sleep -Seconds 1
            $state = Read-Artifact (Join-Path $runDirectory 'state')
            if (Test-TerminalState $state) { Write-Status $runDirectory $state; return 0 }
            if ($state -eq 'running' -and (Test-ReviewerIdentity $runDirectory) -and (Test-SupervisorIdentity $runDirectory)) {
                Write-Status $runDirectory 'running'; return 3
            }
        }
    }
    Write-Status $runDirectory 'indeterminate'
    return 4
}

function Invoke-Wait {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -ne 2) { return 64 }
    $timeout = 0
    if ($Arguments[1] -notmatch '^\d+$' -or
        -not [int]::TryParse($Arguments[1], [ref]$timeout) -or $timeout -lt 0) { return 64 }
    $validation = Test-RunDirectory $Arguments[0]
    if ($validation -ne 0) { return $validation }
    $runDirectory = $script:ValidatedRun
    $deadline = [DateTime]::UtcNow.AddSeconds($timeout)
    while ([DateTime]::UtcNow -lt $deadline) {
        $state = Read-Artifact (Join-Path $runDirectory 'state')
        if (Test-TerminalState $state) { return Invoke-Status @($runDirectory) }
        if (-not (Test-ReviewerIdentity $runDirectory) -or -not (Test-SupervisorIdentity $runDirectory)) {
            return Invoke-Status @($runDirectory)
        }
        Start-Sleep -Seconds 1
    }
    return Invoke-Status @($runDirectory)
}

function Acquire-CancelLock {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    $script:CancelLockDirectory = Join-Path $RunDirectory '.cancel-lock'
    $script:CancelOwnerPid = $PID.ToString()
    $script:CancelOwnerStart = Get-ProcessStartToken $PID
    if ($env:SUPERARTES_REVIEW_TEST_FORCE_CANCEL_OWNER_IDENTITY_FAILURE -eq '1') {
        $script:CancelOwnerStart = ''
    }
    if ($script:CancelOwnerStart.Length -eq 0) {
        [Console]::Error.WriteLine('Cancellation lock refused: could not establish caller process identity')
        return 4
    }
    try { [void](New-Item -ItemType Directory -Path $script:CancelLockDirectory -ErrorAction Stop) }
    catch {
        if ((Test-Path -LiteralPath $script:CancelLockDirectory) -and
            -not (Test-SafeDirectory $script:CancelLockDirectory $RunDirectory)) {
            [Console]::Error.WriteLine("Cancellation lock is not a safe ordinary directory: $($script:CancelLockDirectory)")
            return 4
        }
        $reclaimed = Remove-StaleLock $script:CancelLockDirectory $RunDirectory
        if (-not $reclaimed) {
            [Console]::Error.WriteLine(
                "Cancellation lock unavailable: live, unverifiable, ownerless, or malformed: $($script:CancelLockDirectory)")
            [Console]::Out.WriteLine('STATE=cancellation-requested')
            [Console]::Out.WriteLine("RUN_DIR=$RunDirectory")
            return 12
        }
        [Console]::Error.WriteLine("Reclaimed stale cancellation lock: $($script:CancelLockDirectory)")
        [void](New-Item -ItemType Directory -Path $script:CancelLockDirectory -ErrorAction Stop)
    }
    if (-not (Test-SafeDirectory $script:CancelLockDirectory $RunDirectory)) { return 4 }
    $script:CancelLockOwned = $true
    Write-AtomicText (Join-Path $script:CancelLockDirectory 'owner-pid') $script:CancelOwnerPid
    if (-not (Test-SafeDirectory $script:CancelLockDirectory $RunDirectory)) { return 4 }
    Write-AtomicText (Join-Path $script:CancelLockDirectory 'owner-start') $script:CancelOwnerStart
    return 0
}

function Release-CancelLock {
    if (-not $script:CancelLockOwned) { return }
    $parent = Split-Path $script:CancelLockDirectory -Parent
    if ((Test-SafeDirectory $script:CancelLockDirectory $parent) -and
        (Read-Artifact (Join-Path $script:CancelLockDirectory 'owner-pid')) -ceq $script:CancelOwnerPid -and
        (Test-SafeDirectory $script:CancelLockDirectory $parent) -and
        (Read-Artifact (Join-Path $script:CancelLockDirectory 'owner-start')) -ceq $script:CancelOwnerStart) {
        [void](Remove-OwnedLock $script:CancelLockDirectory $parent $script:CancelOwnerPid $script:CancelOwnerStart)
    }
    $script:CancelLockOwned = $false
}

function Get-DescendantSnapshot {
    param(
        [Parameter(Mandatory = $true)][int]$RootId,
        [Parameter(Mandatory = $true)][DateTime]$RootStart
    )
    if ($env:SUPERARTES_REVIEW_TEST_FORCE_CIM_FAILURE -eq '1') {
        throw 'Forced CIM failure for deterministic cancellation testing'
    }
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $selected = @()
    $frontier = @(New-Object PSObject -Property @{ Id = $RootId; Start = $RootStart.ToUniversalTime() })
    $depth = 0
    while ($frontier.Count -gt 0) {
        $next = @()
        foreach ($parent in $frontier) {
            foreach ($process in $all) {
                if ([int]$process.ParentProcessId -eq $parent.Id) {
                    try {
                        if ($null -eq $process.CreationDate -or
                            ([string]$process.CreationDate).Length -eq 0) {
                            throw 'CreationDate is missing'
                        }
                        if ($process.CreationDate -is [DateTime]) {
                            $created = ([DateTime]$process.CreationDate).ToUniversalTime()
                        }
                        else {
                            $created = [Management.ManagementDateTimeConverter]::ToDateTime(
                                [string]$process.CreationDate).ToUniversalTime()
                        }
                        $creationToken = ConvertTo-CimCreationToken $process.CreationDate
                    }
                    catch { throw "Cannot validate descendant $($process.ProcessId) CreationDate" }
                    if ($created -lt $parent.Start) {
                        throw "Cannot validate descendant $($process.ProcessId): creation precedes parent"
                    }
                    $selected += New-Object PSObject -Property @{
                        Id = [int]$process.ProcessId
                        Depth = $depth + 1
                        ParentId = [int]$process.ParentProcessId
                        CimCreationToken = $creationToken
                    }
                    $next += New-Object PSObject -Property @{
                        Id = [int]$process.ProcessId
                        Start = $created
                    }
                }
            }
        }
        $frontier = $next
        $depth += 1
    }
    return @($selected)
}

function Confirm-DescendantSnapshot {
    param(
        [Parameter(Mandatory = $true)][int]$RootId,
        [Parameter(Mandatory = $true)][DateTime]$RootStart,
        [Parameter()][AllowEmptyCollection()][object[]]$Snapshot = @()
    )
    $current = @(Get-DescendantSnapshot $RootId $RootStart)
    if ($current.Count -ne $Snapshot.Count) {
        throw 'Cannot validate descendants: process closure changed'
    }
    $snapshotById = @{}
    foreach ($child in $Snapshot) {
        if ($snapshotById.ContainsKey($child.Id)) {
            throw "Cannot validate descendant $($child.Id): duplicate snapshot identity"
        }
        $snapshotById[$child.Id] = $child
    }
    foreach ($actual in $current) {
        if (-not $snapshotById.ContainsKey($actual.Id)) {
            throw "Cannot validate descendant $($actual.Id): process closure added an identity"
        }
        $expected = $snapshotById[$actual.Id]
        $actualCreation = $actual.CimCreationToken
        if ($env:SUPERARTES_REVIEW_TEST_FORCE_DESCENDANT_CREATION_MISMATCH -eq '1') {
            $actualCreation += ':forced-mismatch'
        }
        if ($actualCreation -cne $expected.CimCreationToken) {
            throw "Cannot validate descendant $($actual.Id): CIM CreationDate changed"
        }
        if ($actual.ParentId -ne $expected.ParentId -or
            $actual.Depth -ne $expected.Depth) {
            throw "Cannot validate descendant $($actual.Id): ancestry changed"
        }
    }
    $expectedRootToken = ConvertTo-CimCreationToken $RootStart
    if ((Get-ProcessStartToken $RootId) -cne $expectedRootToken) {
        throw "Cannot validate reviewer root ${RootId}: identity changed"
    }
}

function Invoke-Cancel {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -ne 1) { return 64 }
    $validation = Test-RunDirectory $Arguments[0]
    if ($validation -ne 0) { return $validation }
    $runDirectory = $script:ValidatedRun
    $state = Read-Artifact (Join-Path $runDirectory 'state')
    if (Test-TerminalState $state) { Write-Status $runDirectory $state; return 0 }
    $lockResult = Acquire-CancelLock $runDirectory
    if ($lockResult -ne 0) { return $lockResult }
    try {
        $state = Read-Artifact (Join-Path $runDirectory 'state')
        if (Test-TerminalState $state) { Write-Status $runDirectory $state; return 0 }
        $existing = Read-Artifact (Join-Path $runDirectory 'cancel-requested')
        if ($existing.StartsWith('accepted:')) {
            [Console]::Out.WriteLine('STATE=cancellation-requested'); [Console]::Out.WriteLine("RUN_DIR=$runDirectory"); return 0
        }
        $reviewerId = Read-Artifact (Join-Path $runDirectory 'reviewer-pid')
        $reviewerStart = Read-Artifact (Join-Path $runDirectory 'reviewer-start')
        Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("pending:" + (Get-EpochSeconds))
        $delay = Get-TestDelay 'SUPERARTES_REVIEW_TEST_CANCEL_PENDING_DELAY'
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        if (-not (Test-ProcessIdentity $reviewerId $reviewerStart)) {
            Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:identity-mismatch:" + (Get-EpochSeconds))
            Write-Status $runDirectory 'indeterminate'
            return 4
        }
        $numericId = [int]$reviewerId
        if ($env:SUPERARTES_REVIEW_TEST_CANCEL_WAIT_FOR_ROOT_EXIT -eq '1') {
            $testRoot = Get-Process -Id $numericId -ErrorAction SilentlyContinue
            if ($null -ne $testRoot) {
                try { [void]$testRoot.WaitForExit(10000) }
                catch { }
            }
        }
        $rootProcess = Get-Process -Id $numericId -ErrorAction SilentlyContinue
        $rootStart = $null
        $rootStartToken = ''
        if ($null -ne $rootProcess) {
            try {
                $rootStart = $rootProcess.StartTime
                $rootStartToken = ConvertTo-CimCreationToken $rootStart
            }
            catch {
                $rootStart = $null
                $rootStartToken = ''
            }
        }
        if ($null -eq $rootStart -or $rootStartToken -cne $reviewerStart) {
            Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:identity-mismatch:" + (Get-EpochSeconds))
            Write-Status $runDirectory 'indeterminate'
            return 4
        }
        try { $descendants = @(Get-DescendantSnapshot $numericId $rootStart) }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:snapshot-failed:" + (Get-EpochSeconds))
            Write-Status $runDirectory 'indeterminate'
            return 4
        }
        $snapshotTrigger = $env:SUPERARTES_REVIEW_TEST_SNAPSHOT_TRIGGER_FILE
        if ($snapshotTrigger) {
            Write-AtomicText $snapshotTrigger $numericId.ToString()
        }
        $addedDescendantReady = `
            $env:SUPERARTES_REVIEW_TEST_ADDED_DESCENDANT_READY_FILE
        if ($addedDescendantReady) {
            for ($attempt = 0; $attempt -lt 100 -and
                -not (Test-Path -LiteralPath $addedDescendantReady -PathType Leaf);
                $attempt += 1) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $addedDescendantReady -PathType Leaf)) {
                Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:snapshot-failed:" + (Get-EpochSeconds))
                Write-Status $runDirectory 'indeterminate'
                return 4
            }
        }
        try { Confirm-DescendantSnapshot $numericId $rootStart $descendants }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:snapshot-failed:" + (Get-EpochSeconds))
            Write-Status $runDirectory 'indeterminate'
            return 4
        }
        # Successful complete-closure and root confirmation is directly
        # followed by the signal. Public process APIs cannot make this atomic.
        try { Stop-Process -Id $numericId -Force -ErrorAction Stop }
        catch {
            Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:signal-failed:" + (Get-EpochSeconds))
            Write-Status $runDirectory 'indeterminate'
            return 4
        }
        $signalLog = $env:SUPERARTES_REVIEW_TEST_SIGNAL_LOG
        if ($signalLog) {
            Add-SafeLogText $signalLog ("root:$numericId" + [Environment]::NewLine)
        }
        foreach ($child in @($descendants | Sort-Object Depth -Descending)) {
            if ((Get-CimProcessIdentityState $child.Id $child.CimCreationToken) -eq 'Match') {
                try { Stop-Process -Id $child.Id -Force -ErrorAction Stop }
                catch {
                    $childState = Get-CimProcessIdentityState $child.Id $child.CimCreationToken
                    if (@('Match', 'Unverifiable') -contains $childState) {
                        Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:descendant-signal-failed:" + (Get-EpochSeconds))
                        Write-Status $runDirectory 'indeterminate'
                        return 4
                    }
                }
                if ($signalLog) {
                    Add-SafeLogText $signalLog ("child:$($child.Depth):$($child.Id)" + [Environment]::NewLine)
                }
            }
        }
        for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
            $survivors = @()
            $rootState = Get-ProcessIdentityState $reviewerId $reviewerStart
            if (@('Match', 'Unverifiable') -contains $rootState) {
                $survivors += $numericId
            }
            foreach ($child in $descendants) {
                $childState = Get-CimProcessIdentityState $child.Id $child.CimCreationToken
                if (@('Match', 'Unverifiable') -contains $childState) { $survivors += $child.Id }
            }
            if ($survivors.Count -eq 0) { break }
            Start-Sleep -Milliseconds 100
        }
        if ($survivors.Count -ne 0) {
            Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("rejected:process-survived:" + (Get-EpochSeconds))
            Write-Status $runDirectory 'indeterminate'
            return 4
        }
        $delay = Get-TestDelay 'SUPERARTES_REVIEW_TEST_CANCEL_ACCEPT_DELAY'
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        Write-AtomicText (Join-Path $runDirectory 'cancel-requested') ("accepted:" + (Get-EpochSeconds))
        [Console]::Out.WriteLine('STATE=cancellation-requested')
        [Console]::Out.WriteLine("RUN_DIR=$runDirectory")
        return 0
    }
    finally { Release-CancelLock }
}

function Invoke-Cleanup {
    param([Parameter()][AllowEmptyCollection()][string[]]$Arguments = @())
    if ($Arguments.Count -ne 1) { return 64 }
    $validation = Test-RunDirectory $Arguments[0]
    if ($validation -ne 0) { return $validation }
    $runDirectory = $script:ValidatedRun
    $state = Read-Artifact (Join-Path $runDirectory 'state')
    if (-not (Test-TerminalState $state) -or (Test-ReviewerIdentity $runDirectory)) { return 66 }
    for ($attempt = 0; $attempt -lt 20 -and (Test-SupervisorIdentity $runDirectory); $attempt += 1) {
        Start-Sleep -Milliseconds 100
    }
    if (Test-SupervisorIdentity $runDirectory) { return 66 }
    try {
        $cancelLock = Join-Path $runDirectory '.cancel-lock'
        $hasStaleCancelLock = $false
        foreach ($entry in @(Get-ChildItem -LiteralPath $runDirectory -Force -ErrorAction Stop)) {
            if ($entry.Name -eq '.cancel-lock') {
                if (-not (Test-SafeDirectory $entry.FullName $runDirectory)) {
                    [Console]::Error.WriteLine("Cleanup refused: cancellation lock is not a safe ordinary directory: $($entry.FullName)")
                    return 66
                }
                $lockEntries = @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop)
                if ($lockEntries.Count -ne 2 -or
                    @($lockEntries | Where-Object {
                        @('owner-pid', 'owner-start') -notcontains $_.Name -or
                        $_.PSIsContainer -or (Test-ReparsePoint $_.FullName) -or
                        -not (Test-ArtifactAccessibleForRemoval $_.FullName)
                    }).Count -ne 0) {
                    [Console]::Error.WriteLine("Cleanup refused: cancellation lock is malformed: $($entry.FullName)")
                    return 66
                }
                $owner = Get-LockOwner $entry.FullName $runDirectory
                if ($null -eq $owner -or
                    @('Absent', 'Mismatch') -notcontains (
                        Get-ProcessIdentityState $owner.ProcessId $owner.Start)) {
                    [Console]::Error.WriteLine("Cleanup refused: cancellation lock is live, unverifiable, or malformed: $($entry.FullName)")
                    return 66
                }
                $hasStaleCancelLock = $true
                continue
            }
            if ($script:Artifacts -notcontains $entry.Name -or $entry.PSIsContainer -or
                (Test-ReparsePoint $entry.FullName) -or
                -not (Test-ArtifactAccessibleForRemoval $entry.FullName)) {
                [Console]::Error.WriteLine("Cleanup refused: unknown or unsafe entry: $($entry.FullName)")
                return 66
            }
        }
        if ($hasStaleCancelLock) {
            if (-not (Remove-StaleLock $cancelLock $runDirectory)) {
                [Console]::Error.WriteLine("Cleanup refused: cancellation lock changed during recovery: $cancelLock")
                return 66
            }
            [Console]::Error.WriteLine("Reclaimed stale cancellation lock: $cancelLock")
        }
        $validation = Test-RunDirectoryForRemoval $runDirectory
        if ($validation -ne 0) { return $validation }
        $lateArtifacts = @('run-path', 'marker', 'run-id', 'review-key')
        foreach ($artifact in $script:Artifacts) {
            if ($lateArtifacts -contains $artifact) { continue }
            $path = Join-Path $runDirectory $artifact
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if (-not (Test-RegularArtifact $path)) { return 66 }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        foreach ($artifact in $lateArtifacts) {
            $path = Join-Path $runDirectory $artifact
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if (-not (Test-RegularArtifact $path)) { return 66 }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        if (@(Get-ChildItem -LiteralPath $runDirectory -Force -ErrorAction Stop).Count -ne 0) {
            return 66
        }
        [IO.Directory]::Delete($runDirectory, $false)
    }
    catch { return 66 }
    [Console]::Out.WriteLine('STATE=cleaned')
    [Console]::Out.WriteLine("RUN_DIR=$runDirectory")
    return 0
}

function Test-RunDirectoryForRemoval {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    if (-not (Test-SafeDirectory $RunDirectory $script:ReviewRoot)) { return 65 }
    $leaf = Split-Path $RunDirectory -Leaf
    if (-not $leaf.StartsWith('run-', [StringComparison]::Ordinal)) { return 65 }
    return 0
}

try {
    $script:ReviewRoot = Initialize-ReviewRoot
    if ($Operation -eq '--help' -or $Operation -eq '-h') { Show-Usage; $exitCode = 0 }
    elseif ($Operation -eq 'check') { $exitCode = Test-Profile $Remaining }
    elseif ($Operation -eq 'start') { $exitCode = Invoke-Start $Remaining }
    elseif ($Operation -eq 'status') { $exitCode = Invoke-Status $Remaining }
    elseif ($Operation -eq 'wait') { $exitCode = Invoke-Wait $Remaining }
    elseif ($Operation -eq 'cancel') { $exitCode = Invoke-Cancel $Remaining }
    elseif ($Operation -eq 'cleanup') { $exitCode = Invoke-Cleanup $Remaining }
    elseif ($Operation -eq 'RunReviewer') { $exitCode = Invoke-RunReviewer $Remaining }
    elseif ($Operation -eq 'Supervise') {
        $stdinProbe = $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_STDIN_PROBE
        if ($stdinProbe) {
            Write-AtomicText $stdinProbe ([Console]::In.ReadToEnd()) -NoNewline
        }
        $delay = Get-TestDelay 'SUPERARTES_REVIEW_TEST_SUPERVISOR_START_DELAY'
        $ready = $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_START_READY_FILE
        if ($ready) { Write-AtomicText $ready $PID.ToString() }
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        $exitCode = Invoke-Supervise $Remaining
    }
    else { Show-Usage -ErrorStream; $exitCode = 64 }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = 4
}
finally {
    Release-CancelLock
    Release-Registry
}
exit $exitCode
