#!/bin/bash

RUN_ID=$1

if [ -z "$RUN_ID" ]; then
    echo "Usage: ./run_policy_bc_la.sh RUN_ID"
    echo "Example: ./run_policy_bc_la.sh 01"
    exit 1
fi

CONTAINER="python_xapp_runner"

RUN_DIR="$HOME/oran_experiments/policy_bc_la/run_${RUN_ID}"

XAPP_LOG="/tmp/policy_bc_la_run_${RUN_ID}.txt"
PID_FILE="/tmp/policy_bc_la_run_${RUN_ID}.pid"

SAMPLE_LOG="/tmp/policy_bc_la_samples.csv"
ACTION_LOG="/tmp/policy_bc_la_actions.csv"

mkdir -p "$RUN_DIR"

echo "=========================================="
echo "Policy B+C+Load-Aware formal experiment"
echo "Run: $RUN_ID"
echo "Results: $RUN_DIR"
echo "=========================================="

# =========================================================
# 1. Prepare files
# =========================================================

echo
echo "[1/8] Preparing files..."

sudo docker exec "$CONTAINER" sh -c "
rm -f '$XAPP_LOG' \
      '$PID_FILE' \
      '$SAMPLE_LOG' \
      '$ACTION_LOG'
"

# =========================================================
# 2. Start controller
# =========================================================

echo
echo "[2/8] Starting controller..."

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
    echo "ERROR: Could not obtain xApp PID."
    exit 1
fi

if ! sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$XAPP_PID' 2>/dev/null"
then
    echo "ERROR: Controller stopped."
    sudo docker exec "$CONTAINER" sh -c "cat '$XAPP_LOG'"
    exit 1
fi

echo "Controller running with PID $XAPP_PID."

# =========================================================
# 3. Verify KPM
# =========================================================

echo
echo "[3/8] Waiting for KPM indications..."

sleep 5

KPM_COUNT=$(sudo docker exec "$CONTAINER" \
    sh -c "grep -c 'RIC Indication Received' '$XAPP_LOG' 2>/dev/null || true")

echo "Initial KPM indications: $KPM_COUNT"

if [ "$KPM_COUNT" -lt 1 ]; then
    echo "ERROR: No KPM indications."
    sudo docker exec "$CONTAINER" sh -c "cat '$XAPP_LOG'"
    exit 1
fi

# =========================================================
# 4. Start ping
# =========================================================

echo
echo "[4/8] Starting ping..."

sudo ip netns exec ue1 ping \
-c 900 \
-i 0.1 \
10.45.0.1 \
> "$RUN_DIR/ping.txt" 2>&1 &

PING_PID=$!

sleep 1

# =========================================================
# Record sample/action positions BEFORE iperf
# =========================================================

SAMPLE_START=$(sudo docker exec "$CONTAINER" \
    sh -c "wc -l < '$SAMPLE_LOG'")

ACTION_START=$(sudo docker exec "$CONTAINER" \
    sh -c "wc -l < '$ACTION_LOG'")

echo "$SAMPLE_START" > "$RUN_DIR/sample_start_line.txt"
echo "$ACTION_START" > "$RUN_DIR/action_start_line.txt"

echo "KPM line before traffic: $SAMPLE_START"
echo "Action line before traffic: $ACTION_START"

# =========================================================
# 5. Run iperf
# =========================================================

echo
echo "[5/8] Starting 90-second iperf..."

sudo ip netns exec ue1 iperf3 \
-c 10.45.0.1 \
-t 90 \
-i 1 \
> "$RUN_DIR/iperf_ul.txt" 2>&1

IPERF_STATUS=$?

echo "iperf finished with status $IPERF_STATUS."

# Give final KPM indication about one second to arrive
sleep 1

# =========================================================
# Record sample/action positions AFTER iperf
# =========================================================

SAMPLE_END=$(sudo docker exec "$CONTAINER" \
    sh -c "wc -l < '$SAMPLE_LOG'")

ACTION_END=$(sudo docker exec "$CONTAINER" \
    sh -c "wc -l < '$ACTION_LOG'")

