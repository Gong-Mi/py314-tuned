"""Debug / introspection workloads, used both for PGO training and for measuring
the debug paths (tracing, traceback formatting, pdb stepping, cProfile).
Prints one JSON line with best-of-N seconds per workload.
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


def w_trace():
    """Line tracing: the settrace path runs on every executed line."""
    hits = 0

    def tracer(frame, event, arg):
        nonlocal hits
        if event == "line":
            hits += 1
        return tracer

    def work(n):
        total = 0
        for i in range(n):
            if i % 3:
                total += i
            else:
                total -= i
        return total

    sys.settrace(tracer)
    try:
        work(60_000)
    finally:
        sys.settrace(None)
    return hits


def w_traceback():
    import traceback

    def level3(n):
        if n % 2:
            raise ValueError("boom")
        return n

    def level2(n):
        return level3(n) + 1

    def level1(n):
        return level2(n) * 2

    for i in range(4000):
        try:
            level1(i)
        except ValueError:
            traceback.format_exc()


def w_pdb():
    import pdb

    src = "def f(x):\n    y = x + 1\n    z = y * 2\n    return z\n"
    code = compile(src, "<pdb>", "exec")
    ns = {}
    exec(code, ns)
    dbg = pdb.Pdb()
    dbg.reset()
    for _ in range(300):
        dbg.run("f(3)", ns, ns)


def w_profile():
    import cProfile
    import pstats
    import io

    def work(n):
        acc = 0
        for i in range(n):
            acc += (i * i) % 97
        return acc

    for _ in range(40):
        pr = cProfile.Profile()
        pr.enable()
        work(3000)
        pr.disable()
        st = pstats.Stats(pr, stream=io.StringIO())
        st.sort_stats("cumulative").print_stats(5)


def w_inspect():
    import inspect

    def inner():
        return inspect.currentframe()

    for _ in range(20_000):
        f = inner()
        inspect.getframeinfo(f)
        sys._getframe(0)


def w_logging():
    import logging
    import io

    buf = io.StringIO()
    log = logging.getLogger("pgo-train")
    log.setLevel(logging.DEBUG)
    h = logging.StreamHandler(buf)
    log.addHandler(h)
    try:
        for i in range(20_000):
            try:
                if i % 2:
                    raise RuntimeError("x")
            except RuntimeError:
                log.debug("caught", exc_info=True)
    finally:
        log.removeHandler(h)


def w_compile_dis():
    import dis

    src = "def g(a, b):\n    return [x * a for x in range(b) if x % 2]\n"
    for _ in range(2000):
        code = compile(src, "<dis>", "exec")
        dis.dis(code)


WORKLOADS = [
    ("trace_lines", w_trace),
    ("traceback_fmt", w_traceback),
    ("pdb_step", w_pdb),
    ("cprofile", w_profile),
    ("inspect_frame", w_inspect),
    ("logging_exc", w_logging),
    ("compile_dis", w_compile_dis),
]

if __name__ == "__main__":
    out = {}
    for name, fn in WORKLOADS:
        out[name] = round(timed(fn), 6)
    print(json.dumps(out))
