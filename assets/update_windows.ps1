param([Parameter(Mandatory=$true)][string]$Manifest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$jobRoot = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Manifest))
$backup = $null
$target = $null
$swapped = $false
$stage = $null
try {
    # The app starts this helper from its own folder. A process keeps its working
    # directory locked, which would make moving the application directory fail.
    Set-Location -LiteralPath $jobRoot
    [Environment]::CurrentDirectory = $jobRoot
    $job = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = [IO.Path]::GetFullPath($job.target).TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($target)
    if ($jobRoot.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Updater must be staged outside the application directory' }
    if (!$parent -or !(Test-Path -LiteralPath "$target\fuji_san.exe") -or
        !(Test-Path -LiteralPath "$target\flutter_windows.dll") -or
        !(Test-Path -LiteralPath "$target\data\flutter_assets")) { throw 'Invalid application directory' }
    if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked application directories are unsupported' }
    $archive = [IO.Path]::GetFullPath($job.zip)
    if ($archive -ne [IO.Path]::Combine($jobRoot, 'package.zip')) { throw 'Invalid archive path' }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $job.sha256) { throw 'SHA-256 mismatch' }
    $token = [Guid]::NewGuid().ToString('N')
    $stage = [IO.Path]::Combine($parent, '.fuji-san-stage-' + $token)
    $backup = [IO.Path]::Combine($parent, '.fuji-san-previous-' + $token)
    # Both move destinations are checked siblings of the exact application directory.
    foreach ($path in @($stage, $backup)) {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -ne $parent -or (Test-Path -LiteralPath $path)) { throw 'Invalid staging directory' }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $total = [long]0
        foreach ($entry in $zip.Entries) {
            $entryPath = [IO.Path]::GetFullPath([IO.Path]::Combine($stage, $entry.FullName))
            if (!$entryPath.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase) -or $entry.FullName.Contains(':')) { throw 'Unsafe archive entry' }
            $total += $entry.Length
            if ($total -gt 1073741824) { throw 'Unpacked update too large' }
        }
    } finally { $zip.Dispose() }
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stage)
    foreach ($required in @('fuji_san.exe', 'flutter_windows.dll', 'data\flutter_assets')) {
        if (!(Test-Path -LiteralPath ([IO.Path]::Combine($stage, $required)))) { throw 'Incomplete update package' }
    }
    [IO.File]::WriteAllText("$jobRoot\ready", 'ready')
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (!(Test-Path -LiteralPath "$jobRoot\commit")) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Update cancelled before restart' }
        Start-Sleep -Milliseconds 250
    }
    $appProcess = Get-Process -Id $job.pid -ErrorAction SilentlyContinue
    if ($appProcess -and !$appProcess.WaitForExit(60000)) { throw 'Application did not close' }
    # Keep the old bundle intact for recovery. Never delete user files.
    [IO.Directory]::Move($target, $backup)
    try { [IO.Directory]::Move($stage, $target); $swapped = $true }
    catch { [IO.Directory]::Move($backup, $target); throw }
    Start-Process -FilePath "$target\fuji_san.exe" -WorkingDirectory $target
    [IO.File]::WriteAllText("$jobRoot\complete", $backup)
} catch {
    [IO.File]::WriteAllText("$jobRoot\error.txt", $_.Exception.Message)
    # The stage is this run's own unpacked copy; drop it when it was not installed.
    if (!$swapped -and $stage -and (Test-Path -LiteralPath $stage)) {
        try { [IO.Directory]::Delete($stage, $true) } catch { }
    }
    if ($swapped -and $backup -and (Test-Path -LiteralPath $backup)) {
        $failed = [IO.Path]::Combine($parent, '.fuji-san-failed-' + $token)
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($failed)) -eq $parent -and !(Test-Path -LiteralPath $failed)) {
            [IO.Directory]::Move($target, $failed)
            [IO.Directory]::Move($backup, $target)
        }
    }
    if ((Test-Path -LiteralPath "$jobRoot\commit") -and $target -and (Test-Path -LiteralPath "$target\fuji_san.exe")) {
        Start-Process -FilePath "$target\fuji_san.exe" -WorkingDirectory $target
    }
    exit 1
}
