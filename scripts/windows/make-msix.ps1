<#
.SYNOPSIS
  Pack a staged Tailscreen layout into a signed MSIX.

.DESCRIPTION
  Takes the directory the CI staging step already produces — the exe plus its
  Swift runtime, FFmpeg, libopus and WindowsAppSDK DLLs — adds an AppxManifest
  and logo assets, and packs it with MakeAppx. Signs with a self-signed
  certificate by default, which is enough to INSTALL (given the cert is trusted)
  and is not enough to DISTRIBUTE. Real distribution needs a cert whose private
  key is on FIPS 140-2 hardware; see docs/viewer-windows-plan.md W8.

  Runs on Windows only — MakeAppx and SignTool are Windows SDK tools.

.PARAMETER StageDir
  Directory holding the built app. Its contents become the package payload.

.PARAMETER OutFile
  Path of the .msix to write.

.PARAMETER Version
  Four-part version. The fourth part must be 0 (Windows reserves it).

.PARAMETER Subject
  Certificate subject, which also becomes the manifest's Publisher.

.PARAMETER PfxPath
  Optional existing .pfx to sign with. When omitted a self-signed code-signing
  cert is created and exported here.

.PARAMETER PfxPassword
  Password for the pfx.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$StageDir,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [string]$Version = '0.0.1.0',
  [string]$Subject = 'CN=Tailscreen CI, O=Tailscreen, C=SE',
  [string]$PfxPath,
  [string]$PfxPassword = 'tailscreen-ci'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pkgSrc = Join-Path $repoRoot 'packaging/windows'

if (-not (Test-Path $StageDir)) { throw "stage dir not found: $StageDir" }
$exe = Join-Path $StageDir 'tailscreen.exe'
if (-not (Test-Path $exe)) { throw "no tailscreen.exe in $StageDir" }

# Windows reserves the revision field for the Store. MakeAppx accepts a non-zero
# one and Store submission rejects it, so fail here where the message is useful.
if ($Version -notmatch '^\d+\.\d+\.\d+\.0$') {
  throw "Version must be four-part with a trailing 0 (got '$Version')"
}

# ---------------------------------------------------------------------------
# Locate the SDK tools. Both live under a versioned bin directory, and the
# newest is not necessarily last alphabetically (10.0.22621 vs 10.0.9 sort
# wrong as strings), so sort by parsed version.
# ---------------------------------------------------------------------------
function Find-SdkTool([string]$name) {
  # An SDK on PATH wins: it is what the developer explicitly selected.
  $onPath = Get-Command $name -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }

  $roots = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
    "$env:ProgramFiles\Windows Kits\10\bin"
  ) | Where-Object { $_ -and (Test-Path $_) }

  # The host architecture's subdirectory, so this works on an arm64 runner too
  # rather than hardcoding x64 — the mistake that put an ARM64 bootstrapper
  # beside an x64 exe once already.
  $hostArch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'ARM64' { 'arm64' }
    'AMD64' { 'x64' }
    default { 'x64' }
  }

  $candidates = foreach ($root in $roots) {
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^\d+\.\d+\.\d+' } |
      ForEach-Object {
        $v = [version]($_.Name -replace '^(\d+\.\d+\.\d+\.\d+).*$', '$1')
        foreach ($a in @($hostArch, 'x64', 'x86')) {
          $p = Join-Path $_.FullName "$a\$name"
          if (Test-Path $p) { [pscustomobject]@{ Version = $v; Path = $p } }
        }
      }
  }
  $best = $candidates | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $best) { throw "could not find $name in any Windows SDK" }
  return $best.Path
}

$makeappx = Find-SdkTool 'makeappx.exe'
$signtool = Find-SdkTool 'signtool.exe'
Write-Host "makeappx: $makeappx"
Write-Host "signtool: $signtool"

# ---------------------------------------------------------------------------
# Certificate. Created BEFORE the manifest is written, because the manifest's
# Publisher is derived from the cert's Subject rather than being a second
# independently-maintained literal. A mismatch here is the most common MSIX
# failure and it surfaces at install time naming neither side.
# ---------------------------------------------------------------------------
if (-not $PfxPath) {
  $PfxPath = Join-Path ([System.IO.Path]::GetTempPath()) 'tailscreen-ci-msix.pfx'
}

