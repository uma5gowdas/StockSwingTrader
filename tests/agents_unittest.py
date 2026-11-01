"""unittest helper for the agent suites (run with .venv-agents/bin/python).

run_tests(module_or_cases) runs the tests and prints the two summary lines
tests/test_runner.sh parses:
    Tests Passed:  N
    Tests Failed:  N     (errors count as failures)
It returns the process exit code (0 only if everything passed).
"""

import os
import sys
import unittest

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_DIR not in sys.path:
    sys.path.insert(0, PROJECT_DIR)


def run_tests(module_or_cases) -> int:
    loader = unittest.TestLoader()
    if isinstance(module_or_cases, (list, tuple)):
        suite = unittest.TestSuite(loader.loadTestsFromTestCase(c) for c in module_or_cases)
    else:
        suite = loader.loadTestsFromModule(module_or_cases)
    result = unittest.TextTestRunner(verbosity=2, stream=sys.stdout).run(suite)
    failed = len(result.failures) + len(result.errors) + len(getattr(result, "unexpectedSuccesses", []))
    passed = result.testsRun - failed - len(result.skipped)
    print("")
    print("Tests Passed:  %d" % passed)
    print("Tests Failed:  %d" % failed)
    return 0 if failed == 0 and passed > 0 else 1
