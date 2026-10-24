"""Alternate A/B benchmark driver for two CPython builds.

Rotates A,B / B,A per round so frequency/thermal drift doesn't favour one build.
Reports min and median across rounds plus the spread, and writes the raw rounds
to JSON so the noise floor is inspectable.

Usage: python3 driver.py <labelA> <exeA> <labelB> <exeB> [rounds]
"""
import json
import os
import statistics
import subprocess
import sys
import time

BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_interp.py")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ab_rounds.json")


def env_for(exe):
    env = dict(os.environ)
    if "py314" in exe:  # staged build: force its own libpython
        stage_lib = os.path.dirname(os.path.dirname(exe)) + "/lib"
        env["LD_LIBRARY_PATH"] = stage_lib
    return env


def run_bench(exe):
    p = subprocess.run([exe, BENCH], capture_output=True, text=True, timeout=900,
                       env=env_for(exe))
    if p.returncode != 0:
        sys.exit(f"{exe} bench failed:\n{p.stderr[-2000:]}")
    return json.loads(p.stdout.strip().splitlines()[-1])["times"]


def time_cmd(exe, args, n):
    ts = []
    for _ in range(n):
        t0 = time.perf_counter()
        r = subprocess.run([exe] + args, capture_output=True, env=env_for(exe))
        ts.append(time.perf_counter() - t0)
        if r.returncode != 0:
            sys.exit(f"{exe}: {r.stderr.decode()[:400]}")
    return min(ts), statistics.median(ts)


def main():
    la, ea, lb, eb = sys.argv[1:5]
    rounds = int(sys.argv[5]) if len(sys.argv) > 5 else 5
    interp = [(la, ea), (lb, eb)]

    runs = {la: [], lb: []}
    for r in range(rounds):
        order = interp if r % 2 == 0 else interp[::-1]
        for label, exe in order:
            runs[label].append(run_bench(exe))
        print(f"[round {r+1}/{rounds}] " + " ".join(
            f"{k}={v:.3f}" for k, v in runs[la][-1].items()), flush=True)

    startup = {la: time_cmd(ea, ["-c", "pass"], 30), lb: time_cmd(eb, ["-c", "pass"], 30)}
    imports = {la: time_cmd(ea, ["-c", "import json,ssl,sqlite3,decimal,email"], 20),
               lb: time_cmd(eb, ["-c", "import json,ssl,sqlite3,decimal,email"], 20)}
    # -S isolates the interpreter itself: stock has a huge site-packages tree,
    # the staged builds have an empty one, so plain startup is not comparable.
    startup_s = {la: time_cmd(ea, ["-S", "-c", "pass"], 30), lb: time_cmd(eb, ["-S", "-c", "pass"], 30)}
    imports_s = {la: time_cmd(ea, ["-S", "-c", "import json,ssl,sqlite3,decimal,email"], 20),
                 lb: time_cmd(eb, ["-S", "-c", "import json,ssl,sqlite3,decimal,email"], 20)}

    print()
    hdr = f"{'workload':<12}{la:>10}{lb:>10}{'B/A min':>10}{'B/A med':>10}{'B/A max':>10}"
    print(hdr)
    for k in runs[la][0]:
        a = [r[k] for r in runs[la]]
        b = [r[k] for r in runs[lb]]
        print(f"{k:<12}{min(a):>10.4f}{min(b):>10.4f}"
              f"{min(b)/min(a):>10.3f}{statistics.median(b)/statistics.median(a):>10.3f}"
              f"{max(b)/max(a):>10.3f}")
    for name, d in (("startup", startup), ("import", imports),
                    ("startupS", startup_s), ("importS", imports_s)):
        a, b = d[la], d[lb]
        print(f"{name+'_min':<12}{a[0]:>10.4f}{b[0]:>10.4f}{b[0]/a[0]:>10.3f}"
              f"{b[1]/a[1]:>10.3f}{'-':>10}")
        print(f"{name+'_med':<12}{a[1]:>10.4f}{b[1]:>10.4f}{'-':>10}{b[1]/a[1]:>10.3f}{'-':>10}")
    json.dump({"labels": [la, lb], "runs": runs,
               "startup": startup, "imports": imports}, open(OUT, "w"), indent=1)
    print(f"\nraw rounds -> {OUT}\nB/A < 1.0 means B is faster.")


if __name__ == "__main__":
    main()