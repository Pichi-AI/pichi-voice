#!/usr/bin/env python3
"""Registered SAFE self-tests only. This never opts into live HTTP."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("local_api_live_harness_tests", Path(__file__).with_name("test_local_api_live_harness.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromModule(module))
print("Harness self-tests only; live HTTP was not run.")
sys.exit(0 if result.wasSuccessful() and result.testsRun > 0 else 1)
