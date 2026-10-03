#!/bin/bash

set -u

# =========================================================
# Phase 5 Dynamic Traffic Suite — BASELINE
#
# No RC control.
# KPM monitoring only.
#
# Usage:
#   ./run_dynamic_baseline.sh 01
# =========================================================


RUN_ID="${1:-}"

if [ -z "$RUN_ID" ]; then
    echo "Usage: $0 RUN_ID"
    exit 1
fi


# =========================================================
# Configuration
# =========================================================

CONTAINER="python_xapp_runner"

BASE_DIR="$HOME/oran_experiments/dynamic_suite"

OUTPUT_DIR="$BASE_DIR/baseline/run_${RUN_ID}"

TRAFFIC_SCRIPT="$BASE_DIR/generate_traffic_suite.sh"

KPM_CONTAINER_LOG="/tmp/dynamic_baseline_${RUN_ID}.txt"

KPM_PID_FILE="/tmp/dynamic_baseline_${RUN_ID}.pid"


if [ -d "$OUTPUT_DIR" ]; then
    echo
    echo "ERROR:"
    echo "$OUTPUT_DIR already exists."
    echo
    echo "Delete it first only if you intentionally want to repeat this run."
    exit 1
fi


mkdir -p "$OUTPUT_DIR"


echo
echo "=================================================="
echo "PHASE 5 — DYNAMIC BASELINE"
echo "RUN: $RUN_ID"
echo "=================================================="
echo


# =========================================================
# 1. Check traffic generator
# =========================================================

echo "[1/9] Checking traffic generator..."

bash -n "$TRAFFIC_SCRIPT" || exit 1

echo "Traffic generator OK."


# =========================================================
# 2. Clean old KPM files
# =========================================================

echo
echo "[2/9] Cleaning temporary KPM files..."


sudo docker exec "$CONTAINER" sh -c "
rm -f '$KPM_CONTAINER_LOG'
rm -f '$KPM_PID_FILE'
"


# =========================================================
# 3. Start KPM xApp
# =========================================================

echo
echo "[3/9] Starting baseline KPM logger..."


sudo docker exec "$CONTAINER" sh -c "
python3 -u /opt/xApps/kpm_mon_xapp.py \
--e2_node_id gnbd_001_001_00019b_0 \
--ran_func_id 2 \
--kpm_report_style 1 \
--metrics DRB.UEThpUl,DRB.UEThpDl,RRU.PrbUsedUl,RRU.PrbUsedDl,RRU.PrbAvailUl,RRU.PrbAvailDl,CQI,RSRP \
> '$KPM_CONTAINER_LOG' 2>&1 &

echo \$! > '$KPM_PID_FILE'
"


sleep 5


KPM_PID=$(sudo docker exec "$CONTAINER" \
    sh -c "cat '$KPM_PID_FILE' 2>/dev/null")


if [ -z "$KPM_PID" ]; then
    echo "ERROR: Could not obtain KPM PID."
    exit 1
fi


if ! sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$KPM_PID' 2>/dev/null"
then
    echo
    echo "ERROR: KPM logger stopped."
    sudo docker exec "$CONTAINER" \
        cat "$KPM_CONTAINER_LOG"
    exit 1
fi


echo "KPM logger PID: $KPM_PID"


# =========================================================
# 4. Confirm KPM indications
# =========================================================

echo
echo "[4/9] Waiting for KPM indications..."


KPM_OK=0


