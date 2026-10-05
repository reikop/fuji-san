$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Join-Path ([IO.Path]::GetTempPath()) ('fuji-updater-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\update_windows.ps1'))
function Assert($condition, $message) { if (!$condition) { throw $message } }
function Fixture([string]$name) {
    $dir = Join-Path $root $name
    $target = Join-Path $dir 'app with spaces'
    $package = Join-Path $dir 'package'
    $job = Join-Path $dir 'job'
    foreach ($path in @($target, $package, $job)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    foreach ($path in @($target, $package)) {
        [IO.Directory]::CreateDirectory("$path\data\flutter_assets") | Out-Null
        [IO.File]::WriteAllText("$path\flutter_windows.dll", 'fixture')
        Copy-Item -LiteralPath "$root\fixture.exe" -Destination "$path\fuji_san.exe"
    }
    [IO.File]::WriteAllText("$target\version.txt", 'old')
    [IO.File]::WriteAllText("$package\version.txt", 'new')
    [IO.Compression.ZipFile]::CreateFromDirectory($package, "$job\package.zip")
    $manifest = @{ pid = 9999999; target = $target; zip = "$job\package.zip"; sha256 = (Get-FileHash -LiteralPath "$job\package.zip").Hash.ToLowerInvariant() }
    return @{ target=$target; job=$job; manifest=$manifest }
}
Add-Type -TypeDefinition 'public class UpdateFixture { public static void Main() { System.IO.File.WriteAllText(System.IO.Path.Combine(System.AppDomain.CurrentDomain.BaseDirectory, "started.txt"), "started"); } }' -OutputAssembly "$root\fixture.exe" -OutputType WindowsApplication
function RunHelper($fixture) {
    $fixture.manifest | ConvertTo-Json | Set-Content -LiteralPath "$($fixture.job)\job.json" -Encoding UTF8
    $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $helper + '"'), '-Manifest', ('"' + $fixture.job + '\job.json"'))
    $process = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(30000)) { $process.Kill(); throw 'Updater test timeout' }
    return $process.ExitCode
}
$success = Fixture 'success'
[IO.File]::WriteAllText("$($success.job)\commit", 'test')
Assert ((RunHelper $success) -eq 0) 'Successful updater failed'
Assert ((Get-Content -LiteralPath "$($success.target)\version.txt") -eq 'new') 'New version not installed'
$backup = Get-Content -LiteralPath "$($success.job)\complete"
Assert ((Get-Content -LiteralPath "$backup\version.txt") -eq 'old') 'Old version not retained'
Start-Sleep -Milliseconds 300
Assert (Test-Path -LiteralPath "$($success.target)\started.txt") 'New app not restarted'
$badHash = Fixture 'hash-failure'
$badHash.manifest.sha256 = '0' * 64
Assert ((RunHelper $badHash) -ne 0) 'Bad hash accepted'
Assert ((Get-Content -LiteralPath "$($badHash.target)\version.txt") -eq 'old') 'Bad hash changed installation'
$traversal = Fixture 'traversal'
$zip = [IO.Compression.ZipFile]::Open("$($traversal.job)\package.zip", [IO.Compression.ZipArchiveMode]::Update)
try { $entry = $zip.CreateEntry('../escape.txt'); $stream = $entry.Open(); $stream.WriteByte(42); $stream.Dispose() } finally { $zip.Dispose() }
$traversal.manifest.sha256 = (Get-FileHash -LiteralPath "$($traversal.job)\package.zip").Hash.ToLowerInvariant()
Assert ((RunHelper $traversal) -ne 0) 'Traversal archive accepted'
Assert ((Get-Content -LiteralPath "$($traversal.target)\version.txt") -eq 'old') 'Traversal changed installation'
$rollback = Fixture 'rollback'
$zip = [IO.Compression.ZipFile]::Open("$($rollback.job)\package.zip", [IO.Compression.ZipArchiveMode]::Update)
try { $entry = $zip.GetEntry('fuji_san.exe'); $stream = $entry.Open(); $stream.SetLength(0); $stream.Dispose() } finally { $zip.Dispose() }
$rollback.manifest.sha256 = (Get-FileHash -LiteralPath "$($rollback.job)\package.zip").Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$($rollback.job)\commit", 'test')
Assert ((RunHelper $rollback) -ne 0) 'Invalid executable accepted'
Assert ((Get-Content -LiteralPath "$($rollback.target)\version.txt") -eq 'old') 'Launch failure did not restore original'
Start-Sleep -Milliseconds 300
Assert (Test-Path -LiteralPath "$($rollback.target)\started.txt") 'Original app not restarted after rollback'
Write-Output 'PASS: install/restart, original bundle retained, hash rejection, traversal rejection, launch failure rollback'
