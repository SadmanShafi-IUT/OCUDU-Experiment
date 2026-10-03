#!/bin/bash

RUN_ID=$1

if [ -z "$RUN_ID" ]; then
    echo "Usage:"
    echo "./run_dynamic_bc_la.sh RUN_ID"
    echo
    echo "Example:"
    echo "./run_dynamic_bc_la.sh 01"
    exit 1
fi


# =========================================================
# Configuration
# =========================================================

CONTAINER="python_xapp_runner"

BASE_DIR="$HOME/oran_experiments/dynamic_suite"
RUN_DIR="$BASE_DIR/policy_bc_la/run_${RUN_ID}"

TRAFFIC_SCRIPT="$BASE_DIR/generate_traffic_suite.sh"

XAPP_LOG="/tmp/dynamic_bc_la_${RUN_ID}.txt"
PID_FILE="/tmp/dynamic_bc_la_${RUN_ID}.pid"

SAMPLE_LOG="/tmp/policy_bc_la_samples.csv"
ACTION_LOG="/tmp/policy_bc_la_actions.csv"

mkdir -p "$RUN_DIR"


echo
echo "=================================================="
echo "DYNAMIC TRAFFIC EXPERIMENT"
echo "Policy: B+C+Load-Aware"
echo "Run   : $RUN_ID"
echo "=================================================="
echo


# =========================================================
# 1. Check traffic script
# =========================================================

echo "[1/9] Checking traffic generator..."

if [ ! -x "$TRAFFIC_SCRIPT" ]; then

    echo "ERROR:"
    echo "$TRAFFIC_SCRIPT"
    echo "does not exist or is not executable."

    exit 1
fi


# =========================================================
# 2. Clean old controller files
# =========================================================

echo
echo "[2/9] Cleaning old controller files..."

sudo docker exec "$CONTAINER" sh -c "
rm -f \
'$XAPP_LOG' \
'$PID_FILE' \
'$SAMPLE_LOG' \
'$ACTION_LOG'
"


# =========================================================
# 3. Start Policy B+C+Load-Aware
# =========================================================

echo
echo "[3/9] Starting Policy B+C+Load-Aware controller..."

sudo docker exec "$CONTAINER" sh -c "
python3 -u /opt/xApps/policy_bc_la_xapp.py \
--e2_node_id gnbd_001_001_00019b_0 \
--kpm_ran_func_id 2 \
--rc_ran_func_id 3 \
--ue_id 0 \
--initial_prb 30 \
--throughput_target 5000 \
--high_util 0.85 \
--low_util 0.45 \
--window_size 5 \
--up_required 3 \
--down_required 5 \
--cooldown 5 \
> '$XAPP_LOG' 2>&1 &

echo \$! > '$PID_FILE'
"


sleep 5


XAPP_PID=$(sudo docker exec "$CONTAINER" \
    sh -c "cat '$PID_FILE' 2>/dev/null")


if [ -z "$XAPP_PID" ]; then

    echo "ERROR: Could not obtain controller PID."
    exit 1

fi


if ! sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$XAPP_PID' 2>/dev/null"
then

    echo "ERROR: Controller stopped immediately."

    sudo docker exec "$CONTAINER" \
        sh -c "cat '$XAPP_LOG'"

    exit 1
fi


echo "Controller PID: $XAPP_PID"


# =========================================================
# 4. Verify KPM reception
# =========================================================

echo
echo "[4/9] Waiting for KPM indications..."

sleep 6


KPM_COUNT=$(sudo docker exec "$CONTAINER" \
    sh -c "grep -c 'RIC Indication Received' '$XAPP_LOG' 2>/dev/null || true")


echo "Initial KPM indications: $KPM_COUNT"


if [ "$KPM_COUNT" -lt 1 ]; then

    echo "ERROR: No KPM indications received."

    sudo docker exec "$CONTAINER" \
        sh -c "cat '$XAPP_LOG'"

    exit 1
fi


