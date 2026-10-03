#!/usr/bin/env python3

import csv
import sys
import calendar

from datetime import datetime
from pathlib import Path


if len(sys.argv) != 2:
    print(
        "Usage: python3 analyze_dynamic_run.py RUN_DIRECTORY"
    )
    sys.exit(1)


run_dir = Path(sys.argv[1])

schedule_file = run_dir / "offered_load.csv"
action_file = run_dir / "control_actions.csv"
timeseries_file = run_dir / "dynamic_timeseries.csv"


# =========================================================
# Read offered-load schedule
# =========================================================

with open(schedule_file, newline="") as f:
    schedule = list(csv.DictReader(f))


for row in schedule:

    row["start_epoch"] = int(
        row["start_epoch"]
    )

    row["end_epoch"] = int(
        row["end_epoch"]
    )

    row["offered_load_mbps"] = float(
        row["offered_load_mbps"]
    )


# =========================================================
# Helper: find pattern by epoch
# =========================================================

def find_pattern(epoch):

    for row in schedule:

        if (
            row["start_epoch"]
            <= epoch
            <= row["end_epoch"]
        ):

            return (
                row["pattern"],
                row["segment"],
                row["offered_load_mbps"]
            )

    return (
        "outside_suite",
        "outside_suite",
        0.0
    )


# =========================================================
# Read control actions
# =========================================================

with open(action_file, newline="") as f:
    actions = list(csv.DictReader(f))


mapped_actions = []


for row in actions:

    try:

        dt = datetime.strptime(
            row["timestamp"],
            "%Y-%m-%d %H:%M:%S"
        )

        epoch = calendar.timegm(
            dt.timetuple()
        )

    except Exception:
        continue


    pattern, segment, offered = (
        find_pattern(epoch)
    )


    old_prb = float(
        row["old_prb_percent"]
    )

    new_prb = float(
        row["new_prb_percent"]
    )


    if new_prb > old_prb:
        direction = "UP"

    elif new_prb < old_prb:
        direction = "DOWN"

    else:
        direction = "HOLD"


    new_row = dict(row)

    new_row["traffic_pattern"] = pattern
    new_row["traffic_segment"] = segment
    new_row["offered_load_mbps"] = offered
    new_row["direction"] = direction

    mapped_actions.append(
        new_row
    )


# =========================================================
# Save mapped actions
# =========================================================

mapped_file = (
    run_dir /
    "control_actions_mapped.csv"
)


if mapped_actions:

    fields = list(
        mapped_actions[0].keys()
    )

    with open(
        mapped_file,
        "w",
        newline=""
    ) as f:

        writer = csv.DictWriter(
            f,
            fieldnames=fields
        )

        writer.writeheader()
        writer.writerows(
            mapped_actions
        )


# =========================================================
# Read time-series
# =========================================================

with open(
    timeseries_file,
    newline=""
) as f:

    rows = list(
        csv.DictReader(f)
    )


patterns = [
    "constant",
    "step",
    "bursty",
    "random"
]


# =========================================================
# Build enhanced summary
# =========================================================

summary_file = (
    run_dir /
    "enhanced_pattern_summary.csv"
)


with open(
    summary_file,
    "w",
    newline=""
) as f:

    writer = csv.writer(f)

    writer.writerow([
        "traffic_pattern",
        "num_kpm_samples",
        "avg_offered_load_mbps",
        "avg_kpm_throughput_raw",
        "avg_prb_used",
        "avg_prb_quota_percent",
        "control_actions",
        "up_actions",
        "down_actions",
        "min_prb_quota",
        "max_prb_quota"
    ])


    for pattern in patterns:

        pattern_rows = [
            r
            for r in rows
            if r["traffic_pattern"]
            == pattern
        ]


        pattern_actions = [
            r
            for r in mapped_actions
            if r["traffic_pattern"]
            == pattern
        ]


        offered = []
        throughput = []
        prb_used = []
        quota = []


        for r in pattern_rows:

            try:
                offered.append(
                    float(
                        r[
                            "offered_load_mbps"
                        ]
                    )
                )
            except:
                pass

            try:
                throughput.append(
                    float(
                        r[
                            "ul_throughput_raw"
                        ]
                    )
                )
            except:
                pass

            try:
                prb_used.append(
                    float(
                        r[
                            "prb_used_ul"
                        ]
                    )
                )
            except:
                pass

            try:
                if "prb_quota_percent" in r and r["prb_quota_percent"]:
                    quota.append(
                        float(r["prb_quota_percent"])
                    )
                elif "current_prb_percent" in r and r["current_prb_percent"]:
                    quota.append(
                        float(r["current_prb_percent"])
                    )
            except:
                pass


        def avg(values):

            if not values:
                return None

            return (
                sum(values) /
                len(values)
            )


        up_actions = sum(
            r["direction"] == "UP"
            for r in pattern_actions
        )

        down_actions = sum(
            r["direction"] == "DOWN"
            for r in pattern_actions
        )


        writer.writerow([
            pattern,
            len(pattern_rows),
            avg(offered),
            avg(throughput),
            avg(prb_used),
            avg(quota),
            len(pattern_actions),
            up_actions,
            down_actions,
            min(quota) if quota else None,
            max(quota) if quota else None
        ])


print()
print(
    "Enhanced summary created:"
)

print(
    summary_file
)

print()

with open(summary_file) as f:
    print(
        f.read()
    )
