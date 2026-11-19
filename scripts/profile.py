#!/usr/bin/env python3
"""Sample the running GUI process only; no container workload or engine totals."""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("--samples", type=int, default=20)
args = parser.parse_args()
samples = []
for _ in range(args.samples):
    output = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "rss=,%cpu="], text=True).split()
    if len(output) != 2:
        raise SystemExit("Process is no longer running")
    samples.append({"rss_mib": round(int(output[0]) / 1024, 2), "cpu_percent": float(output[1])})
    time.sleep(1)
print(json.dumps({
    "pid": args.pid, "samples": len(samples), "interval_seconds": 1,
    "rss_mib_min": min(x["rss_mib"] for x in samples),
    "rss_mib_max": max(x["rss_mib"] for x in samples),
    "cpu_percent_mean": round(sum(x["cpu_percent"] for x in samples) / len(samples), 2),
    "scope": "GUI process RSS and ps CPU estimates; excludes engine and VMs. Not physical footprint, a startup benchmark, or a Docker comparison.",
    "raw": samples,
}, indent=2))
