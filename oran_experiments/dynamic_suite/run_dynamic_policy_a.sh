#!/bin/bash

set -u

# =========================================================
# Phase 5 Dynamic Traffic Suite — Policy A
#
# Usage:
#
#   ./run_dynamic_policy_a.sh 01
#
# Output:
#
#   ~/oran_experiments/dynamic_suite/policy_a/run_01/
#
# =========================================================


# ---------------------------------------------------------
# Input
# ---------------------------------------------------------

RUN_ID="${1:-}"

if [ -z "$RUN_ID" ]; then
    echo "Usage:"
    echo "$0 RUN_ID"
    echo
    echo "Example:"
    echo "$0 01"
    exit 1
fi


# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

CONTAINER="python_xapp_runner"

E2_NODE_ID="gnbd_001_001_00019b_0"

BASE_DIR="$HOME/oran_experiments/dynamic_suite"

OUTPUT_DIR="$BASE_DIR/policy_a/run_${RUN_ID}"

TRAFFIC_SCRIPT="$BASE_DIR/generate_traffic_suite.sh"

XAPP_SCRIPT="/opt/xApps/policy_a_xapp.py"

XAPP_LOG="/tmp/dynamic_policy_a_${RUN_ID}.txt"

PID_FILE="/tmp/dynamic_policy_a_${RUN_ID}.pid"

KPM_SOURCE="/tmp/policy_a_samples.csv"

ACTION_SOURCE="/tmp/policy_a_actions.csv"


# ---------------------------------------------------------
# Create output directory
# ---------------------------------------------------------

if [ -d "$OUTPUT_DIR" ]; then

    echo
    echo "ERROR:"
    echo "$OUTPUT_DIR already exists."
    echo
    echo "Delete it first if this run should be repeated:"
    echo
    echo "rm -rf $OUTPUT_DIR"
    echo

    exit 1
fi


mkdir -p "$OUTPUT_DIR"


echo
echo "=================================================="
echo "PHASE 5 — POLICY A DYNAMIC SUITE"
echo "RUN: $RUN_ID"
echo "=================================================="
echo


# ---------------------------------------------------------
# Check traffic generator
# ---------------------------------------------------------

echo "[1/9] Checking traffic generator..."

if [ ! -x "$TRAFFIC_SCRIPT" ]; then

    echo "ERROR:"
    echo "Traffic generator is not executable:"
    echo "$TRAFFIC_SCRIPT"

    exit 1
fi


bash -n "$TRAFFIC_SCRIPT"

if [ $? -ne 0 ]; then

    echo "ERROR:"
    echo "Traffic generator has a syntax error."

    exit 1
fi


echo "Traffic generator OK."


# ---------------------------------------------------------
# Remove old temporary Policy A logs
# ---------------------------------------------------------

echo
echo "[2/9] Cleaning old Policy A temporary files..."


sudo docker exec "$CONTAINER" sh -c "
rm -f '$XAPP_LOG'
rm -f '$PID_FILE'
rm -f '$KPM_SOURCE'
rm -f '$ACTION_SOURCE'
" 2>/dev/null


# ---------------------------------------------------------
# Start Policy A
# ---------------------------------------------------------

echo
echo "[3/9] Starting Policy A controller..."


sudo docker exec "$CONTAINER" sh -c "
python3 -u '$XAPP_SCRIPT' \
--e2_node_id '$E2_NODE_ID' \
--ue_id 0 \
--initial_prb 30 \
--throughput_target 5000 \
> '$XAPP_LOG' 2>&1 &

echo \$! > '$PID_FILE'
"


sleep 5


# ---------------------------------------------------------
# Verify controller process
# ---------------------------------------------------------

XAPP_PID=$(sudo docker exec "$CONTAINER" \
    sh -c "cat '$PID_FILE' 2>/dev/null" \
    2>/dev/null)


if [ -z "$XAPP_PID" ]; then

    echo
    echo "ERROR:"
    echo "Could not obtain Policy A PID."

    sudo docker exec "$CONTAINER" \
        cat "$XAPP_LOG"

    exit 1
fi


echo "Policy A PID: $XAPP_PID"


if ! sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$XAPP_PID' 2>/dev/null"
then

    echo
    echo "ERROR:"
    echo "Policy A controller exited immediately."
    echo
    echo "Controller log:"
    echo "------------------------------------------"

    sudo docker exec "$CONTAINER" \
        cat "$XAPP_LOG"

    exit 1
fi


echo "Policy A controller is running."


# ---------------------------------------------------------
# Wait for KPM indications
# ---------------------------------------------------------

echo
echo "[4/9] Waiting for KPM indications..."


KPM_OK=0


