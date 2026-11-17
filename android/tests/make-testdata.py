#!/usr/bin/env python3
"""Writes the synthetic files the test catalog's download scenarios use into argv[1]. Deterministic: the catalog
(harness/src/main/assets/test-catalog.json) pins these exact sizes and hashes. Each scenario gets its own bytes so
the Model Library (which shares by hash) never treats one scenario's file as another's. Prints name size sha256."""
import hashlib, os, sys
FILES = {"resume.bin": 3_000_000, "corrupt.bin": 1_000_000, "mirror.bin": 1_000_000, "pause.bin": 5_000_000, "alias.bin": 2_000_000}
for name, size in FILES.items():
    out, i = bytearray(), 0
    while len(out) < size: out += hashlib.sha256(f"{name}:{i}".encode()).digest(); i += 1
    data = bytes(out[:size])
    open(os.path.join(sys.argv[1], name), "wb").write(data)
    print(name, size, hashlib.sha256(data).hexdigest())
