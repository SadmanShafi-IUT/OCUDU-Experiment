#!/usr/bin/env python3

import csv
import re
import sys
import calendar
from datetime import datetime
from pathlib import Path


if len(sys.argv) != 2:
    print("Usage:")
    print("python3 parse_dynamic_baseline.py RUN_DIRECTORY")
    sys.exit(1)


run_dir = Path(sys.argv[1])

kpm_text = run_dir / "kpm.txt"
schedule_file = run_dir / "offered_load.csv"

kpm_csv = run_dir / "kpm_timeseries.csv"
dynamic_csv = run_dir / "dynamic_timeseries.csv"
summary_csv = run_dir / "pattern_summary.csv"


# =========================================================
# Check files
# =========================================================

if not kpm_text.exists():
    print("ERROR: Missing:", kpm_text)
    sys.exit(1)

if not schedule_file.exists():
    print("ERROR: Missing:", schedule_file)
    sys.exit(1)


# =========================================================
# Load offered-load schedule
# =========================================================

schedule = []

with open(schedule_file, newline="") as f:

    for row in csv.DictReader(f):

        schedule.append({
            "pattern": row["pattern"],
            "segment": row["segment"],
            "start": int(row["start_epoch"]),
            "end": int(row["end_epoch"]),
            "offered": float(row["offered_load_mbps"])
        })


def map_traffic(epoch):

    for e in schedule:

        if e["start"] <= epoch <= e["end"]:

            return (
                e["pattern"],
                e["segment"],
                e["offered"]
            )

    return (
        "outside_suite",
        "outside_suite",
        0.0
    )


# =========================================================
# Parse KPM text
# =========================================================

text = kpm_text.read_text(errors="ignore")
lines = text.splitlines()

records = []
current = None


def metric_value(line, metric_name):

    pattern = (
        r"--Metric:\s*"
        + re.escape(metric_name)
        + r"\s*,\s*Value:\s*"
        + r"\[\s*([-+]?[0-9]*\.?[0-9]+)\s*\]"
    )

    m = re.search(
        pattern,
        line,
        re.IGNORECASE
    )

    if m:
        return float(m.group(1))

    return None


for line in lines:

    # -----------------------------------------------------
    # Start of new indication
    # -----------------------------------------------------

    if "RIC Indication Received" in line:

        if current is not None:
            records.append(current)

        current = {
            "timestamp": "",
            "ul_throughput_raw": "",
            "dl_throughput_raw": "",
            "prb_used_ul": "",
            "prb_used_dl": "",
            "prb_available_ul": "",
            "prb_available_dl": "",
            "cqi": "",
            "rsrp": ""
        }

        continue


    if current is None:
        continue


    # -----------------------------------------------------
    # Timestamp
    # -----------------------------------------------------

    if "ColletStartTime" in line:

        m = re.search(
            r"(20\d\d-\d\d-\d\d\s+\d\d:\d\d:\d\d)",
            line
        )

        if m:
            current["timestamp"] = m.group(1)


    # -----------------------------------------------------
    # Metrics
    # -----------------------------------------------------

    v = metric_value(
        line,
        "DRB.UEThpUl"
    )

    if v is not None:
        current["ul_throughput_raw"] = v


    v = metric_value(
        line,
        "DRB.UEThpDl"
    )

    if v is not None:
        current["dl_throughput_raw"] = v


    v = metric_value(
        line,
        "RRU.PrbUsedUl"
    )

    if v is not None:
        current["prb_used_ul"] = v


    v = metric_value(
        line,
        "RRU.PrbUsedDl"
    )

    if v is not None:
        current["prb_used_dl"] = v


    v = metric_value(
        line,
        "RRU.PrbAvailUl"
    )

    if v is not None:
        current["prb_available_ul"] = v


    v = metric_value(
        line,
        "RRU.PrbAvailDl"
    )

    if v is not None:
        current["prb_available_dl"] = v


    v = metric_value(
        line,
        "CQI"
    )

    if v is not None:
        current["cqi"] = v


    v = metric_value(
        line,
        "RSRP"
    )

    if v is not None:
        current["rsrp"] = v


