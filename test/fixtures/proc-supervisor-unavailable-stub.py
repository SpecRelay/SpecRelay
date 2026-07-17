#!/usr/bin/env python3
"""proc-supervisor-unavailable-stub.py — deterministic test-only stand-in for
py/proc_supervisor.py that always reports process-group supervision as
UNAVAILABLE (spec 0029, section 22.1, "honest foreground-fallback trigger").

Used ONLY via the SPECRELAY_PROC_SUPERVISOR_PY test-seam
(lib/specrelay/providers/provider.sh) to exercise the AE fixture
(test/executor_finalization_test.sh) deterministically, without depending on
an actual platform that lacks os.setsid/os.killpg. Every other subcommand is
unreachable once `available` reports "no" (specrelay::provider::_supervised_exec
falls back to a direct exec; specrelay::provider::reap_survivors short-circuits
to "0 not_verifiable"), so they are stubbed only defensively, never exercised.
"""

import sys


def main(argv):
    if not argv:
        return 2
    if argv[0] == "available":
        print("no")
        return 0
    sys.stderr.write(
        "proc-supervisor-unavailable-stub.py: unreachable command %r "
        "(supervision is stubbed unavailable)\n" % (argv[0],)
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
