"""Extra PGO training: exercise imports, the parser/compiler and common stdlib
code paths that the micro-benchmarks do not touch, so the profile is not only
optimised for tight loops.
"""
import os
import py_compile
import sys
import sysconfig

# 1. heavy imports
for mod in ("asyncio", "ssl", "sqlite3", "decimal", "email", "http.client",
            "xml.etree.ElementTree", "csv", "pickle", "argparse", "unittest",
            "dataclasses", "typing", "pathlib", "logging", "subprocess",
            "urllib.parse", "collections", "concurrent.futures", "threading"):
    __import__(mod)

# 2. some parsing / formatting work
import json
import urllib.parse
for i in range(2000):
    urllib.parse.urlencode({"a": i, "b": "x y z"})
    json.loads(json.dumps({"k": i, "v": [1, 2, 3]}))

# 3. compile a slice of the stdlib (parser + compiler + symtable)
stdlib = sysconfig.get_paths()["stdlib"]
count = 0
for root, _dirs, files in os.walk(stdlib):
    for name in files:
        if name.endswith(".py") and count < 400:
            try:
                py_compile.compile(os.path.join(root, name), doraise=False)
            except Exception:
                pass
            count += 1
print("training done, compiled", count)