for i in $(seq 1 15)
do

    COUNT=$(sudo docker exec "$CONTAINER" \
        sh -c "
        grep -c 'RIC Indication' \
        '$XAPP_LOG' 2>/dev/null || true
        " \
        | tr -d '[:space:]')


    if [ -z "$COUNT" ]; then
        COUNT=0
    fi


    echo "KPM indication count: $COUNT"


    if [ "$COUNT" -gt 0 ]; then

        KPM_OK=1
        break

    fi


    sleep 2

done


if [ "$KPM_OK" -ne 1 ]; then

    echo
    echo "ERROR:"
    echo "Policy A did not receive KPM indications."
    echo
    echo "Controller log:"
    echo "------------------------------------------"

    sudo docker exec "$CONTAINER" \
        tail -100 "$XAPP_LOG"

    sudo docker exec "$CONTAINER" \
        sh -c "kill '$XAPP_PID' 2>/dev/null || true"

    exit 1
fi


echo
echo "KPM reception confirmed."


# ---------------------------------------------------------
# Start continuous ping
# ---------------------------------------------------------

echo
echo "[5/9] Starting UE ping logger..."


sudo ip netns exec ue1 \
    ping -i 0.1 10.45.0.1 \
    > "$OUTPUT_DIR/ping.txt" 2>&1 &


PING_PID=$!


echo "Ping PID: $PING_PID"


sleep 2


# ---------------------------------------------------------
# Run dynamic traffic suite
# ---------------------------------------------------------

echo
echo "[6/9] Starting dynamic traffic suite..."
echo


"$TRAFFIC_SCRIPT" "$OUTPUT_DIR"

TRAFFIC_STATUS=$?


if [ "$TRAFFIC_STATUS" -ne 0 ]; then

    echo
    echo "ERROR:"
    echo "Traffic suite failed."

    kill "$PING_PID" 2>/dev/null || true

    sudo docker exec "$CONTAINER" \
        sh -c "kill '$XAPP_PID' 2>/dev/null || true"

    sleep 2


    sudo docker cp \
        "$CONTAINER:$XAPP_LOG" \
        "$OUTPUT_DIR/controller.txt" \
        2>/dev/null || true


    sudo docker cp \
        "$CONTAINER:$KPM_SOURCE" \
        "$OUTPUT_DIR/kpm_timeseries.csv" \
        2>/dev/null || true


    sudo docker cp \
        "$CONTAINER:$ACTION_SOURCE" \
        "$OUTPUT_DIR/control_actions.csv" \
        2>/dev/null || true


    exit 1
fi


# ---------------------------------------------------------
# Post-traffic settling
# ---------------------------------------------------------

echo
echo "[7/9] Traffic complete."
echo "Observing controller for 15 seconds..."
echo


sleep 15


# ---------------------------------------------------------
# Stop logging/controller
# ---------------------------------------------------------

echo
echo "[8/9] Stopping ping and Policy A..."


kill "$PING_PID" 2>/dev/null || true

wait "$PING_PID" 2>/dev/null || true


sudo docker exec "$CONTAINER" \
    sh -c "kill '$XAPP_PID' 2>/dev/null || true"


sleep 3


# ---------------------------------------------------------
# Copy controller files
# ---------------------------------------------------------

echo
echo "Copying controller files..."


sudo docker cp \
    "$CONTAINER:$XAPP_LOG" \
    "$OUTPUT_DIR/controller.txt"


sudo docker cp \
    "$CONTAINER:$KPM_SOURCE" \
    "$OUTPUT_DIR/kpm_timeseries.csv"


sudo docker cp \
    "$CONTAINER:$ACTION_SOURCE" \
    "$OUTPUT_DIR/control_actions.csv"


sudo chown -R \
    "$USER:$USER" \
    "$OUTPUT_DIR" \
    2>/dev/null || true


# ---------------------------------------------------------
# Build dynamic_timeseries.csv + pattern_summary.csv
# ---------------------------------------------------------

echo
echo "[9/9] Building combined dynamic data..."


python3 - "$OUTPUT_DIR" <<'PY'

import csv
import sys
import calendar

from datetime import datetime
from pathlib import Path


run_dir = Path(sys.argv[1])

kpm_file = run_dir / "kpm_timeseries.csv"

schedule_file = run_dir / "offered_load.csv"

output_file = run_dir / "dynamic_timeseries.csv"

summary_file = run_dir / "pattern_summary.csv"


# =========================================================
# Read traffic schedule
# =========================================================

schedule = []

with open(schedule_file, newline="") as f:

    reader = csv.DictReader(f)

    for row in reader:

        schedule.append({
            "pattern":
                row["pattern"],

            "segment":
                row["segment"],

            "start":
                int(row["start_epoch"]),

            "end":
                int(row["end_epoch"]),

            "offered":
                float(row["offered_load_mbps"])
        })


# =========================================================
# Map an epoch to traffic state
# =========================================================

def map_traffic(epoch):

    for event in schedule:

        if (
            event["start"]
            <= epoch
            <= event["end"]
        ):

            return (
                event["pattern"],
                event["segment"],
                event["offered"]
            )


    return (
        "outside_suite",
        "outside_suite",
        0.0
    )


# =========================================================
# Read KPM data
# =========================================================

with open(kpm_file, newline="") as f:

    reader = csv.DictReader(f)

    kpm_rows = list(reader)


if not kpm_rows:

    print(
        "ERROR: kpm_timeseries.csv is empty."
    )

    sys.exit(1)


# =========================================================
# Discover column names
# =========================================================

columns = list(
    kpm_rows[0].keys()
)


def find_column(candidates):

    lower_map = {
        c.lower(): c
        for c in columns
    }


    for candidate in candidates:

        if candidate.lower() in lower_map:

            return lower_map[
                candidate.lower()
            ]


    for column in columns:

        lc = column.lower()

        for candidate in candidates:

            if candidate.lower() in lc:

                return column


    return None


timestamp_col = find_column([
    "timestamp"
])


throughput_col = find_column([
    "ul_throughput_raw",
    "throughput_ul_raw",
    "drb.uethpul",
    "ul_throughput"
])


prb_used_col = find_column([
    "prb_used_ul",
    "rru.prbusedul",
    "prbusedul"
])


quota_col = find_column([
    "prb_quota_percent",
    "current_prb_percent",
    "prb_percent"
])


if timestamp_col is None:

    print(
        "ERROR: Could not identify timestamp column."
    )

    print(
        "Columns:",
        columns
    )

    sys.exit(1)


print(
    "Detected columns:"
)

print(
    " timestamp:",
    timestamp_col
)

print(
    " throughput:",
    throughput_col
)

print(
    " PRB used:",
    prb_used_col
)

print(
    " quota:",
    quota_col
)


# =========================================================
# Build combined rows
# =========================================================

combined = []


for row in kpm_rows:

    timestamp = row[
        timestamp_col
    ]


    try:

        dt = datetime.strptime(
            timestamp,
            "%Y-%m-%d %H:%M:%S"
        )


        epoch = calendar.timegm(
            dt.timetuple()
        )


    except Exception:

        continue


    pattern, segment, offered = (
        map_traffic(epoch)
    )


    output_row = dict(row)

    output_row[
        "traffic_pattern"
    ] = pattern

    output_row[
        "traffic_segment"
    ] = segment

    output_row[
        "offered_load_mbps"
    ] = offered


    combined.append(
        output_row
    )


# =========================================================
# Write combined timeseries
# =========================================================

if combined:

    output_columns = list(
        combined[0].keys()
    )


    with open(
        output_file,
        "w",
        newline=""
    ) as f:

        writer = csv.DictWriter(
            f,
            fieldnames=output_columns
        )

        writer.writeheader()

        writer.writerows(
            combined
        )


# =========================================================
# Helper conversion
# =========================================================

def numeric(row, column):

    if column is None:

        return None


    try:

        return float(
            row[column]
        )

    except Exception:

        return None


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
        for r in combined
        if r[
            "traffic_pattern"
        ] == pattern
    ]


    offered_values = [
        float(
            r["offered_load_mbps"]
        )
        for r in rows
    ]


    throughput_values = [
        x
        for x in (
            numeric(
                r,
                throughput_col
            )
            for r in rows
        )
        if x is not None
    ]


    prb_used_values = [
        x
        for x in (
            numeric(
                r,
                prb_used_col
            )
            for r in rows
        )
        if x is not None
    ]


    quota_values = [
        x
        for x in (
            numeric(
                r,
                quota_col
            )
            for r in rows
        )
        if x is not None
    ]


    def average(values):

        if not values:

            return ""

        return (
            sum(values)
            /
            len(values)
        )


    summary_rows.append({
        "policy":
            "policy_a",

        "traffic_pattern":
            pattern,

        "num_kpm_samples":
            len(rows),

        "avg_offered_load_mbps":
            average(
                offered_values
            ),

        "avg_kpm_throughput_raw":
            average(
                throughput_values
            ),

        "avg_prb_used":
            average(
                prb_used_values
            ),

        "avg_prb_quota_percent":
            average(
                quota_values
            )
    })