# =========================================================
# 5. Start continuous ping
#
# Traffic suite lasts around 480 seconds.
# Use ~520 seconds of ping.
# =========================================================

echo
echo "[5/9] Starting continuous ping..."

sudo ip netns exec ue1 ping \
-c 5200 \
-i 0.1 \
10.45.0.1 \
> "$RUN_DIR/ping.txt" 2>&1 &

PING_PID=$!


# =========================================================
# 6. Run complete traffic suite
# =========================================================

echo
echo "[6/9] Starting full traffic suite..."

"$TRAFFIC_SCRIPT" "$RUN_DIR"

TRAFFIC_STATUS=$?


if [ "$TRAFFIC_STATUS" -ne 0 ]; then

    echo
    echo "ERROR: Traffic suite failed."

    kill "$PING_PID" 2>/dev/null || true

    sudo docker exec "$CONTAINER" \
        sh -c "kill -INT '$XAPP_PID' 2>/dev/null || true"

    exit 1
fi


echo
echo "Traffic suite finished successfully."


# =========================================================
# Give controller time to react after final traffic ends
#
# This is useful because we WANT to observe:
#
# 70 -> 50 -> 30
#
# after traffic disappears.
# =========================================================

echo
echo "Allowing 15-second post-traffic settling period..."

sleep 15


# =========================================================
# Stop ping
# =========================================================

echo
echo "[7/9] Stopping ping..."

kill "$PING_PID" 2>/dev/null || true

wait "$PING_PID" 2>/dev/null || true


# =========================================================
# 8. Stop controller
# =========================================================

echo
echo "[8/9] Stopping controller..."

sudo docker exec "$CONTAINER" \
    sh -c "kill -INT '$XAPP_PID' 2>/dev/null || true"

sleep 3


# =========================================================
# Copy controller files
# =========================================================

echo
echo "Saving controller logs..."


sudo docker exec "$CONTAINER" \
    sh -c "cat '$XAPP_LOG'" \
    > "$RUN_DIR/controller.txt"


sudo docker exec "$CONTAINER" \
    sh -c "cat '$SAMPLE_LOG'" \
    > "$RUN_DIR/kpm_timeseries.csv"


sudo docker exec "$CONTAINER" \
    sh -c "cat '$ACTION_LOG'" \
    > "$RUN_DIR/control_actions.csv"


# =========================================================
# 9. Create combined dynamic CSV
#
# IMPORTANT:
#
# offered_load.csv stores UNIX epoch timestamps.
#
# KPM timestamp is UTC, so Python explicitly interprets
# the KPM timestamp as UTC before matching it to traffic.
#
# =========================================================

echo
echo "[9/9] Building combined dynamic dataset..."

python3 - "$RUN_DIR" <<'PY'

import csv
import sys
import calendar
from datetime import datetime
from pathlib import Path


run_dir = Path(sys.argv[1])


# =========================================================
# Read offered-load schedule
# =========================================================

schedule_file = (
    run_dir /
    "offered_load.csv"
)

with open(
    schedule_file,
    newline=""
) as f:

    schedule = list(
        csv.DictReader(f)
    )


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
# Read KPM samples
# =========================================================

kpm_file = (
    run_dir /
    "kpm_timeseries.csv"
)

with open(
    kpm_file,
    newline=""
) as f:

    samples = list(
        csv.DictReader(f)
    )


# =========================================================
# Find traffic segment for each KPM sample
# =========================================================

def find_segment(epoch):

    for row in schedule:

        if (
            row["start_epoch"]
            <= epoch
            <= row["end_epoch"]
        ):

            return row

    return None


combined_rows = []


