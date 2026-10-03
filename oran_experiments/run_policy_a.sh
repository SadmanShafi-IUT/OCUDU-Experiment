#!/bin/bash

RUN_ID=$1

if [ -z "$RUN_ID" ]; then
    echo "Usage: ./run_policy_a.sh RUN_ID"
    echo "Example: ./run_policy_a.sh 01"
    exit 1
fi

CONTAINER="python_xapp_runner"

RUN_DIR="$HOME/oran_experiments/policy_a/run_${RUN_ID}"

XAPP_LOG="/tmp/policy_a_run_${RUN_ID}.txt"
PID_FILE="/tmp/policy_a_run_${RUN_ID}.pid"

SAMPLE_LOG="/tmp/policy_a_samples.csv"
ACTION_LOG="/tmp/policy_a_actions.csv"

mkdir -p "$RUN_DIR"

echo "=========================================="
echo "Policy A formal experiment"
echo "Run: $RUN_ID"
echo "Results: $RUN_DIR"
echo "=========================================="

# ---------------------------------------------------------
# 1. Clean old temporary files
# ---------------------------------------------------------

echo
echo "[1/8] Preparing files..."

sudo docker exec "$CONTAINER" sh -c "
rm -f '$XAPP_LOG' \
      '$PID_FILE' \
      '$SAMPLE_LOG' \
      '$ACTION_LOG'
"

# ---------------------------------------------------------
# 2. Start Policy A xApp
# ---------------------------------------------------------

echo "[2/8] Starting Policy A controller..."

sudo docker exec "$CONTAINER" sh -c "
python3 -u /opt/xApps/policy_a_xapp.py \
--e2_node_id gnbd_001_001_00019b_0 \
--ue_id 0 \
--initial_prb 30 \
--throughput_target 5000 \
> '$XAPP_LOG' 2>&1 &

echo \$! > '$PID_FILE'
"

sleep 4

XAPP_PID=$(sudo docker exec "$CONTAINER" \
    sh -c "cat '$PID_FILE' 2>/dev/null")

if [ -z "$XAPP_PID" ]; then
    echo "ERROR: Could not obtain Policy A PID."
    exit 1
fi

if ! sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$XAPP_PID' 2>/dev/null"
then
    echo "ERROR: Policy A xApp stopped."
    sudo docker exec "$CONTAINER" \
        sh -c "cat '$XAPP_LOG'"
    exit 1
fi

echo "Policy A running with PID $XAPP_PID."

# ---------------------------------------------------------
# 3. Give subscription time to become active
# ---------------------------------------------------------

sleep 3

echo
echo "[3/8] Starting ping..."

sudo ip netns exec ue1 ping \
-c 900 \
-i 0.1 \
10.45.0.1 \
> "$RUN_DIR/ping.txt" 2>&1 &

PING_PID=$!

# ---------------------------------------------------------
# 4. Run 90-second saturated traffic
# ---------------------------------------------------------

echo "[4/8] Starting 90-second iperf..."

sudo ip netns exec ue1 iperf3 \
-c 10.45.0.1 \
-t 90 \
-i 1 \
> "$RUN_DIR/iperf_ul.txt" 2>&1

echo "iperf finished."

# ---------------------------------------------------------
# 5. Wait for ping
# ---------------------------------------------------------

echo
echo "[5/8] Waiting for ping..."

wait "$PING_PID"

sleep 2

# ---------------------------------------------------------
# 6. Stop Policy A xApp
# ---------------------------------------------------------

echo "[6/8] Stopping Policy A..."

sudo docker exec "$CONTAINER" \
    sh -c "kill -INT '$XAPP_PID' 2>/dev/null || true"

sleep 3

# ---------------------------------------------------------
# 7. Copy controller logs
# ---------------------------------------------------------

echo "[7/8] Saving controller logs..."

sudo docker exec "$CONTAINER" \
    sh -c "cat '$XAPP_LOG'" \
    > "$RUN_DIR/controller.txt"

sudo docker exec "$CONTAINER" \
    sh -c "cat '$SAMPLE_LOG'" \
    > "$RUN_DIR/kpm_timeseries.csv"

sudo docker exec "$CONTAINER" \
    sh -c "cat '$ACTION_LOG'" \
    > "$RUN_DIR/control_actions.csv"

# ---------------------------------------------------------
# 8. Create run summary
# ---------------------------------------------------------

echo "[8/8] Creating summary..."

python3 - "$RUN_DIR" <<'PY'
import csv
import re
import statistics
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])

# -----------------------------
# iperf
# -----------------------------

iperf_text = (run_dir / "iperf_ul.txt").read_text(errors="ignore")

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


# -----------------------------
# ping
# -----------------------------

ping_text = (run_dir / "ping.txt").read_text(errors="ignore")

loss = None
rtt_avg = None

m = re.search(r"([\d.]+)% packet loss", ping_text)

if m:
    loss = float(m.group(1))

m = re.search(
    r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s+ms",
    ping_text
)

if m:
    rtt_avg = float(m.group(2))


# -----------------------------
# Policy samples
# -----------------------------

sample_file = run_dir / "kpm_timeseries.csv"

samples = []

with open(sample_file, newline="") as f:
    samples = list(csv.DictReader(f))

prbs = []

throughputs = []

for r in samples:

    try:
        prbs.append(
            float(r["current_prb_percent"])
        )
    except:
        pass

    try:
        throughputs.append(
            float(r["ul_throughput_raw"])
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


# -----------------------------
# Control actions
# -----------------------------

action_file = run_dir / "control_actions.csv"

with open(action_file, newline="") as f:
    actions = list(csv.DictReader(f))

num_actions = len(actions)


# -----------------------------
# Save summary
# -----------------------------

summary = run_dir / "run_summary.csv"

with open(summary, "w", newline="") as f:

    writer = csv.writer(f)

    writer.writerow([
        "policy",
        "iperf_sender_mbps",
        "iperf_receiver_mbps",
        "tcp_retransmissions",
        "packet_loss_percent",
        "rtt_avg_ms",
        "avg_prb_percent",
        "avg_kpm_throughput_raw",
        "num_control_actions"
    ])

    writer.writerow([
        "policy_a",
        sender,
        receiver,
        retr,
        loss,
        rtt_avg,
        avg_prb,
        avg_kpm_thp,
        num_actions
    ])

print()
print("Summary:")
print(summary.read_text())
PY

echo
echo "=========================================="
echo "Policy A run_${RUN_ID} COMPLETE"
echo "=========================================="

echo
echo "Files:"
ls -lh "$RUN_DIR"

echo
echo "Control actions:"
wc -l "$RUN_DIR/control_actions.csv"

echo
echo "KPM samples:"
wc -l "$RUN_DIR/kpm_timeseries.csv"

echo "=========================================="