# Add final indication
if current is not None:
    records.append(current)


# Remove incomplete timestamp records
records = [
    r
    for r in records
    if r["timestamp"]
]


if not records:

    print("ERROR:")
    print("No KPM records could be parsed.")
    sys.exit(1)


# =========================================================
# Write parsed KPM CSV
# =========================================================

kpm_fields = [
    "timestamp",
    "ul_throughput_raw",
    "dl_throughput_raw",
    "prb_used_ul",
    "prb_used_dl",
    "prb_available_ul",
    "prb_available_dl",
    "cqi",
    "rsrp"
]


with open(
    kpm_csv,
    "w",
    newline=""
) as f:

    writer = csv.DictWriter(
        f,
        fieldnames=kpm_fields
    )

    writer.writeheader()
    writer.writerows(records)


# =========================================================
# Map each KPM sample to traffic pattern
# =========================================================

dynamic = []


for row in records:

    dt = datetime.strptime(
        row["timestamp"],
        "%Y-%m-%d %H:%M:%S"
    )

    # KPM timestamps are treated as UTC,
    # same method used for Policy A / BC-LA.
    epoch = calendar.timegm(
        dt.timetuple()
    )

    pattern, segment, offered = (
        map_traffic(epoch)
    )

    r = dict(row)

    r["traffic_pattern"] = pattern
    r["traffic_segment"] = segment
    r["offered_load_mbps"] = offered

    dynamic.append(r)


dynamic_fields = (
    kpm_fields
    + [
        "traffic_pattern",
        "traffic_segment",
        "offered_load_mbps"
    ]
)


with open(
    dynamic_csv,
    "w",
    newline=""
) as f:

    writer = csv.DictWriter(
        f,
        fieldnames=dynamic_fields
    )

    writer.writeheader()
    writer.writerows(dynamic)


# =========================================================
# Helpers
# =========================================================

def values(rows, key):

    output = []

    for row in rows:

        try:
            output.append(
                float(row[key])
            )

        except:
            pass

    return output


def avg(x):

    if not x:
        return ""

    return sum(x) / len(x)


# =========================================================
# Pattern summary
# =========================================================

patterns = [
    "constant",
    "step",
    "bursty",
    "random"
]


summary_rows = []


for pattern in patterns:

    rows = [
        r
        for r in dynamic
        if r["traffic_pattern"] == pattern
    ]

    summary_rows.append({

        "policy":
            "baseline",

        "traffic_pattern":
            pattern,

        "num_kpm_samples":
            len(rows),

        "avg_offered_load_mbps":
            avg(
                values(
                    rows,
                    "offered_load_mbps"
                )
            ),

        "avg_kpm_throughput_raw":
            avg(
                values(
                    rows,
                    "ul_throughput_raw"
                )
            ),

        "avg_prb_used":
            avg(
                values(
                    rows,
                    "prb_used_ul"
                )
            ),

        "avg_prb_available":
            avg(
                values(
                    rows,
                    "prb_available_ul"
                )
            )
    })


summary_fields = [
    "policy",
    "traffic_pattern",
    "num_kpm_samples",
    "avg_offered_load_mbps",
    "avg_kpm_throughput_raw",
    "avg_prb_used",
    "avg_prb_available"
]


with open(
    summary_csv,
    "w",
    newline=""
) as f:

    writer = csv.DictWriter(
        f,
        fieldnames=summary_fields
    )

    writer.writeheader()
    writer.writerows(summary_rows)


# =========================================================
# Display validation
# =========================================================

print()
print("==========================================")
print("BASELINE PARSING COMPLETE")
print("==========================================")

print()
print("Total parsed KPM samples:", len(records))

print()
print("Traffic pattern counts:")


for pattern in [
    "constant",
    "step",
    "bursty",
    "random",
    "idle",
    "outside_suite"
]:

    count = sum(
        r["traffic_pattern"] == pattern
        for r in dynamic
    )

    print(
        f"{pattern:15s} {count}"
    )


print()
print("Pattern summary:")
print()

with open(summary_csv) as f:
    print(f.read())
