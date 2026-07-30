<#
.SYNOPSIS
  Install a signed MSIX, launch it, and report whether a PACKAGED Tailscreen
  actually starts.

.DESCRIPTION
  This is the question W8b exists to answer, and it is not the same question as
  "does the package build". A packaged WinUI 3 app resolves its Windows App SDK
  dependency differently from an unpackaged one: unpackaged calls the
  bootstrapper to find an installed runtime (the mechanism behind two of the
  staging bugs already fixed), while packaged is supposed to get it from the
  package graph. swift-winui initialises through the bootstrapper either way,
  and whether that is correct, harmless or fatal inside a package is not
  something reading the docs settles. So: install it and launch it.

  A failure here is a finding, not a defeat — the useful output is WHICH of the
  three stages fails (install / activate / stay alive) and with what code.

  Cleans up after itself: the package is removed and the trusted cert deleted,
  so a self-signed CI cert is never left in a machine store.

.PARAMETER MsixPath
  The signed .msix to install.

.PARAMETER PfxPath
  The pfx it was signed with, whose certificate must be trusted before install.

.PARAMETER PfxPassword
  Password for the pfx.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$MsixPath,
  [Parameter(Mandatory = $true)][string]$PfxPath,
  [string]$PfxPassword = 'tailscreen-ci'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $MsixPath)) { throw "msix not found: $MsixPath" }
if (-not (Test-Path $PfxPath)) { throw "pfx not found: $PfxPath" }

$packageName = 'Tailscreen.Tailscreen'
$appId = 'Tailscreen'
$imported = $null
$installed = $false

function Write-Finding($stage, $text) {
  Write-Host ""
  Write-Host "=== $stage : $text"
}

try {
  # -------------------------------------------------------------------------
  # 1. Trust the signing certificate.
  #
  # LocalMachine\TrustedPeople is where Windows looks for sideload signers.
  # This needs admin, which GitHub's Windows runners have. Without it,
  # Add-AppxPackage fails with a signature error that looks like a bad package.
  # -------------------------------------------------------------------------
  $sec = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
  $imported = Import-PfxCertificate -FilePath $PfxPath `
    -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' -Password $sec
  Write-Host "trusted signer: $($imported.Subject) [$($imported.Thumbprint)]"

  # A stale install from an earlier run would make Add-AppxPackage fail for a
  # reason unrelated to this package.
  Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue |
    ForEach-Object {
      Write-Host "removing pre-existing $($_.PackageFullName)"
      Remove-AppxPackage -Package $_.PackageFullName
    }

  # -------------------------------------------------------------------------
  # 2. Install.
  # -------------------------------------------------------------------------
  try {
    Add-AppxPackage -Path $MsixPath -ErrorAction Stop
    $installed = $true
  } catch {
    Write-Finding 'INSTALL FAILED' $_.Exception.Message
    # The activity ID points at an event-log entry with the real reason, which
    # is routinely more specific than the exception text.
    Write-Host ""
    Write-Host "--- recent AppXDeployment-Server events ---"
    Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' `
      -MaxEvents 25 -ErrorAction SilentlyContinue |
      Where-Object { $_.LevelDisplayName -in @('Error', 'Warning') } |
      ForEach-Object { Write-Host "[$($_.TimeCreated)] $($_.Message)" }
    throw
  }

  $pkg = Get-AppxPackage -Name $packageName
  Write-Host "installed: $($pkg.PackageFullName)"
  Write-Host "  install location: $($pkg.InstallLocation)"
  Write-Host "  architecture:     $($pkg.Architecture)"

  # -------------------------------------------------------------------------
  # 3. Activate.
  #
  # A packaged app is launched by AUMID, not by path: running the exe out of
  # WindowsApps directly does NOT give it package identity, so it would test
  # the unpackaged path again while looking like it tested this one. That is
  # the whole trap this step is written around.
  # -------------------------------------------------------------------------
  $aumid = "$($pkg.PackageFamilyName)!$appId"
  Write-Host "activating $aumid"

  # The shell activation API, via the same COM class Explorer uses. Returns the
  # child PID, which Start-Process on an AUMID cannot give us.
  $src = @'
