"""Workload set for interpreter-level comparison. Same script, both interpreters.

Prints one JSON line: {workload: best_seconds}. Each workload runs REPS times and
keeps the minimum, to reduce scheduler/frequency noise.
"""
import json
import sys
import time

REPS = 3


def timed(fn):
    best = None
    for _ in range(REPS):
        t0 = time.perf_counter()
        fn()
        dt = time.perf_counter() - t0
        if best is None or dt < best:
            best = dt
    return best


def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)


def w_fib():
    fib(27)


def w_int():
    s = 0
    i = 0
    while i < 6_000_000:
        s = (s + i * 3) % 1000003
        i += 1
    return s


def w_float():
    import math
    s = 0.0
    for i in range(2_000_000):
        s += math.sqrt(i & 0xFFFF)
    return s


def w_dict():
    d = {}
    for i in range(1_000_000):
        d[i & 0xFFFF] = i
    s = 0
    for v in d.values():
        s += v
    return s


def w_sort():
    import random
    r = random.Random(1234)
    a = [r.randrange(1 << 30) for _ in range(300_000)]
    a.sort()
    return a[0]


def w_str():
    parts = []
    for i in range(200_000):
        parts.append("item-%d=%s" % (i, str(i * 7)))
    s = ",".join(parts)
    return len(s)


def w_json():
    import json as j
    payload = [{"a": i, "b": "x" * 10, "c": [1, 2, 3]} for i in range(2000)]
    for _ in range(100):
        j.loads(j.dumps(payload))


def w_regex():
    import re
    txt = "\n".join("user%d@example.com 2026-10-%02d" % (i, i % 28 + 1) for i in range(100_000))
    pat = re.compile(r"user(\d+)@(\w+)\.com")
    for _ in range(5):
        pat.findall(txt)


def w_sha():
    import hashlib
    b = b"x" * 1048576
    for _ in range(64):
        hashlib.sha256(b).digest()


def w_class():
    class P:
        __slots__ = ("x", "y")

        def __init__(self, x, y):
            self.x = x
            self.y = y

        def norm(self):
            return self.x * self.x + self.y * self.y

    ps = [P(i, i + 1) for i in range(1000)]
    t = 0
    for _ in range(2000):
        for p in ps:
            t += p.norm()
    return t


def w_exc():
    n = 0
    for i in range(300_000):
        try:
            if i & 1:
                raise ValueError(i)
        except ValueError:
            n += 1
    return n


WORKLOADS = [
    ("fib", w_fib),
    ("int_loop", w_int),
    ("float_loop", w_float),
    ("dict", w_dict),
    ("sort", w_sort),
    ("str", w_str),
    ("json", w_json),
    ("regex", w_regex),
    ("sha256", w_sha),
    ("class_call", w_class),
    ("exception", w_exc),
]

out = {}
fib(20)  # warmup
for name, fn in WORKLOADS:
    out[name] = round(timed(fn), 6)
print(json.dumps({"version": sys.version.split()[0], "python": sys.executable, "times": out}))
