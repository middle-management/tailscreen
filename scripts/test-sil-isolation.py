#!/usr/bin/env python3
"""Fixtures for check-sil-isolation.py.

Same discipline as scripts/test-callback-isolation.py: a checker that fails
open turns "nobody looked" into "CI says it is fine". The SIL and the mangled
names below are real compiler output, from a package built with
`-Xswiftc -emit-sil` in the two states that matter.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

CHECKER = Path(__file__).resolve().parent / "check-sil-isolation.py"

# A closure that inherited actor isolation. `$s3App5ModelC8scheduleyyFyycfU_`
# demangles to "closure #1 () -> () in App.Model.schedule() -> ()".
OFFENDER = """\
// closure #1 in Model.schedule()
// Isolation: global_actor. type: MainActor
sil private [ossa] @$s3App5ModelC8scheduleyyFyycfU_ : $@convention(thin) () -> () {
bb0:
  %0 = function_ref @swift_task_isCurrentExecutor : $@convention(thin) (Builtin.Executor) -> Bool
  %1 = tuple ()
  return %1
} // end sil function '$s3App5ModelC8scheduleyyFyycfU_'
"""

# The stdlib helper every precondition calls. It is the mechanism, not an
# instance of the bug, and it appears in EVERY module that has one — so a
# checker that fails to filter it reports a finding on healthy code forever.
STDLIB_HELPER = """\
sil public_external [transparent] @$ss22_checkExpectedExecutor14_filenameStart01_D6Length01_D7IsASCII5_line9_executoryBp_BwBi1_BwBetF : $@convention(thin) (Builtin.RawPointer, Builtin.Word, Builtin.Int1, Builtin.Word, Builtin.Executor) -> () {
bb0:
  %5 = function_ref @swift_task_isCurrentExecutor : $@convention(thin) (Builtin.Executor) -> Bool
  %6 = tuple ()
  return %6
} // end sil function '$ss22_checkExpectedExecutor14_filenameStart01_D6Length01_D7IsASCII5_line9_executoryBp_BwBi1_BwBetF'
"""

CLEAN = """\
// Model.schedule()
// Isolation: global_actor. type: MainActor
sil hidden [ossa] @$s3App5ModelC8scheduleyyF : $@convention(method) (@guaranteed Model) -> () {
bb0(%0 : @guaranteed $Model):
  %1 = tuple ()
  return %1
} // end sil function '$s3App5ModelC8scheduleyyF'
"""

# The baseline keys on the mangled symbol, so the fixtures do too — they
# then need no Swift toolchain, and neither does the check itself.
OFFENDER_SYM = "$s3App5ModelC8scheduleyyFyycfU_"


def run(sil, *args):
    proc = subprocess.run([sys.executable, str(CHECKER), "-", *args],
                          input=sil, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def main():
    failures = []

    def check(name, cond, detail=""):
        print("%-4s %s" % ("ok" if cond else "FAIL", name))
        if not cond:
            failures.append((name, detail))

    code, out = run(CLEAN + OFFENDER + STDLIB_HELPER, "--report")
    check("finds the isolation-inheriting closure, by name",
          OFFENDER_SYM in out and "1 function(s)" in out, out)
    check("filters the stdlib helper every precondition calls",
          "_checkExpectedExecutor" not in out, out)

    code, out = run(CLEAN + STDLIB_HELPER, "--report")
    check("clean SIL reports nothing", "0 function(s)" in out, out)

    code, out = run("this is not SIL\n", "--report")
    check("refuses input that is not SIL (a failed build must not read as "
          "clean)", code == 2, out)

    with tempfile.TemporaryDirectory() as tmp:
        baseline = Path(tmp) / "baseline.txt"

        code, out = run(CLEAN + OFFENDER, "--baseline", str(baseline))
        check("no baseline is an error, not a pass", code == 2, out)

        baseline.write_text("# fixture\n%s\n" % OFFENDER_SYM)
        code, out = run(CLEAN + OFFENDER, "--baseline", str(baseline))
        check("a precondition already in the baseline passes", code == 0, out)

        baseline.write_text("# fixture\n")
        code, out = run(CLEAN + OFFENDER, "--baseline", str(baseline))
        check("a new precondition fails and is named",
              code == 1 and OFFENDER_SYM in out, out)

        baseline.write_text("# fixture\n$s3App9GoneAwayCfD\n")
        code, out = run(CLEAN, "--baseline", str(baseline))
        check("a stale baseline entry is a note, not a failure",
              code == 0 and "no longer present" in out, out)

    for name, detail in failures:
        print("\n--- %s ---\n%s" % (name, detail))
    if failures:
        print("%d fixture(s) failed — the checker does not do what it claims."
              % len(failures))
        return 1
    print("\n8 fixtures pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