echo "$SAMPLE_END" > "$RUN_DIR/sample_end_line.txt"
echo "$ACTION_END" > "$RUN_DIR/action_end_line.txt"

echo "KPM line after traffic: $SAMPLE_END"
echo "Action line after traffic: $ACTION_END"

# =========================================================
# Wait for ping
# =========================================================

echo
echo "Waiting for ping..."

wait "$PING_PID"

sleep 2

# =========================================================
# 6. Stop controller
# =========================================================

echo
echo "[6/8] Stopping controller..."

sudo docker exec "$CONTAINER" \
    sh -c "kill -INT '$XAPP_PID' 2>/dev/null || true"

sleep 3

# =========================================================
# 7. Save complete logs
# =========================================================

echo
echo "[7/8] Saving logs..."

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
# 8. Create traffic-only files + summary
# =========================================================

echo
echo "[8/8] Creating traffic-window summary..."

python3 - "$RUN_DIR" <<'PY'
import csv
import re
import statistics
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])

# =========================================================
# Read line positions
# =========================================================

sample_start = int(
    (run_dir / "sample_start_line.txt").read_text().strip()
)

sample_end = int(
    (run_dir / "sample_end_line.txt").read_text().strip()
)

action_start = int(
    (run_dir / "action_start_line.txt").read_text().strip()
)

action_end = int(
    (run_dir / "action_end_line.txt").read_text().strip()
)

# =========================================================
# Load full KPM CSV
# =========================================================

sample_file = run_dir / "kpm_timeseries.csv"

with open(sample_file, newline="") as f:
    all_samples = list(csv.DictReader(f))

# wc includes the header.
# If start line = 11, that means 10 data rows already existed.
start_data_index = max(0, sample_start - 1)
end_data_index = max(0, sample_end - 1)

traffic_samples = all_samples[
    start_data_index:end_data_index
]

# =========================================================
# Save traffic-only KPM CSV
# =========================================================

filtered_sample_file = (
    run_dir / "kpm_traffic_window.csv"
)

with open(
    filtered_sample_file,
    "w",
    newline=""
) as f:

    if all_samples:
        writer = csv.DictWriter(
            f,
            fieldnames=all_samples[0].keys()
        )

        writer.writeheader()
        writer.writerows(traffic_samples)

# =========================================================
# Load actions
# =========================================================

action_file = run_dir / "control_actions.csv"

with open(action_file, newline="") as f:
    all_actions = list(csv.DictReader(f))

start_action_index = max(
    0,
    action_start - 1
)

end_action_index = max(
    0,
    action_end - 1
)

traffic_actions = all_actions[
    start_action_index:end_action_index
]

# =========================================================
# Save traffic-only actions
# =========================================================

filtered_action_file = (
    run_dir / "control_actions_traffic_window.csv"
)

with open(
    filtered_action_file,
    "w",
    newline=""
) as f:

    if all_actions:
        writer = csv.DictWriter(
            f,
            fieldnames=all_actions[0].keys()
        )

        writer.writeheader()
        writer.writerows(traffic_actions)

# =========================================================
# Parse iperf
# =========================================================

iperf_text = (
    run_dir / "iperf_ul.txt"
).read_text(errors="ignore")

sender = None
receiver = None
retr = None

m = re.search(
    r"([\d.]+)\s+Mbits/sec\s+(\d+)\s+sender",
    iperf_text
)

if m:
    sender = float(m.group(1))
    retr = int(m.group(2))

m = re.search(
    r"([\d.]+)\s+Mbits/sec\s+receiver",
    iperf_text
)

if m:
    receiver = float(m.group(1))

# =========================================================
# Parse ping
# =========================================================

ping_text = (
    run_dir / "ping.txt"
).read_text(errors="ignore")

loss = None
rtt_min = None
rtt_avg = None
rtt_max = None
rtt_mdev = None

m = re.search(
    r"([\d.]+)% packet loss",
    ping_text
)

if m:
    loss = float(m.group(1))

m = re.search(
    r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s+ms",
    ping_text
)

if m:
    rtt_min = float(m.group(1))
    rtt_avg = float(m.group(2))
    rtt_max = float(m.group(3))
    rtt_mdev = float(m.group(4))

