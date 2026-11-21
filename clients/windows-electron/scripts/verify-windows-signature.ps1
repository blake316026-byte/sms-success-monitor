param(
  [Parameter(Mandatory = $true)][string]$AppDirectory,
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$ExpectedThumbprint
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath $AppDirectory).Path
$expected = $ExpectedThumbprint.ToUpperInvariant()
$main = Join-Path $root 'SMS Success Monitor.exe'
if (!(Test-Path -LiteralPath $main -PathType Leaf)) { throw 'Missing client executable' }
if (Test-Path -LiteralPath (Join-Path $root 'UNSIGNED-TEST-ONLY.txt')) { throw 'Unsigned test builds cannot be released' }
$entries = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)
if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
  throw 'Package must not contain links or reparse points'
}
$extensions = @('.exe', '.dll', '.node', '.sys', '.efi', '.scr', '.msi', '.appx', '.appxbundle', '.msix', '.msixbundle', '.cat', '.cab', '.xap', '.vbs', '.wsf', '.ps1')
$files = @($entries | Where-Object { !$_.PSIsContainer -and $extensions -contains $_.Extension.ToLowerInvariant() })
if (!$files.Count) { throw 'No signable files in package' }
$report = @()
foreach ($file in $files) {
  $relative = $file.FullName.Substring($root.Length + 1)
  $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
  if ($signature.Status -ne 'Valid' -or !$signature.SignerCertificate) {
    throw ("Invalid signature: " + $relative + " [" + $signature.Status + "]")
  }
  $cert = $signature.SignerCertificate
  if ($cert.Thumbprint.ToUpperInvariant() -ne $expected) { throw ("Unexpected publisher: " + $relative) }
  if ($cert.Subject -eq $cert.Issuer) { throw ("Self-signed certificate: " + $relative) }
  $eku = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
  if ($eku -notcontains '1.3.6.1.5.5.7.3.3') { throw ("Not a code signing certificate: " + $relative) }
  if (!$signature.TimeStamperCertificate) { throw ("Missing trusted timestamp: " + $relative) }
  $report += [ordered]@{
    path = $relative
    sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    publisher = $cert.Subject
    thumbprint = $cert.Thumbprint
    timestampPublisher = $signature.TimeStamperCertificate.Subject
  }
}
[ordered]@{
  status = 'VERIFIED'
  releaseAllowed = $true
  expectedThumbprint = $expected
  fileCount = $files.Count
  files = $report
} | ConvertTo-Json -Depth 5 -Compress