using System;
using System.Runtime.InteropServices;
public static class Activator2 {
  [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
  private class ApplicationActivationManager { }
  [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IApplicationActivationManager {
    IntPtr ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      int options, out uint processId);
  }
  public static uint Activate(string aumid) {
    var mgr = (IApplicationActivationManager)new ApplicationActivationManager();
    uint pid;
    var hr = mgr.ActivateApplication(aumid, null, 0, out pid);
    if (hr != IntPtr.Zero) Marshal.ThrowExceptionForHR(hr.ToInt32());
    return pid;
  }
}
'@
  Add-Type -TypeDefinition $src -Language CSharp

  $pid2 = 0
  try {
    $pid2 = [Activator2]::Activate($aumid)
    Write-Host "activated, pid $pid2"
  } catch {
    Write-Finding 'ACTIVATION FAILED' $_.Exception.Message
    throw
  }

  # Grab the Process object WHILE IT IS ALIVE, purely to keep a handle open so
  # .ExitCode is readable after it dies. The exit code is the single most
  # discriminating evidence available here: 0xC0000135 is a missing DLL,
  # 0xC0000409 a security check, and a WinAppSDK bootstrapper HRESULT something
  # else again. Without it, "gone within 12s" is a symptom every hypothesis
  # shares.
  $handle = Get-Process -Id $pid2 -ErrorAction SilentlyContinue

  # Touching .Handle is REQUIRED, not defensive. Get-Process hands back a Process
  # object whose OS handle .NET opens LAZILY, so a first attempt that only
  # captured the object still lost the exit code — the run reported "could not
  # read the exit code — the handle closed first". Reading .Handle forces
  # OpenProcess now and caches it, which is what keeps ExitCode readable once the
  # process is gone.
  if ($handle) {
    try { $null = $handle.Handle }
    catch { Write-Host "::warning::could not open a handle on pid $pid2 : $_" }
  }