# =========================================================
# KPM metrics during iperf
# =========================================================

prbs = []
throughputs = []
prb_used = []

state_counts = {
    30: 0,
    50: 0,
    70: 0,
    100: 0
}

for row in traffic_samples:

    try:
        value = float(
            row["current_prb_percent"]
        )

        prbs.append(value)

        state = int(round(value))

        if state in state_counts:
            state_counts[state] += 1

    except:
        pass

    try:
        throughputs.append(
            float(
                row["ul_throughput_raw"]
            )
        )
    except:
        pass

    try:
        prb_used.append(
            float(
                row["prb_used_ul"]
            )
        )
    except:
        pass

avg_prb = (
    statistics.mean(prbs)
    if prbs else None
)

avg_kpm_thp = (
    statistics.mean(throughputs)
    if throughputs else None
)

avg_prb_used = (
    statistics.mean(prb_used)
    if prb_used else None
)

# =========================================================
# PRB state percentages
# =========================================================

total_states = sum(
    state_counts.values()
)

def pct(x):
    if total_states == 0:
        return None

    return (
        x / total_states * 100
    )

pct30 = pct(state_counts[30])
pct50 = pct(state_counts[50])
pct70 = pct(state_counts[70])
pct100 = pct(state_counts[100])

# =========================================================
# Actions
# =========================================================

num_actions = len(traffic_actions)

up_actions = 0
down_actions = 0

for row in traffic_actions:

    try:
        old = float(
            row["old_prb_percent"]
        )

        new = float(
            row["new_prb_percent"]
        )

        if new > old:
            up_actions += 1

        elif new < old:
            down_actions += 1

    except:
        pass

# =========================================================
# QoS violation
# =========================================================

qos_target = 5000.0

if throughputs:

    violations = sum(
        x < qos_target
        for x in throughputs
    )

    qos_violation_percent = (
        violations /
        len(throughputs) *
        100
    )

else:
    qos_violation_percent = None

# =========================================================
# Save summary
# =========================================================

columns = [
    "policy",
    "iperf_sender_mbps",
    "iperf_receiver_mbps",
    "tcp_retransmissions",
    "packet_loss_percent",
    "rtt_min_ms",
    "rtt_avg_ms",
    "rtt_max_ms",
    "rtt_mdev_ms",
    "avg_prb_percent",
    "avg_prb_used",
    "avg_kpm_throughput_raw",
    "num_control_actions",
    "num_up_actions",
    "num_down_actions",
    "pct_time_prb_30",
    "pct_time_prb_50",
    "pct_time_prb_70",
    "pct_time_prb_100",
    "qos_violation_percent",
    "traffic_kpm_samples"
]

values = [
    "policy_bc_la",
    sender,
    receiver,
    retr,
    loss,
    rtt_min,
    rtt_avg,
    rtt_max,
    rtt_mdev,
    avg_prb,
    avg_prb_used,
    avg_kpm_thp,
    num_actions,
    up_actions,
    down_actions,
    pct30,
    pct50,
    pct70,
    pct100,
    qos_violation_percent,
    len(traffic_samples)
]

summary_file = (
    run_dir / "run_summary.csv"
)

with open(
    summary_file,
    "w",
    newline=""
) as f:

    writer = csv.writer(f)

    writer.writerow(columns)
    writer.writerow(values)

print()
print("==========================================")
print("TRAFFIC-WINDOW SUMMARY")
print("==========================================")

for name, value in zip(
    columns,
    values
):
    print(f"{name}: {value}")

print("==========================================")
PY

echo
echo "=========================================="
echo "Policy B+C+Load-Aware run_${RUN_ID} COMPLETE"
echo "=========================================="

echo
echo "Traffic-window KPM samples:"
wc -l "$RUN_DIR/kpm_traffic_window.csv"

echo
echo "Traffic-window control actions:"
wc -l "$RUN_DIR/control_actions_traffic_window.csv"

echo
echo "Summary:"
cat "$RUN_DIR/run_summary.csv"

echo
echo "=========================================="
