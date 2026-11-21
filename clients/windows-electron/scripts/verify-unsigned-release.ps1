param([Parameter(Mandatory=$true)][string]$AppDirectory)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $AppDirectory).Path
if (Test-Path -LiteralPath (Join-Path $root 'UNSIGNED-TEST-ONLY.txt')) { throw 'Test-only build is not a release' }
$report = Get-Content -LiteralPath (Join-Path $root 'WINDOWS-SIGNATURE.json') -Raw | ConvertFrom-Json
if ($report.status -ne 'UNSIGNED_RELEASE' -or $report.releaseAllowed -ne $true -or $report.publisherSignatureVerified -ne $false) { throw 'Unexpected release policy' }
$entries = @(Get-ChildItem -LiteralPath $root -Recurse -Force)
if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Links are not allowed' }
$files = @($entries | Where-Object { -not $_.PSIsContainer -and $_.FullName -ne (Join-Path $root 'WINDOWS-SIGNATURE.json') })
if ($files.Count -ne $report.fileCount -or @($report.files).Count -ne $files.Count) { throw 'Inventory count mismatch' }
$expected = @{}
foreach ($entry in $report.files) {
  if ($entry.path -match '(^/|\\|:|(^|/)\.\.(/|$))' -or $expected.ContainsKey($entry.path) -or $entry.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid inventory entry' }
  $expected[$entry.path] = $entry.sha256
}
foreach ($file in $files) {
  $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\','/')
  if (!$expected.ContainsKey($relative) -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower() -ne $expected[$relative]) { throw "Package integrity mismatch: $relative" }
}
foreach ($required in @('SMS Success Monitor.exe', 'resources/app.asar')) {
  if (!$expected.ContainsKey($required)) { throw "Missing: $required" }
}
Write-Output "PASS: explicit unsigned release; $($files.Count) file hashes verified. Publisher trust is NOT verified."
