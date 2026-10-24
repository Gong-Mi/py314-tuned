"""A/B driver for the debug workloads (bench_debug.py). Same rotation/min
methodology as ab_driver.py."""
import json
import os
import statistics
import subprocess
import sys
import time

BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_debug.py")


def env_for(exe):
    env = dict(os.environ)
    if "py314" in exe:
        env["LD_LIBRARY_PATH"] = os.path.dirname(os.path.dirname(exe)) + "/lib"
    return env


def run_bench(exe):
    p = subprocess.run([exe, BENCH], capture_output=True, text=True, timeout=900,
                       env=env_for(exe))
    if p.returncode != 0:
        sys.exit(f"{exe} failed:\n{p.stderr[-2000:]}")
    return json.loads(p.stdout.strip().splitlines()[-1])


def main():
    la, ea, lb, eb = sys.argv[1:5]
    rounds = int(sys.argv[5]) if len(sys.argv) > 5 else 5
    runs = {la: [], lb: []}
    for r in range(rounds):
        order = [(la, ea), (lb, eb)] if r % 2 == 0 else [(lb, eb), (la, ea)]
        for label, exe in order:
            runs[label].append(run_bench(exe))
    print(f"{'workload':<16}{la:>10}{lb:>10}{'B/A min':>10}{'B/A med':>10}")
    for k in runs[la][0]:
        a = [r[k] for r in runs[la]]
        b = [r[k] for r in runs[lb]]
        print(f"{k:<16}{min(a):>10.4f}{min(b):>10.4f}"
              f"{min(b)/min(a):>10.3f}{statistics.median(b)/statistics.median(a):>10.3f}")


if __name__ == "__main__":
    main()
