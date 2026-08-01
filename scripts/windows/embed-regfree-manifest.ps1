# Embed the reg-free WinRT manifest into the app exe's RT_MANIFEST resource.
# Run from dist/ after stage-winappsdk.sh wrote tailscreen.exe.manifest.
#
# Embedding is mandatory, not a nicety: Windows ignores an external
# <exe>.manifest file whenever the exe already carries an embedded manifest,
# and lld-link may have embedded a default one. Without these 896
# activatable-class registrations the self-contained payload is decorative —
# the app dies at its first XAML type with REGDB_E_CLASSNOTREG, silently from
# CI's point of view unless the launch check runs.
#
# Merge-aware: if the exe already has an embedded manifest it is extracted and
# merged with the reg-free one (mt.exe supports multiple -manifest inputs);
# otherwise the reg-free manifest is embedded alone.
param(
  [string]$Exe = 'tailscreen.exe',
  [string]$Manifest = 'tailscreen.exe.manifest'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $Exe)) { throw "no $Exe here — run from dist/" }
if (-not (Test-Path $Manifest)) { throw "no $Manifest — stage-winappsdk.sh writes it" }

# Same versioned-bin walk as make-msix.ps1's Find-SdkTool; duplicated because
# these scripts are deliberately standalone. Host-arch subdirectory first so
# the arm64 runner uses its native tool.
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

$mt = Find-SdkTool 'mt.exe'
Write-Host "mt: $mt"

# Does the exe already carry an embedded manifest? mt fails cleanly if not —
# a tolerated probe, so the exit code must be reset afterwards (pwsh exits
# with the last $LASTEXITCODE; this family of scripts has been bitten by that
# exact trap once already).
$existing = Join-Path ([System.IO.Path]::GetTempPath()) 'tailscreen-existing.manifest'
if (Test-Path $existing) { Remove-Item $existing -Force }
& $mt -nologo "-inputresource:$Exe;#1" "-out:$existing" 2>$null
$hadEmbedded = ($LASTEXITCODE -eq 0) -and (Test-Path $existing)
$global:LASTEXITCODE = 0

if ($hadEmbedded) {
  Write-Host "merging with the exe's existing embedded manifest"
  & $mt -nologo -manifest $existing $Manifest "-outputresource:$Exe;#1"
} else {
  Write-Host "no existing embedded manifest; embedding the reg-free manifest alone"
  & $mt -nologo -manifest $Manifest "-outputresource:$Exe;#1"
}
if ($LASTEXITCODE -ne 0) { throw "mt.exe embed failed ($LASTEXITCODE)" }

# Read it back and count the registrations — the write succeeding is not the
# same as the content being there.
$check = Join-Path ([System.IO.Path]::GetTempPath()) 'tailscreen-check.manifest'
if (Test-Path $check) { Remove-Item $check -Force }
& $mt -nologo "-inputresource:$Exe;#1" "-out:$check"
if ($LASTEXITCODE -ne 0) { throw "could not read back the embedded manifest ($LASTEXITCODE)" }
$count = (Select-String -Path $check -Pattern 'activatableClass' -AllMatches).Matches.Count
if ($count -lt 800) {
  throw "embedded manifest has only $count activatableClass entries — expected ~896"
}
Write-Host "embedded manifest verified: $count activatableClass registrations"

exit 0