if (Test-Path $PfxPath) {
  Write-Host "using existing pfx: $PfxPath"
  $sec = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
  $cert = Get-PfxData -FilePath $PfxPath -Password $sec
  $publisher = $cert.EndEntityCertificates[0].Subject
} else {
  Write-Host "creating a self-signed code-signing certificate"
  $cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $Subject `
    -KeyUsage DigitalSignature `
    -FriendlyName 'Tailscreen CI (self-signed, not for distribution)' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
  $sec = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
  Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $sec | Out-Null
  # X500DistinguishedName round-trips the exact encoded form. Reading .Subject
  # off the created cert is what guarantees the byte-for-byte match, instead of
  # assuming New-SelfSignedCertificate stored $Subject verbatim — it normalises
  # spacing, and that difference alone is enough to fail the install.
  $publisher = $cert.Subject
}
Write-Host "publisher (from cert): $publisher"

# ---------------------------------------------------------------------------
# Assemble the payload in a scratch layout so the staged directory is left
# untouched and re-runnable.
# ---------------------------------------------------------------------------
$layout = Join-Path ([System.IO.Path]::GetTempPath()) "tailscreen-msix-layout"
if (Test-Path $layout) { Remove-Item $layout -Recurse -Force }
New-Item -ItemType Directory -Path $layout | Out-Null

Copy-Item (Join-Path $StageDir '*') $layout -Recurse -Force
Copy-Item (Join-Path $pkgSrc 'Assets') $layout -Recurse -Force

# The package's own architecture must match the binaries in it. Read it off the
# exe's PE header rather than trusting a parameter: a mismatch produces an
# install that fails on the target machine, not a build error here.
$fs = [System.IO.File]::OpenRead($exe)
try {
  $br = New-Object System.IO.BinaryReader($fs)
  $fs.Position = 0x3C
  $peOff = $br.ReadInt32()
  $fs.Position = $peOff + 4
  $machine = $br.ReadUInt16()
} finally { $fs.Dispose() }

$arch = switch ('0x{0:X4}' -f $machine) {
  '0xAA64' { 'arm64' }
  '0x8664' { 'x64' }
  default  { throw ("unsupported PE machine type 0x{0:X4} in {1}" -f $machine, $exe) }
}
Write-Host "package architecture (from the exe's PE header): $arch"

$manifest = Get-Content (Join-Path $pkgSrc 'AppxManifest.xml') -Raw
$manifest = $manifest.Replace('@PUBLISHER@', [System.Security.SecurityElement]::Escape($publisher))
$manifest = $manifest.Replace('@VERSION@', $Version)
$manifest = $manifest.Replace('@ARCH@', $arch)
$manifestPath = Join-Path $layout 'AppxManifest.xml'
Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8

# Parse it before handing it to MakeAppx: a schema error from MakeAppx names a
# line in a file it generated a view of, which is harder to act on than this.
try { [xml](Get-Content $manifestPath -Raw) | Out-Null }
catch { throw "templated AppxManifest.xml is not well-formed XML: $_" }

Write-Host "payload: $((Get-ChildItem $layout -Recurse -File).Count) files"

# ---------------------------------------------------------------------------
# Pack and sign.
# ---------------------------------------------------------------------------
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

# /o overwrites, /d packs a directory. Not /l (no localisation footprint yet).
& $makeappx pack /d $layout /p $OutFile /o
if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed ($LASTEXITCODE)" }

& $signtool sign /fd SHA256 /a /f $PfxPath /p $PfxPassword $OutFile
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed ($LASTEXITCODE)" }

& $signtool verify /pa $OutFile
if ($LASTEXITCODE -ne 0) {
  # Expected for a self-signed cert that is not yet in TrustedPeople. Not fatal:
  # verify-msix.ps1 trusts the cert and then installs, which is the real test.
  Write-Host "::warning::signtool verify /pa failed — expected while the cert is untrusted"

  # RESET IT. pwsh exits with the last $LASTEXITCODE, so tolerating a native
  # command's failure means clearing the code as well as skipping the throw.
  # Without this the script printed every success line, wrote its outputs, and
  # then failed the step on the exit code of a check it had just declared
  # expected — so the install and activation steps never ran at all.
  $global:LASTEXITCODE = 0
}

$size = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
Write-Host "packed and signed: $OutFile (${size} MB)"

"MSIX_PATH=$OutFile" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"MSIX_PFX=$PfxPath" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
"MSIX_PUBLISHER=$publisher" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8

# Explicit, rather than inheriting whatever the last native command left behind.
# Every failure path above throws, so reaching here means success — and saying so
# structurally is cheaper than auditing $LASTEXITCODE at every future edit. This
# script already failed a step once while printing nothing but success.
exit 0