for i in $(seq 1 15)
do

    COUNT=$(sudo docker exec "$CONTAINER" \
        sh -c "
        grep -c 'RIC Indication Received' \
        '$KPM_CONTAINER_LOG' 2>/dev/null || true
        " | tr -d '[:space:]')


    [ -z "$COUNT" ] && COUNT=0


    echo "KPM indication count: $COUNT"


    if [ "$COUNT" -gt 0 ]; then
        KPM_OK=1
        break
    fi


    sleep 2
done


if [ "$KPM_OK" -ne 1 ]; then

    echo
    echo "ERROR: No KPM indications received."

    sudo docker exec "$CONTAINER" \
        tail -100 "$KPM_CONTAINER_LOG"

    sudo docker exec "$CONTAINER" \
        sh -c "kill -INT '$KPM_PID' 2>/dev/null || true"

    exit 1
fi


echo "KPM reception confirmed."


# =========================================================
# 5. Start continuous ping
# =========================================================

echo
echo "[5/9] Starting UE ping logger..."


sudo ip netns exec ue1 \
    ping -i 0.1 10.45.0.1 \
    > "$OUTPUT_DIR/ping.txt" 2>&1 &


PING_PID=$!


sleep 2


# =========================================================
# 6. Run identical dynamic traffic suite
# =========================================================

echo
echo "[6/9] Starting dynamic traffic suite..."
echo


"$TRAFFIC_SCRIPT" "$OUTPUT_DIR"

TRAFFIC_STATUS=$?


if [ "$TRAFFIC_STATUS" -ne 0 ]; then

    echo
    echo "ERROR: Traffic suite failed."

    kill "$PING_PID" 2>/dev/null || true

    sudo docker exec "$CONTAINER" \
        sh -c "kill -INT '$KPM_PID' 2>/dev/null || true"

    sudo docker exec "$CONTAINER" \
        sh -c "cat '$KPM_CONTAINER_LOG'" \
        > "$OUTPUT_DIR/kpm.txt"

    exit 1
fi


# =========================================================
# 7. Post-traffic observation
# =========================================================

echo
echo "[7/9] Traffic complete."
echo "Collecting 15 seconds of post-traffic KPM data..."


sleep 15


# =========================================================
# 8. Stop monitoring
# =========================================================

echo
echo "[8/9] Stopping ping and KPM logger..."


kill "$PING_PID" 2>/dev/null || true

wait "$PING_PID" 2>/dev/null || true


sudo docker exec "$CONTAINER" \
    sh -c "kill -INT '$KPM_PID' 2>/dev/null || true"


sleep 2


if sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$KPM_PID' 2>/dev/null"
then

    sudo docker exec "$CONTAINER" \
        sh -c "kill -TERM '$KPM_PID' 2>/dev/null || true"

fi


sleep 2


sudo docker exec "$CONTAINER" \
    sh -c "cat '$KPM_CONTAINER_LOG'" \
    > "$OUTPUT_DIR/kpm.txt"


KPM_COUNT=$(grep -c \
    "RIC Indication Received" \
    "$OUTPUT_DIR/kpm.txt" \
    2>/dev/null || true)


echo "Total KPM indications captured: $KPM_COUNT"


if [ "$KPM_COUNT" -eq 0 ]; then
    echo "ERROR: No KPM data saved."
    exit 1
fi


# =========================================================
# 9. Parse KPM text + map dynamic traffic
# =========================================================

echo
echo "[9/9] Parsing dynamic baseline data..."


python3 - "$OUTPUT_DIR" <<'PY'

import csv
import re
import sys
import calendar

from datetime import datetime
from pathlib import Path


run_dir = Path(sys.argv[1])

kpm_text = run_dir / "kpm.txt"
schedule_file = run_dir / "offered_load.csv"

kpm_csv = run_dir / "kpm_timeseries.csv"
dynamic_csv = run_dir / "dynamic_timeseries.csv"
summary_csv = run_dir / "pattern_summary.csv"


# =========================================================
# Load traffic schedule
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
# Flexible KPM text parser
# =========================================================

text = kpm_text.read_text(
    errors="ignore"
)

lines = text.splitlines()

records = []

current = None


def extract_number(line, names):

    for name in names:

        pattern = (
            re.escape(name)
            + r"\s*[:=]\s*"
            + r"([-+]?[0-9]*\.?[0-9]+)"
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
    # New indication timestamp
    # -----------------------------------------------------

    if "RIC Indication Received" in line:

        if current is not None:
            records.append(current)

        current = {
            "timestamp": "",
            "ul_throughput_raw": "",
            "prb_used_ul": "",
            "prb_available_ul": "",
            "cqi": "",
            "rsrp": ""
        }


        m = re.search(
            r"(20\d\d-\d\d-\d\d[ T]\d\d:\d\d:\d\d)",
            line
        )

        if m:
            current["timestamp"] = (
                m.group(1).replace("T", " ")
            )

        continue


    if current is None:
        continue


    # Timestamp may appear on another line.
    if not current["timestamp"]:

        m = re.search(
            r"(20\d\d-\d\d-\d\d[ T]\d\d:\d\d:\d\d)",
            line
        )

        if m:
            current["timestamp"] = (
                m.group(1).replace("T", " ")
            )


    value = extract_number(
        line,
        [
            "DRB.UEThpUl",
            "UEThpUl"
        ]
    )

    if value is not None:
        current["ul_throughput_raw"] = value


    value = extract_number(
        line,
        [
            "RRU.PrbUsedUl",
            "PrbUsedUl"
        ]
    )

    if value is not None:
        current["prb_used_ul"] = value


    value = extract_number(
        line,
        [
            "RRU.PrbAvailUl",
            "PrbAvailUl"
        ]
    )

    if value is not None:
        current["prb_available_ul"] = value


    value = extract_number(
        line,
        ["CQI"]
    )

    if value is not None:
        current["cqi"] = value


    value = extract_number(
        line,
        ["RSRP"]
    )

    if value is not None:
        current["rsrp"] = value


if current is not None:
    records.append(current)


# Remove unusable entries
records = [
    r
    for r in records
    if r["timestamp"]
]


if not records:

    print()
    print("ERROR:")
    print("Could not parse KPM indications.")
    print()
    print("First 100 lines of KPM log:")
    print()

    for line in lines[:100]:
        print(line)

    sys.exit(1)


# =========================================================
# Save raw parsed KPM CSV
# =========================================================

fields = [
    "timestamp",
    "ul_throughput_raw",
    "prb_used_ul",
    "prb_available_ul",
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
        fieldnames=fields
    )

    writer.writeheader()
    writer.writerows(records)


# =========================================================
# Traffic mapping
# =========================================================

dynamic = []


for row in records:

    dt = datetime.strptime(
        row["timestamp"],
        "%Y-%m-%d %H:%M:%S"
    )

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
    fields
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
# Pattern summary
# =========================================================

patterns = [
    "constant",
    "step",
    "bursty",
    "random"
]


def numeric(rows, key):

    values = []

    for row in rows:

        try:
            values.append(
                float(row[key])
            )

        except:
            pass

    return values


def avg(values):

    if not values:
        return ""

    return sum(values) / len(values)


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
                numeric(
                    rows,
                    "offered_load_mbps"
                )
            ),

        "avg_kpm_throughput_raw":
            avg(
                numeric(
                    rows,
                    "ul_throughput_raw"
                )
            ),

        "avg_prb_used":
            avg(
                numeric(
                    rows,
                    "prb_used_ul"
                )
            ),

        "avg_prb_available":
            avg(
                numeric(
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


print()
print("Parsed KPM samples:", len(records))

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

with open(summary_csv) as f:
    print(f.read())

PY


STATUS=$?


if [ "$STATUS" -ne 0 ]; then

    echo
    echo "ERROR:"
    echo "Dynamic baseline parsing failed."

    exit 1
fi


echo
echo "=================================================="
echo "DYNAMIC BASELINE RUN $RUN_ID COMPLETE"
echo "=================================================="
echo


echo "Saved files:"

ls -lh "$OUTPUT_DIR"


echo
echo "Pattern summary:"

cat "$OUTPUT_DIR/pattern_summary.csv"


echo
echo "=================================================="
