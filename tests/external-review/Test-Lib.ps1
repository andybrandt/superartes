Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:CaptureExitCode = 0
$script:CaptureOutput = ''
$script:TestRoot = ''
$script:CanonicalTestRoot = ''
$script:FakeLogDirectory = ''
$script:NativeReviewerPath = ''
$script:OriginalPath = $env:PATH
$script:OriginalReviewRoot = $env:SUPERARTES_REVIEW_TMPDIR
$script:OriginalTemp = $env:TEMP
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    [IO.File]::WriteAllText($Path, $Value, $script:Utf8NoBom)
}

function Pass-Test {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Passed += 1
    Write-Host "PASS: $Message"
}

function Fail-Test {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Failed += 1
    [Console]::Error.WriteLine("FAIL: $Message")
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Expected -ceq $Actual) {
        Pass-Test $Message
    }
    else {
        Fail-Test "$Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-OneOf {
    param(
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Allowed -contains $Actual) {
        Pass-Test $Message
    }
    else {
        Fail-Test "$Message (got '$Actual')"
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Value.Contains($Text)) {
        Pass-Test $Message
    }
    else {
        Fail-Test $Message
    }
}

function Assert-FileContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        ([IO.File]::ReadAllText($Path).Contains($Text))) {
        Pass-Test $Message
    }
    else {
        Fail-Test $Message
    }
}

function Assert-FileEqual {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$ActualPath,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $expected = [IO.File]::ReadAllBytes($ExpectedPath)
    $actual = [IO.File]::ReadAllBytes($ActualPath)
    if ([Convert]::ToBase64String($expected) -ceq [Convert]::ToBase64String($actual)) {
        Pass-Test $Message
    }
    else {
        Fail-Test $Message
    }
}

function Assert-JsonArrayEqual {
    param(
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-Test "$Message (missing $Path)"
        return
    }
    $actual = @([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    if ($actual.Count -ne $Expected.Count) {
        Fail-Test "$Message (expected $($Expected.Count) arguments, got $($actual.Count))"
        return
    }
    for ($index = 0; $index -lt $Expected.Count; $index += 1) {
        if ([string]$actual[$index] -cne $Expected[$index]) {
            Fail-Test "$Message (argument $index expected '$($Expected[$index])', got '$($actual[$index])')"
            return
        }
    }
    Pass-Test $Message
}

function Assert-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom) {
        Pass-Test $Message
    }
    else {
        Fail-Test $Message
    }
}

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$Runner,
        [Parameter()][string[]]$Arguments = @()
    )
    $capture = Join-Path $script:TestRoot ("capture-{0}.txt" -f [Guid]::NewGuid())
    $errorCapture = Join-Path $script:TestRoot ("capture-error-{0}.txt" -f [Guid]::NewGuid())
    try {
        $powerShell = (Get-Process -Id $PID).Path
        $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Quote-TestWindowsArgument $Runner))
        foreach ($argument in $Arguments) {
            $quoted += Quote-TestWindowsArgument $argument
        }
        $process = Start-Process -FilePath $powerShell -ArgumentList ($quoted -join ' ') `
            -RedirectStandardOutput $capture -RedirectStandardError $errorCapture `
            -WindowStyle Hidden -Wait -PassThru
        $script:CaptureExitCode = $process.ExitCode
        $script:CaptureOutput = [IO.File]::ReadAllText($capture) +
            [IO.File]::ReadAllText($errorCapture)
    }
    catch {
        $script:CaptureExitCode = 1
        $script:CaptureOutput = $_.Exception.Message
    }
    finally {
        Remove-Item -LiteralPath $capture -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errorCapture -Force -ErrorAction SilentlyContinue
    }
}