for sample in samples:

    timestamp_text = (
        sample["timestamp"]
    )

    try:

        # KPM timestamp is treated as UTC.
        dt = datetime.strptime(
            timestamp_text,
            "%Y-%m-%d %H:%M:%S"
        )

        epoch = calendar.timegm(
            dt.timetuple()
        )

    except Exception:

        continue


    segment = find_segment(epoch)


    if segment is None:

        pattern = "outside_suite"
        segment_name = "outside_suite"
        offered_load = 0.0

    else:

        pattern = segment["pattern"]

        segment_name = (
            segment["segment"]
        )

        offered_load = (
            segment[
                "offered_load_mbps"
            ]
        )


    combined_rows.append({

        "timestamp":
            timestamp_text,

        "epoch":
            epoch,

        "traffic_pattern":
            pattern,

        "traffic_segment":
            segment_name,

        "offered_load_mbps":
            offered_load,

        "ul_throughput_raw":
            sample[
                "ul_throughput_raw"
            ],

        "dl_throughput_raw":
            sample[
                "dl_throughput_raw"
            ],

        "prb_used_ul":
            sample[
                "prb_used_ul"
            ],

        "prb_available_ul":
            sample[
                "prb_available_ul"
            ],

        "cqi":
            sample["cqi"],

        "rsrp":
            sample["rsrp"],

        "prb_quota_percent":
            sample[
                "current_prb_percent"
            ]
    })


# =========================================================
# Save combined CSV
# =========================================================

combined_file = (
    run_dir /
    "dynamic_timeseries.csv"
)


fieldnames = [

    "timestamp",
    "epoch",

    "traffic_pattern",
    "traffic_segment",

    "offered_load_mbps",

    "ul_throughput_raw",
    "dl_throughput_raw",

    "prb_used_ul",
    "prb_available_ul",

    "cqi",
    "rsrp",

    "prb_quota_percent"
]


with open(
    combined_file,
    "w",
    newline=""
) as f:

    writer = csv.DictWriter(
        f,
        fieldnames=fieldnames
    )

    writer.writeheader()

    writer.writerows(
        combined_rows
    )


# =========================================================
# Simple pattern summary
# =========================================================

patterns = [
    "constant",
    "step",
    "bursty",
    "random"
]


summary_file = (
    run_dir /
    "pattern_summary.csv"
)


with open(
    summary_file,
    "w",
    newline=""
) as f:

    writer = csv.writer(f)

    writer.writerow([
        "policy",
        "traffic_pattern",
        "num_kpm_samples",
        "avg_offered_load_mbps",
        "avg_kpm_throughput_raw",
        "avg_prb_used",
        "avg_prb_quota_percent"
    ])


    for pattern in patterns:

        rows = [
            r
            for r in combined_rows
            if r["traffic_pattern"]
            == pattern
        ]


        if not rows:
            continue


        offered = []
        throughput = []
        used = []
        quota = []


        for r in rows:

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
                used.append(
                    float(
                        r[
                            "prb_used_ul"
                        ]
                    )
                )
            except:
                pass

            try:
                quota.append(
                    float(
                        r[
                            "prb_quota_percent"
                        ]
                    )
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


        writer.writerow([

            "policy_bc_la",
            pattern,
            len(rows),

            avg(offered),
            avg(throughput),
            avg(used),
            avg(quota)

        ])


print()
print(
    "Combined samples:",
    len(combined_rows)
)

print()
print(
    "Traffic-pattern sample counts:"
)

for pattern in [
    "constant",
    "step",
    "bursty",
    "random",
    "idle",
    "outside_suite"
]:

    count = sum(
        1
        for r in combined_rows
        if r["traffic_pattern"]
        == pattern
    )

    print(
        f"{pattern}: {count}"
    )

PY


# =========================================================
# Final result
# =========================================================

echo
echo "=================================================="
echo "DYNAMIC BC-LA RUN $RUN_ID COMPLETE"
echo "=================================================="

echo
echo "Saved files:"
ls -lh "$RUN_DIR"

echo
echo "Pattern summary:"
cat "$RUN_DIR/pattern_summary.csv"

echo
echo "Control actions:"
cat "$RUN_DIR/control_actions.csv"

echo
echo "=================================================="
