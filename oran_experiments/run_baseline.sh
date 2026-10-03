#!/bin/bash

RUN_ID=$1

if [ -z "$RUN_ID" ]; then
    echo "Usage: ./run_baseline.sh RUN_ID"
    exit 1
fi

RUN_DIR="$HOME/oran_experiments/baseline/run_${RUN_ID}"

CONTAINER="python_xapp_runner"
KPM_CONTAINER_LOG="/tmp/kpm_run_${RUN_ID}.txt"
KPM_PID_FILE="/tmp/kpm_run_${RUN_ID}.pid"

mkdir -p "$RUN_DIR"

echo "=========================================="
echo "Starting baseline run_${RUN_ID}"
echo "Results directory: $RUN_DIR"
echo "=========================================="

# ---------------------------------------------------------
# 1. Check that KPM HTTP port 8090 is free
# ---------------------------------------------------------

echo
echo "[1/8] Checking KPM xApp port..."

if sudo docker exec "$CONTAINER" \
    sh -c "ss -ltn 2>/dev/null | grep -q ':8090 '"
then
    echo
    echo "ERROR: Port 8090 is already in use inside $CONTAINER."
    echo "A previous KPM xApp may still be running."
    echo "Do NOT restart the container."
    exit 1
fi

echo "Port 8090 is free."

# ---------------------------------------------------------
# 2. Remove old temporary files for this run
# ---------------------------------------------------------

sudo docker exec "$CONTAINER" \
    sh -c "rm -f '$KPM_CONTAINER_LOG' '$KPM_PID_FILE'"

# ---------------------------------------------------------
# 3. Start KPM xApp inside the existing container
# ---------------------------------------------------------

echo
echo "[2/8] Starting KPM logger..."

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

# ---------------------------------------------------------
# 4. Check that KPM process is alive
# ---------------------------------------------------------

echo "[3/8] Verifying KPM logger..."

KPM_PID=$(sudo docker exec "$CONTAINER" \
    sh -c "cat '$KPM_PID_FILE' 2>/dev/null")

if [ -z "$KPM_PID" ]; then
    echo "ERROR: Could not obtain KPM process PID."
    exit 1
fi

if ! sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$KPM_PID' 2>/dev/null"
then
    echo
    echo "ERROR: KPM xApp stopped unexpectedly."

    sudo docker exec "$CONTAINER" \
        sh -c "cat '$KPM_CONTAINER_LOG' 2>/dev/null"

    exit 1
fi

# Check for obvious startup errors
if sudo docker exec "$CONTAINER" \
    sh -c "grep -q 'Traceback' '$KPM_CONTAINER_LOG' 2>/dev/null"
then
    echo
    echo "ERROR: KPM xApp produced a Python error."

    sudo docker exec "$CONTAINER" \
        sh -c "cat '$KPM_CONTAINER_LOG'"

    exit 1
fi

echo "KPM logger running with PID $KPM_PID."

# ---------------------------------------------------------
# 5. Confirm indications are actually arriving
# ---------------------------------------------------------

sleep 3

INITIAL_KPM_COUNT=$(sudo docker exec "$CONTAINER" \
    sh -c "grep -c 'RIC Indication Received' '$KPM_CONTAINER_LOG' 2>/dev/null || true")

echo "Initial KPM indications received: $INITIAL_KPM_COUNT"

if [ "$INITIAL_KPM_COUNT" -eq 0 ]; then
    echo
    echo "ERROR: KPM subscription started but no RIC indications arrived."
    echo "Current KPM log:"
    echo

    sudo docker exec "$CONTAINER" \
        sh -c "cat '$KPM_CONTAINER_LOG'"

    echo
    echo "Stopping KPM process..."

    sudo docker exec "$CONTAINER" \
        sh -c "kill -INT '$KPM_PID' 2>/dev/null || true"

    exit 1
fi

# ---------------------------------------------------------
# 6. Start ping measurement
# ---------------------------------------------------------

echo
echo "[4/8] Starting ping measurement..."

sudo ip netns exec ue1 ping \
-c 600 \
-i 0.1 \
10.45.0.1 \
> "$RUN_DIR/ping.txt" 2>&1 &

PING_PID=$!

# ---------------------------------------------------------
# 7. Start 60-second iperf traffic
# ---------------------------------------------------------

echo "[5/8] Starting 60-second uplink iperf test..."

sudo ip netns exec ue1 iperf3 \
-c 10.45.0.1 \
-t 60 \
-i 1 \
> "$RUN_DIR/iperf_ul.txt" 2>&1

IPERF_STATUS=$?

if [ "$IPERF_STATUS" -ne 0 ]; then
    echo "WARNING: iperf returned status $IPERF_STATUS."
fi

echo "iperf finished."

# ---------------------------------------------------------
# 8. Wait for ping
# ---------------------------------------------------------

echo
echo "[6/8] Waiting for ping to finish..."

wait "$PING_PID"

echo "Ping finished."

# Get a few final idle KPM measurements
sleep 3

# ---------------------------------------------------------
# 9. Stop ONLY this KPM process
# ---------------------------------------------------------

echo
echo "[7/8] Stopping KPM logger..."

sudo docker exec "$CONTAINER" \
    sh -c "kill -INT '$KPM_PID' 2>/dev/null || true"

sleep 2

# If still alive, use TERM
if sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$KPM_PID' 2>/dev/null"
then
    sudo docker exec "$CONTAINER" \
        sh -c "kill -TERM '$KPM_PID' 2>/dev/null || true"
fi

sleep 2

# Copy KPM log from container to experiment folder
sudo docker exec "$CONTAINER" \
    sh -c "cat '$KPM_CONTAINER_LOG'" \
    > "$RUN_DIR/kpm.txt"

# Count captured indications
KPM_COUNT=$(grep -c "RIC Indication Received" \
    "$RUN_DIR/kpm.txt" 2>/dev/null || true)

echo "Total KPM indications captured: $KPM_COUNT"

if [ "$KPM_COUNT" -eq 0 ]; then
    echo
    echo "ERROR: No KPM indications were saved."
    exit 1
fi

# ---------------------------------------------------------
# 10. Parse experiment files
# ---------------------------------------------------------

echo
echo "[8/8] Parsing results..."

python3 "$HOME/oran_experiments/parse_run.py" \
--run_dir "$RUN_DIR" \
--scenario baseline \
--prb baseline

if [ $? -ne 0 ]; then
    echo "ERROR: parse_run.py failed."
    exit 1
fi

# ---------------------------------------------------------
# Final results
# ---------------------------------------------------------

echo
echo "=========================================="
echo "Baseline run_${RUN_ID} COMPLETE"
echo "=========================================="

echo
echo "Run summary:"
cat "$RUN_DIR/run_summary.csv"

echo
echo "KPM CSV rows:"
wc -l "$RUN_DIR/kpm_timeseries.csv"

echo
echo "Generated files:"
ls -lh "$RUN_DIR"

echo
echo "=========================================="