function Start-RunnerCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Runner,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ErrorPath
    )
    $powerShell = (Get-Process -Id $PID).Path
    $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Quote-TestWindowsArgument $Runner))
    foreach ($argument in $Arguments) { $quoted += Quote-TestWindowsArgument $argument }
    $process = Start-Process -FilePath $powerShell -ArgumentList ($quoted -join ' ') `
        -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath `
        -WindowStyle Hidden -PassThru
    $startToken = ''
    $cimCreationToken = ''
    try { $startToken = ConvertTo-CimCreationToken $process.StartTime }
    catch { $startToken = '' }
    $cimRecord = Get-CimProcessRecord $process.Id
    if ($null -ne $cimRecord) {
        $cimCreationToken = ConvertTo-CimCreationToken $cimRecord.CreationDate
    }
    $process | Add-Member -NotePropertyName FixtureStartToken -NotePropertyValue $startToken
    $process | Add-Member -NotePropertyName FixtureCimCreationToken `
        -NotePropertyValue $cimCreationToken
    return $process
}

function Quote-TestWindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
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

function Get-OutputField {
    param([Parameter(Mandatory = $true)][string]$Name)
    foreach ($line in ($script:CaptureOutput -split "`r?`n")) {
        if ($line.StartsWith("$Name=")) {
            return $line.Substring($Name.Length + 1)
        }
    }
    return ''
}

function Get-FieldFromText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    foreach ($line in ($Value -split "`r?`n")) {
        if ($line.StartsWith("$Name=")) { return $line.Substring($Name.Length + 1) }
    }
    return ''
}

function Get-ProcessStartToken {
    param([Parameter(Mandatory = $true)][int]$Id)
    try {
        $process = Get-Process -Id $Id -ErrorAction Stop
        return ConvertTo-CimCreationToken $process.StartTime
    }
    catch {
        return ''
    }
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

function Test-ProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $actual = Get-ProcessStartToken $Id
    return $actual.Length -gt 0 -and $actual -ceq $Expected
}

function Get-CimProcessRecord {
    param([Parameter(Mandatory = $true)][int]$Id)
    $records = @(Get-CimInstance Win32_Process -Filter "ProcessId = $Id" -ErrorAction Stop)
    if ($records.Count -ne 1 -or $null -eq $records[0].CreationDate -or
        ([string]$records[0].CreationDate).Length -eq 0) {
        return $null
    }
    try { [void](ConvertTo-CimCreationToken $records[0].CreationDate) }
    catch { return $null }
    return $records[0]
}

function Stop-ValidatedFixtureProcess {
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][string]$ExpectedStartToken,
        [Parameter()][AllowEmptyString()][string]$ExpectedCimCreationToken = ''
    )
    if (-not (Test-ProcessIdentity $Id $ExpectedStartToken)) {
        throw "Refusing to stop fixture PID $Id because its StartTime identity changed"
    }
    $record = Get-CimProcessRecord $Id
    if ($null -eq $record) {
        throw "Refusing to stop fixture PID $Id because its CIM identity is unavailable"
    }
    $creationToken = ConvertTo-CimCreationToken $record.CreationDate
    if ($ExpectedCimCreationToken.Length -gt 0 -and
        $creationToken -cne $ExpectedCimCreationToken) {
        throw "Refusing to stop fixture PID $Id because its CIM identity changed"
    }
    $current = Get-CimProcessRecord $Id
    if ($null -eq $current -or
        (ConvertTo-CimCreationToken $current.CreationDate) -cne $creationToken -or
        -not (Test-ProcessIdentity $Id $ExpectedStartToken)) {
        throw "Refusing to stop fixture PID $Id because identity changed immediately before signal"
    }
    Stop-Process -Id $Id -Force -ErrorAction Stop
}

function Stop-CapturedFixtureProcess {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    Stop-ValidatedFixtureProcess $Process.Id `
        ([string]$Process.FixtureStartToken) `
        ([string]$Process.FixtureCimCreationToken)
    $Process.WaitForExit()
}

function Wait-ForFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][int]$Tenths = 80
    )
    for ($attempt = 0; $attempt -lt $Tenths; $attempt += 1) {
        if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
            (Get-Item -LiteralPath $Path).Length -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Require-File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (Wait-ForFile $Path) {
        Pass-Test $Message
        return
    }
    Fail-Test $Message
    throw "Required synchronization file was not published: $Path"
}

function Wait-ForArtifactPrefix {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter()][int]$Tenths = 80
    )
    for ($attempt = 0; $attempt -lt $Tenths; $attempt += 1) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $value = [IO.File]::ReadAllText($Path).Trim()
            if ($value.StartsWith($Prefix, [StringComparison]::Ordinal)) {
                return $value
            }
        }
        Start-Sleep -Milliseconds 100
    }
    return ''
}

function Wait-ForProcessExit {
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][string]$StartToken,
        [Parameter()][int]$Tenths = 80
    )
    for ($attempt = 0; $attempt -lt $Tenths; $attempt += 1) {
        if (-not (Test-ProcessIdentity $Id $StartToken)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function New-RequiredJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    try {
        [void](New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop)
    }
    catch {
        Fail-Test "required junction fixture creation succeeds: $($_.Exception.Message)"
        throw
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        Fail-Test 'required junction fixture is a reparse point'
        throw 'Junction creation did not create a reparse point'
    }
    Pass-Test 'required junction fixture is created deterministically'
}

function Stop-FixtureRun {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    foreach ($name in @('reviewer', 'supervisor')) {
        $pidPath = Join-Path $RunDirectory "$name-pid"
        $startPath = Join-Path $RunDirectory "$name-start"
        if ((Test-Path -LiteralPath $pidPath -PathType Leaf) -and
            (Test-Path -LiteralPath $startPath -PathType Leaf)) {
            $processId = 0
            if ([int]::TryParse(([IO.File]::ReadAllText($pidPath).Trim()), [ref]$processId)) {
                $token = [IO.File]::ReadAllText($startPath).Trim()
                if (Test-ProcessIdentity $processId $token) {
                    Stop-ValidatedFixtureProcess $processId $token
                }
            }
        }
    }
}

function Write-NativeFakeReviewer {
    $nativeDirectory = Join-Path $script:TestRoot 'native-bin'
    [void](New-Item -ItemType Directory -Path $nativeDirectory)
    $script:NativeReviewerPath = Join-Path $nativeDirectory 'native-reviewer.exe'
    $source = @'
using System;
using System.Globalization;
using System.IO;
using System.Text;

public static class NativeFakeReviewer
{
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

    private static void CopyFileToStream(string sourcePath, Stream destination)
    {
        if (String.IsNullOrEmpty(sourcePath))
        {
            return;
        }
        using (FileStream source = File.OpenRead(sourcePath))
        {
            source.CopyTo(destination);
        }
        destination.Flush();
    }

    public static int Main(string[] arguments)
    {
        if (arguments.Length == 1 && arguments[0] == "--version")
        {
            Console.Out.Write("claude-native-test");
            return 0;
        }
        if (arguments.Length == 1 && arguments[0] == "--help")
        {
            Console.Out.Write("--safe-mode --permission-mode --output-format --session-id --tools --allowedTools");
            return 0;
        }

        string session = String.Empty;
        for (int index = 1; index < arguments.Length; index += 1)
        {
            if (arguments[index - 1] == "--session-id")
            {
                session = arguments[index];
            }
        }
        string logDirectory = Environment.GetEnvironmentVariable("FAKE_LOG_DIR");
        if (String.IsNullOrEmpty(session) || String.IsNullOrEmpty(logDirectory))
        {
            return 64;
        }

        string logBase = Path.Combine(logDirectory, "claude-native-" + session);
        File.WriteAllText(
            logBase + ".argv", String.Join("\0", arguments) + "\0", Utf8NoBom);
        using (Stream input = Console.OpenStandardInput())
        using (FileStream inputLog = File.Create(logBase + ".stdin"))
        {
            input.CopyTo(inputLog);
        }
        File.WriteAllText(
            logBase + ".env",
            Environment.GetEnvironmentVariable("CLAUDE_CODE_USE_POWERSHELL_TOOL") ?? String.Empty,
            Utf8NoBom);
        File.WriteAllText(logBase + ".pwd", Environment.CurrentDirectory, Utf8NoBom);

        CopyFileToStream(
            Environment.GetEnvironmentVariable("FAKE_NATIVE_EXE_STDOUT_FILE"),
            Console.OpenStandardOutput());
        CopyFileToStream(
            Environment.GetEnvironmentVariable("FAKE_NATIVE_EXE_STDERR_FILE"),
            Console.OpenStandardError());

        int exitCode = 0;
        Int32.TryParse(
            Environment.GetEnvironmentVariable("FAKE_REVIEW_EXIT"),
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out exitCode);
        return exitCode;
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp `
        -OutputAssembly $script:NativeReviewerPath `
        -OutputType ConsoleApplication -ErrorAction Stop
}

function Write-FakeReviewers {
    $fakeScript = Join-Path $script:TestRoot 'bin\fake-reviewer.ps1'
    $fakeChildScript = Join-Path $script:TestRoot 'bin\fake-child.ps1'
    $claudeCommand = Join-Path $script:TestRoot 'bin\claude.cmd'
    $codexCommand = Join-Path $script:TestRoot 'bin\codex.cmd'
    $fakeSource = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$FakeProfile = $env:SUPERARTES_FAKE_PROFILE
$Remaining = @($args)
$utf8 = New-Object System.Text.UTF8Encoding($false)
if ($Remaining.Count -eq 1 -and $Remaining[0] -ceq '--version') {
    $versionOutput = "$FakeProfile-test"
    [IO.File]::WriteAllText(
        (Join-Path $env:FAKE_LOG_DIR "$FakeProfile.preflight-version"),
        $versionOutput, $utf8)
    [Console]::Out.WriteLine($versionOutput)
    exit 0
}
if ($FakeProfile -ceq 'claude' -and $Remaining.Count -eq 1 -and
    $Remaining[0] -ceq '--help') {
    $helpOutput = '--safe-mode --permission-mode --output-format --session-id --tools --allowedTools'
    [IO.File]::WriteAllText(
        (Join-Path $env:FAKE_LOG_DIR 'claude.preflight-help'),
        $helpOutput, $utf8)
    [Console]::Out.WriteLine($helpOutput)
    exit 0
}
if ($FakeProfile -ceq 'codex' -and $Remaining.Count -eq 2 -and
    $Remaining[0] -ceq 'exec' -and $Remaining[1] -ceq '--help') {
    $helpOutput = '--sandbox --skip-git-repo-check --output-last-message'
    [IO.File]::WriteAllText(
        (Join-Path $env:FAKE_LOG_DIR 'codex-prompt.preflight-help'),
        $helpOutput, $utf8)
    [Console]::Out.WriteLine($helpOutput)
    exit 0
}
if ($FakeProfile -ceq 'codex' -and $Remaining.Count -eq 3 -and
    $Remaining[0] -ceq 'exec' -and $Remaining[1] -ceq 'review' -and
    $Remaining[2] -ceq '--help') {
    $helpOutput = '--uncommitted --base --commit --skip-git-repo-check --output-last-message'
    [IO.File]::WriteAllText(
        (Join-Path $env:FAKE_LOG_DIR 'codex-review.preflight-help'),
        $helpOutput, $utf8)
    [Console]::Out.WriteLine($helpOutput)
    exit 0
}
$session = ''
$outputPath = ''
for ($index = 0; $index -lt $Remaining.Count; $index += 1) {
    if ($index -gt 0 -and $Remaining[$index - 1] -ceq '--session-id') {
        $session = $Remaining[$index]
    }
    if ($index -gt 0 -and ($Remaining[$index - 1] -ceq '-o' -or
        $Remaining[$index - 1] -ceq '--output-last-message')) {
        $outputPath = $Remaining[$index]
    }
}
if ($FakeProfile -ceq 'claude') {
    if ($session.Length -eq 0) { exit 64 }
    $logBase = Join-Path $env:FAKE_LOG_DIR "claude-$session"
}
else {
    if ($outputPath.Length -eq 0) { exit 64 }
    $logBase = Join-Path $env:FAKE_LOG_DIR ("codex-" + (Split-Path (Split-Path $outputPath -Parent) -Leaf))
}
[IO.File]::WriteAllText("$logBase.argv.json", ($Remaining | ConvertTo-Json -Compress), $utf8)
[IO.File]::WriteAllText("$logBase.pwd", (Get-Location).ProviderPath, $utf8)
[IO.File]::WriteAllText("$logBase.env", [string]$env:CLAUDE_CODE_USE_POWERSHELL_TOOL, $utf8)
$isReview = $FakeProfile -ceq 'codex' -and $Remaining.Count -gt 1 -and
    $Remaining[0] -ceq 'exec' -and $Remaining[1] -ceq 'review'
if (-not $isReview) {
    [IO.File]::WriteAllText("$logBase.stdin", [Console]::In.ReadToEnd(), $utf8)
}
if ($env:FAKE_SPAWN_CHILD -ceq '1') {
    $childScript = Join-Path (Split-Path $PSCommandPath -Parent) 'fake-child.ps1'
    $childArguments = '-NoProfile -ExecutionPolicy Bypass -File "' +
        $childScript.Replace('"', '\"') + '" "' + $logBase.Replace('"', '\"') + '"'
    $child = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList $childArguments -PassThru -WindowStyle Hidden
    [IO.File]::WriteAllText("$logBase.child-pid", $child.Id.ToString(), $utf8)
    [IO.File]::WriteAllText("$logBase.child-start", $child.StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture), $utf8)
}
if ($env:SUPERARTES_REVIEW_TEST_SNAPSHOT_TRIGGER_FILE -and
    $env:SUPERARTES_REVIEW_TEST_ADDED_DESCENDANT_READY_FILE) {
    for ($attempt = 0; $attempt -lt 100; $attempt += 1) {
        if (Test-Path -LiteralPath $env:SUPERARTES_REVIEW_TEST_SNAPSHOT_TRIGGER_FILE) {
            $childScript = Join-Path (Split-Path $PSCommandPath -Parent) 'fake-child.ps1'
            $childArguments = '-NoProfile -ExecutionPolicy Bypass -File "' +
                $childScript.Replace('"', '\"') + '" "' + $logBase.Replace('"', '\"') + '"'
            $lateChild = Start-Process -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList $childArguments -PassThru -WindowStyle Hidden
            [IO.File]::WriteAllText(
                "$logBase.late-child-pid", $lateChild.Id.ToString(), $utf8)
            [IO.File]::WriteAllText(
                "$logBase.late-child-start",
                $lateChild.StartTime.ToUniversalTime().Ticks.ToString(
                    [Globalization.CultureInfo]::InvariantCulture), $utf8)
            [IO.File]::WriteAllText(
                $env:SUPERARTES_REVIEW_TEST_ADDED_DESCENDANT_READY_FILE,
                $lateChild.Id.ToString(), $utf8)
            break
        }
        Start-Sleep -Milliseconds 100
    }
}
$delay = 0
if ($env:FAKE_REVIEW_DELAY) { [void][int]::TryParse($env:FAKE_REVIEW_DELAY, [ref]$delay) }
if ($delay -gt 0) { Start-Sleep -Seconds $delay }
$exitCode = 0
if ($env:FAKE_REVIEW_EXIT) { [void][int]::TryParse($env:FAKE_REVIEW_EXIT, [ref]$exitCode) }
if ($exitCode -ne 0) {
    if ($env:FAKE_RESULT_BEFORE_EXIT -ceq '1') {
        if ($FakeProfile -ceq 'claude') {
            if ($env:FAKE_CLAUDE_PARTIAL_FILE) {
                $bytes = [IO.File]::ReadAllBytes($env:FAKE_CLAUDE_PARTIAL_FILE)
                [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
            }
            elseif ($env:FAKE_NATIVE_JSON_FILE) {
                $bytes = [IO.File]::ReadAllBytes($env:FAKE_NATIVE_JSON_FILE)
                [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
            }
            else { [Console]::Out.Write('[{"type":"result","result":"partial"}]') }
        }
        else { [IO.File]::WriteAllText($outputPath, 'partial', $utf8) }
    }
    [Console]::Error.WriteLine('fake reviewer failure')
    exit $exitCode
}
if ($FakeProfile -ceq 'claude') {
    if ($env:FAKE_NATIVE_JSON_FILE) {
        $bytes = [IO.File]::ReadAllBytes($env:FAKE_NATIVE_JSON_FILE)
        [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
    }
    else { [Console]::Out.Write('[{"type":"result","session_id":"fake","result":"fake Claude review"}]') }
}
else { [IO.File]::WriteAllText($outputPath, 'fake Codex review', $utf8) }
'@
    Write-Utf8NoBom $fakeScript $fakeSource
    Write-Utf8NoBom $fakeChildScript @'
param([Parameter(Mandatory = $true)][string]$FixtureMarker)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Start-Sleep -Seconds 60
'@
    $powerShell = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Utf8NoBom $claudeCommand "@echo off`r`nsetlocal`r`nset `"SUPERARTES_FAKE_PROFILE=claude`"`r`n$powerShell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-reviewer.ps1`" %*`r`nexit /b %errorlevel%`r`n"
    Write-Utf8NoBom $codexCommand "@echo off`r`nsetlocal`r`nset `"SUPERARTES_FAKE_PROFILE=codex`"`r`n$powerShell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-reviewer.ps1`" %*`r`nexit /b %errorlevel%`r`n"
}

function Start-TestSuite {
    $base = [IO.Path]::GetTempPath()
    $script:TestRoot = Join-Path $base ("superartes-external-review-tests-{0} with spaces % & (native) ^" -f [Guid]::NewGuid())
    [void](New-Item -ItemType Directory -Path $script:TestRoot)
    [void](New-Item -ItemType Directory -Path (Join-Path $script:TestRoot 'bin'))
    [void](New-Item -ItemType Directory -Path (Join-Path $script:TestRoot 'fake logs'))
    [void](New-Item -ItemType Directory -Path (Join-Path $script:TestRoot 'review temp'))
    $script:CanonicalTestRoot = (Resolve-Path -LiteralPath $script:TestRoot).ProviderPath
    $script:FakeLogDirectory = Join-Path $script:CanonicalTestRoot 'fake logs'
    $env:FAKE_LOG_DIR = $script:FakeLogDirectory
    $env:SUPERARTES_REVIEW_TMPDIR = Join-Path $script:CanonicalTestRoot 'review temp'
    $env:TEMP = Join-Path $script:CanonicalTestRoot 'TEMP with spaces'
    [void](New-Item -ItemType Directory -Path $env:TEMP)
    $env:PATH = (Join-Path $script:CanonicalTestRoot 'bin') + [IO.Path]::PathSeparator + $script:OriginalPath
    Write-NativeFakeReviewer
    Write-FakeReviewers
}

function Stop-TestSuite {
    if ($script:CanonicalTestRoot.Length -eq 0) { return }
    $leaf = Split-Path $script:CanonicalTestRoot -Leaf
    if (-not $leaf.StartsWith('superartes-external-review-tests-')) { return }
    $reviewRoot = Join-Path $script:CanonicalTestRoot 'review temp'
    if (Test-Path -LiteralPath $reviewRoot -PathType Container) {
        Get-ChildItem -LiteralPath $reviewRoot -Directory -Filter 'run-*' |
            ForEach-Object { Stop-FixtureRun $_.FullName }
    }
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            if ($process.CommandLine -and
                ([string]$process.CommandLine).IndexOf($script:CanonicalTestRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $processId = [int]$process.ProcessId
                $startToken = Get-ProcessStartToken $processId
                $creationToken = ConvertTo-CimCreationToken $process.CreationDate
                if ($startToken.Length -gt 0 -and $creationToken.Length -gt 0) {
                    Stop-ValidatedFixtureProcess $processId $startToken $creationToken
                }
            }
        }
    }
    catch { Fail-Test "fixture teardown process query and cleanup succeeds: $($_.Exception.Message)" }
    $env:PATH = $script:OriginalPath
    $env:SUPERARTES_REVIEW_TMPDIR = $script:OriginalReviewRoot
    $env:TEMP = $script:OriginalTemp
    Remove-Item -LiteralPath $script:CanonicalTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:CanonicalTestRoot) {
        Fail-Test 'fixture-owned test tree is removed'
    }
}

function Complete-TestSuite {
    Write-Host ''
    Write-Host "Passed: $script:Passed"
    Write-Host "Failed: $script:Failed"
    if ($script:Failed -ne 0) { exit 1 }
}
