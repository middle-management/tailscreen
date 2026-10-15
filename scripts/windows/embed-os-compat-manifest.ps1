# Embed os-compat.manifest (Windows 10/11 supportedOS) into each exe that links
# libtailscale, merged with whatever manifest the exe already carries.
#
# Mandatory: tailscale.com reads the OS version through wingoes, which panics
# when GetVersionEx (manifest-gated, reports 6.2 without this) disagrees with
# the kernel's real version. The crash lands on the first control dial.
param(
  [string[]]$Exe = @('tailscreen.exe', 'tsnet-probe.exe'),
  [string]$Manifest = (Join-Path $PSScriptRoot 'os-compat.manifest')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Same lookup as embed-regfree-manifest.ps1; duplicated because these scripts
# are deliberately standalone.
function Find-SdkTool([string]$name) {
  $onPath = Get-Command $name -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  $roots = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
    "$env:ProgramFiles\Windows Kits\10\bin"
  ) | Where-Object { $_ -and (Test-Path $_) }
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

if (-not (Test-Path $Manifest)) { throw "no $Manifest" }
$mt = Find-SdkTool 'mt.exe'
Write-Host "mt: $mt"

foreach ($e in $Exe) {
  if (-not (Test-Path $e)) { throw "no $e here — run from dist/" }

  # mt fails cleanly when there is no embedded manifest — a tolerated probe,
  # so reset the exit code (pwsh exits with the last $LASTEXITCODE).
  $existing = Join-Path ([System.IO.Path]::GetTempPath()) "tailscreen-compat-existing.manifest"
  if (Test-Path $existing) { Remove-Item $existing -Force }
  & $mt -nologo "-inputresource:$e;#1" "-out:$existing" 2>$null
  $hadEmbedded = ($LASTEXITCODE -eq 0) -and (Test-Path $existing)
  $global:LASTEXITCODE = 0

  if ($hadEmbedded) {
    & $mt -nologo -manifest $existing $Manifest "-outputresource:$e;#1"
  } else {
    & $mt -nologo -manifest $Manifest "-outputresource:$e;#1"
  }
  if ($LASTEXITCODE -ne 0) { throw "mt.exe embed into $e failed ($LASTEXITCODE)" }

  $check = Join-Path ([System.IO.Path]::GetTempPath()) "tailscreen-compat-check.manifest"
  if (Test-Path $check) { Remove-Item $check -Force }
  & $mt -nologo "-inputresource:$e;#1" "-out:$check"
  if ($LASTEXITCODE -ne 0) { throw "could not read back $e's embedded manifest ($LASTEXITCODE)" }
  if (-not (Select-String -Path $check -Pattern '8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a' -Quiet)) {
    throw "$e's embedded manifest lacks the Windows 10 supportedOS entry"
  }
  Write-Host "${e}: Windows 10 supportedOS embedded (merged: $hadEmbedded)"
}

exit 0
