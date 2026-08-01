# Staged-binary architecture check, extracted from windows-build.yml when the
# arm64 leg needed it. Compares every staged PE's machine type against the app
# exe's own — the assertion that caught the ARM64 bootstrapper beside an x64
# exe. Arch-neutral by construction: the reference is read from the exe, so it
# validates an arm64 staging exactly as it validates x64. Run from dist/.
function Get-PEMachine($path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $br = [IO.BinaryReader]::new($fs)
    $fs.Position = 0x3C
    $pe = $br.ReadInt32()
    $fs.Position = $pe + 4
    return '{0:X4}' -f $br.ReadUInt16()
  } finally { $fs.Dispose() }
}
$want = Get-PEMachine 'tailscreen.exe'
Write-Host "app architecture: $want (8664 = x64, AA64 = ARM64)"
$bad = @()
Get-ChildItem -Recurse -File |
  Where-Object { $_.Extension -in '.dll', '.exe' } |
  ForEach-Object {
    $m = Get-PEMachine $_.FullName
    if ($m -ne $want) {
      $bad += "  $($_.FullName.Substring($PWD.Path.Length + 1)) is $m"
    }
  }
if ($bad.Count -gt 0) {
  Write-Error ("architecture mismatch — these cannot load into a $want process:`n" + ($bad -join "`n"))
  exit 1
}
Write-Host "all staged binaries are $want"

      # Catch a missing DLL HERE rather than on a tester's desktop.
      #
      # A WinUI app can't run to completion on a headless runner, so this does
      # not assert success — it asserts the absence of two specific NTSTATUS
      # exit codes that mean the loader gave up before any of our code ran:
      #
      #   0xC0000135 STATUS_DLL_NOT_FOUND       — a DLL is missing
      #   0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND — a DLL is the wrong version
      #
      # Every other outcome (including a headless-display failure, and including
      # a timeout, which means it got far enough to sit in an event loop) is
      # accepted. Narrow on purpose: this is a packaging check, not a UI test.
      #
      # 0xC000001D is called out separately because it is what a Swift trap
      # looks like on Windows — fatalError, a failed precondition and a nil
      # force-unwrap all emit `ud2`, which the OS reports as an illegal
      # instruction. That means the loader was satisfied and OUR code ran and
      # then rejected something, which is a completely different bug class from
      # a missing DLL and worth naming rather than lumping into "other". It does
      # not fail the build: a WinUI app with no interactive desktop session may
      # legitimately trap during backend init, and the runner cannot tell that
      # apart from a real defect. A human with a real desktop can.
      #
      # ExitCode is an Int32 and these statuses are negative when read as one.
      # `[uint32]` on a negative Int32 THROWS in PowerShell rather than
      # reinterpreting the bits, and `-band 0xFFFFFFFF` does NOT rescue it:
      # PowerShell types that literal as Int32 -1, so the mask is a no-op and
      # the value stays negative. Both mistakes were made here in turn.
      #
      # BitConverter reinterprets the four bytes with no dependency on how the
      # language types integer literals, which is the property that matters.
      #
      # The classification is wrapped because a bug in THIS step must not fail
      # the build: it can only legitimately fail for the two loader statuses,
      # and if the code can't be read then it can't be claimed to be either.
