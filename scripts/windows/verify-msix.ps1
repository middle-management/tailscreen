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
  # .ExitCode is readable after it dies. Get-Process after exit throws, and the
  # exit code is the single most discriminating piece of evidence available here:
  # 0xC0000135 is a missing DLL, 0xC0000409 a security check, and a WinAppSDK
  # bootstrapper HRESULT is something else again. Without it, "gone within 12s"
  # is a symptom shared by every hypothesis.
  $handle = Get-Process -Id $pid2 -ErrorAction SilentlyContinue

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
        '0xC0000409' { Write-Host '  => STATUS_STACK_BUFFER_OVERRUN (also Swift/CRT fatalError)' }
        '0xC000001D' { Write-Host '  => STATUS_ILLEGAL_INSTRUCTION' }
        default      { Write-Host '  => not a loader status; likely a clean exit from our own code' }
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
    $script:verdict = 'exited'
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

if ($script:verdict -ne 'ok') {
  Write-Error "packaged Tailscreen did not stay running — see the stage marked FAILED above"
  exit 1
}
exit 0
