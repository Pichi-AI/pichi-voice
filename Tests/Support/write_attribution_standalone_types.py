#!/usr/bin/env python3
"""Copy actual shared canonical value contracts for bounded production-code tests."""
from pathlib import Path
import sys

# The former --fingerprint option remains accepted: the shared value file now owns the
# unchanged framing utility, so all callers compile one canonical implementation.
source = Path("Sources/Fluid/Services/Meeting/Backend/MeetingCanonicalEvidenceTypes.swift")
Path(sys.argv[1]).write_text(source.read_text())