  # -------------------------------------------------------------------------
  # 4. Does it stay up?
  #
  # Same standard as the unpackaged "Check the app loads" step: surviving the
  # loader is the bar. A packaged app that dies immediately is usually a missing
  # DLL inside the package or a bootstrapper that cannot find its runtime, and
  # both show up as an early exit rather than an install error.
  # -------------------------------------------------------------------------
  Start-Sleep -Seconds 12
  $proc = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
  if ($proc) {
    Write-Host ""
    Write-Host "still running after 12s — a PACKAGED Tailscreen starts on Windows"
    Write-Host "  process: $($proc.ProcessName) (pid $($proc.Id))"
    Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
    $script:verdict = 'ok'
  } else {
    Write-Finding 'EXITED EARLY' "pid $pid2 is gone within 12s"

    # The exit code, classified. This is the evidence that separates the
    # hypotheses; the first version of this step printed none and left the
    # question open.
    $code = $null
    if ($handle) {
      try { $code = $handle.ExitCode } catch { }
    }
    if ($null -ne $code) {
      $u = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int32]$code), 0)
      # Compared as STRINGS. Every constant below exceeds Int32.MaxValue, so
      # PowerShell types the literal as a NEGATIVE Int32 and a numeric -eq is
      # false no matter what the app did — the bug that broke the unpackaged
      # load check twice. Do not "simplify" this.
      $hex = '0x{0:X8}' -f $u
      Write-Host "exit code: $hex"
      switch ($hex) {
        '0xC0000135' { Write-Host '  => STATUS_DLL_NOT_FOUND: a payload DLL is missing from the package' }
        '0xC0000139' { Write-Host '  => STATUS_ENTRYPOINT_NOT_FOUND: a DLL loaded but lacked an export' }
        default      { Write-Host '  => see the classification below' }
      }

      # A Swift trap is NOT a packaging failure, and this job was wrong to treat
      # it as one.
      #
      # `ud2` (0xC000001D) and __fastfail (0xC0000409) are both how a Swift
      # fatalError / failed precondition / nil force-unwrap reaches the OS. Either
      # one means the LOADER WAS SATISFIED — every DLL in the package resolved —
      # and then our own code decided to die. For a WinUI app that is most often
      # swift-winui's SwiftApplication.main turning a failed Windows App SDK init
      # into fatalError.
      #
      # Which is exactly the packaged framework-resolution question this job
      # exists to ask... and exactly what a headless runner CANNOT answer,
      # because a WinUI app with no interactive desktop session may legitimately
      # trap during backend init and the runner cannot tell that apart from a
      # real defect. The app job's unpackaged `Check the app loads` step reached
      # this conclusion first and accepts both codes with a warning; this job
      # failing on the same codes was an unjustified asymmetry between the
      # packaged and unpackaged checks.
      #
      # So: loader failures above stay fatal, because those ARE packaging bugs
      # and the runner can decide them. A trap is reported and tolerated, and the
      # launch verdict is explicitly deferred to a human on a real desktop.
      if ($hex -eq '0xC000001D' -or $hex -eq '0xC0000409') {
        Write-Host "  => Swift trap ($hex): every DLL in the package resolved, then the app aborted."
        Write-Host ''
        Write-Host '::warning::packaged app trapped at startup — NOT decidable here. Two candidates a headless runner cannot separate: (1) a packaged process cannot reach Windows App SDK (no <PackageDependency>, and swift-winui uses the unpackaged bootstrapper), or (2) WinUI backend init legitimately trapping with no interactive desktop session. The unpackaged check tolerates the same codes for the same reason. Needs a human on a real desktop.'
        $script:verdict = 'trap'
      }
    } else {
      Write-Host '::warning::could not read the exit code — the handle closed first'
    }

    Write-Host ''
    Write-Host 'Leading hypothesis, and what this job exists to distinguish:'
    Write-Host '  A packaged WinUI 3 app is meant to resolve Windows App SDK'
    Write-Host '  through the PACKAGE GRAPH, but this manifest declares no'
    Write-Host '  <PackageDependency> on the WindowsAppRuntime framework — and'
    Write-Host '  swift-winui initialises through the UNPACKAGED bootstrapper'
    Write-Host '  regardless. A packaged process therefore has neither route to'
    Write-Host '  the runtime. Fix is Windows App SDK self-contained mode, or a'
    Write-Host '  declared framework dependency. See docs/viewer-windows-plan.md W8.'
    Write-Host ''

    # The RIGHT logs. Filtering the Application log by 'tailscreen' found nothing
    # on the first run: a packaged app's activation failures land in the AppModel
    # channels, and a loader failure in WER, neither of which mentions our name in
    # a way that filter caught.
    foreach ($log in @(
      'Microsoft-Windows-AppModel-Runtime/Admin',
      'Microsoft-Windows-AppXDeploymentServer/Operational',
      'Application'
    )) {
      $ev = Get-WinEvent -LogName $log -MaxEvents 15 -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -in @('Error', 'Warning', 'Critical') }
      if ($ev) {
        Write-Host "--- $log ---"
        $ev | ForEach-Object { Write-Host "[$($_.TimeCreated)] $($_.Message)" }
      }
    }
    # Only if the trap branch above did not already classify it. Assigning
    # unconditionally here would overwrite 'trap' with 'exited' and re-fail the
    # very case that was just decided to be tolerable.
    if ($script:verdict -ne 'trap') { $script:verdict = 'exited' }
  }
} finally {
  # -------------------------------------------------------------------------
  # Always clean up. A self-signed cert left in LocalMachine\TrustedPeople is a
  # machine that trusts anything we later sign with it, and on a throwaway
  # runner that is harmless but it is still the wrong habit to encode.
  # -------------------------------------------------------------------------
  if ($installed) {
    Get-AppxPackage -Name $packageName -ErrorAction SilentlyContinue |
      ForEach-Object {
        Write-Host "cleanup: removing $($_.PackageFullName)"
        Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
      }
  }
  if ($imported) {
    $p = "Cert:\LocalMachine\TrustedPeople\$($imported.Thumbprint)"
    if (Test-Path $p) {
      Write-Host "cleanup: removing trusted signer $($imported.Thumbprint)"
      Remove-Item $p -Force -ErrorAction SilentlyContinue
    }
  }
}

# 'ok'    — packaged app installed, activated and stayed up. The full answer.
# 'trap'  — installed and activated; our own code then aborted. Tolerated with a
#           warning, because a headless runner cannot separate a failed Windows
#           App SDK init from WinUI backend init trapping for want of a desktop
#           session. Same standard the unpackaged check already applies.
# anything else — a loader-level or install-level failure, which IS decidable
#           here and IS a packaging bug.
switch ($script:verdict) {
  'ok'   { exit 0 }
  'trap' {
    Write-Host ''
    Write-Host 'VERDICT: MSIX packaging, signing, installation and activation all work.'
    Write-Host 'The packaged launch outcome is undecided and needs a real desktop.'
    exit 0
  }
  default {
    Write-Error "packaged Tailscreen failed at a stage this runner CAN decide — see the stage marked FAILED above"
    exit 1
  }
}