with open(
    summary_file,
    "w",
    newline=""
) as f:

    fields = [
        "policy",
        "traffic_pattern",
        "num_kpm_samples",
        "avg_offered_load_mbps",
        "avg_kpm_throughput_raw",
        "avg_prb_used",
        "avg_prb_quota_percent"
    ]


    writer = csv.DictWriter(
        f,
        fieldnames=fields
    )


    writer.writeheader()

    writer.writerows(
        summary_rows
    )


print()
print(
    "Combined rows:",
    len(combined)
)

print(
    "Created:",
    output_file
)

print(
    "Created:",
    summary_file
)

PY


PYTHON_STATUS=$?


if [ "$PYTHON_STATUS" -ne 0 ]; then

    echo
    echo "WARNING:"
    echo "Traffic completed, but combined-data generation failed."

fi


# ---------------------------------------------------------
# Final output
# ---------------------------------------------------------

echo
echo "=================================================="
echo "POLICY A DYNAMIC RUN $RUN_ID COMPLETE"
echo "=================================================="
echo


echo "Saved files:"

ls -lh "$OUTPUT_DIR"


echo
echo "Pattern summary:"

cat "$OUTPUT_DIR/pattern_summary.csv"


echo
echo "Control actions:"

cat "$OUTPUT_DIR/control_actions.csv"


echo
echo "=================================================="
