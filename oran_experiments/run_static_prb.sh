#!/bin/bash

PRB=$1
RUN_ID=$2

if [ -z "$PRB" ] || [ -z "$RUN_ID" ]; then
    echo "Usage: ./run_static_prb.sh PRB RUN_ID"
    echo "Example: ./run_static_prb.sh 30 01"
    exit 1
fi

case "$PRB" in
    30|50|70|100)
        ;;
    *)
        echo "ERROR: PRB must be 30, 50, 70, or 100."
        exit 1
        ;;
esac

CONTAINER="python_xapp_runner"

RUN_DIR="$HOME/oran_experiments/static_prb_${PRB}/run_${RUN_ID}"

RC_LOG="/tmp/rc_prb_${PRB}_${RUN_ID}.txt"
RC_PID_FILE="/tmp/rc_prb_${PRB}_${RUN_ID}.pid"

KPM_LOG="/tmp/kpm_prb_${PRB}_${RUN_ID}.txt"
KPM_PID_FILE="/tmp/kpm_prb_${PRB}_${RUN_ID}.pid"

mkdir -p "$RUN_DIR"

echo "=========================================="
echo "Static PRB experiment"
echo "PRB = ${PRB}%"
echo "Run = ${RUN_ID}"
echo "Results = $RUN_DIR"
echo "=========================================="

# ---------------------------------------------------------
# 1. Check xApp HTTP port is free
# ---------------------------------------------------------

echo
echo "[1/10] Checking xApp port 8090..."

if sudo docker exec "$CONTAINER" \
    sh -c "ss -ltn 2>/dev/null | grep -q ':8090 '"
then
    echo "ERROR: Port 8090 is already in use."
    echo "Stop any manually running RC/KPM xApp first."
    exit 1
fi

echo "Port 8090 is free."

# ---------------------------------------------------------
# 2. Apply fixed PRB control
# ---------------------------------------------------------

echo
echo "[2/10] Applying ${PRB}% PRB control..."

sudo docker exec "$CONTAINER" \
    sh -c "rm -f '$RC_LOG' '$RC_PID_FILE'"

sudo docker exec "$CONTAINER" sh -c "
python3 -u /opt/xApps/fixed_prb_xapp.py \
--e2_node_id gnbd_001_001_00019b_0 \
--ran_func_id 3 \
--gnb_cu_ue_f1ap_id 0 \
--max_prb_ratio $PRB \
> '$RC_LOG' 2>&1 &

echo \$! > '$RC_PID_FILE'
"

sleep 3

RC_PID=$(sudo docker exec "$CONTAINER" \
    sh -c "cat '$RC_PID_FILE' 2>/dev/null")

if [ -z "$RC_PID" ]; then
    echo "ERROR: Could not obtain RC xApp PID."
    exit 1
fi

# ---------------------------------------------------------
# 3. Wait for RIC_CONTROL_ACK
# ---------------------------------------------------------

echo "[3/10] Waiting for RIC_CONTROL_ACK..."

ACK_FOUND=0

for i in {1..10}; do

    if sudo docker exec "$CONTAINER" \
        sh -c "grep -q 'RIC_CONTROL_ACK' '$RC_LOG' 2>/dev/null"
    then
        ACK_FOUND=1
        break
    fi

    sleep 1
done

if [ "$ACK_FOUND" -ne 1 ]; then
    echo
    echo "ERROR: No RIC_CONTROL_ACK received."
    echo
    sudo docker exec "$CONTAINER" \
        sh -c "cat '$RC_LOG'"

    sudo docker exec "$CONTAINER" \
        sh -c "kill -INT '$RC_PID' 2>/dev/null || true"

    exit 1
fi

echo "RIC_CONTROL_ACK received for ${PRB}% PRB."

# Save RC log
sudo docker exec "$CONTAINER" \
    sh -c "cat '$RC_LOG'" \
    > "$RUN_DIR/rc_control.txt"

# ---------------------------------------------------------
# 4. Stop RC xApp only
# ---------------------------------------------------------

echo
echo "[4/10] Stopping RC xApp..."

sudo docker exec "$CONTAINER" \
    sh -c "kill -INT '$RC_PID' 2>/dev/null || true"

sleep 2

if sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$RC_PID' 2>/dev/null"
then
    sudo docker exec "$CONTAINER" \
        sh -c "kill -TERM '$RC_PID' 2>/dev/null || true"
fi

sleep 2

# Verify 8090 is free before KPM starts
if sudo docker exec "$CONTAINER" \
    sh -c "ss -ltn 2>/dev/null | grep -q ':8090 '"
then
    echo "ERROR: RC xApp did not release port 8090."
    exit 1
fi

# ---------------------------------------------------------
# 5. Start KPM logger
# ---------------------------------------------------------

echo
echo "[5/10] Starting KPM logger..."

sudo docker exec "$CONTAINER" \
    sh -c "rm -f '$KPM_LOG' '$KPM_PID_FILE'"

sudo docker exec "$CONTAINER" sh -c "
python3 -u /opt/xApps/kpm_mon_xapp.py \
--e2_node_id gnbd_001_001_00019b_0 \
--ran_func_id 2 \
--kpm_report_style 1 \
--metrics DRB.UEThpUl,DRB.UEThpDl,RRU.PrbUsedUl,RRU.PrbUsedDl,RRU.PrbAvailUl,RRU.PrbAvailDl,CQI,RSRP \
> '$KPM_LOG' 2>&1 &

echo \$! > '$KPM_PID_FILE'
"

sleep 5

KPM_PID=$(sudo docker exec "$CONTAINER" \
    sh -c "cat '$KPM_PID_FILE' 2>/dev/null")

if [ -z "$KPM_PID" ]; then
    echo "ERROR: Could not obtain KPM xApp PID."
    exit 1
fi

if ! sudo docker exec "$CONTAINER" \
    sh -c "kill -0 '$KPM_PID' 2>/dev/null"
then
    echo "ERROR: KPM xApp stopped unexpectedly."
    sudo docker exec "$CONTAINER" \
        sh -c "cat '$KPM_LOG'"
    exit 1
fi

sleep 3

INITIAL_KPM_COUNT=$(sudo docker exec "$CONTAINER" \
    sh -c "grep -c 'RIC Indication Received' '$KPM_LOG' 2>/dev/null || true")

echo "Initial KPM indications: $INITIAL_KPM_COUNT"

if [ "$INITIAL_KPM_COUNT" -eq 0 ]; then
    echo "ERROR: No KPM indications received."
    sudo docker exec "$CONTAINER" \
        sh -c "cat '$KPM_LOG'"

    sudo docker exec "$CONTAINER" \
        sh -c "kill -INT '$KPM_PID' 2>/dev/null || true"

    exit 1
fi

# ---------------------------------------------------------
# 6. Start ping
# ---------------------------------------------------------

echo
echo "[6/10] Starting ping..."

sudo ip netns exec ue1 ping \
-c 600 \
-i 0.1 \
10.45.0.1 \
> "$RUN_DIR/ping.txt" 2>&1 &

PING_PID=$!

# ---------------------------------------------------------
# 7. Run 60-second iperf
# ---------------------------------------------------------

echo "[7/10] Starting 60-second uplink iperf..."

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
echo "[8/10] Waiting for ping..."

wait "$PING_PID"

echo "Ping finished."

sleep 3

# ---------------------------------------------------------
# 9. Stop KPM logger and save log
# ---------------------------------------------------------

echo
echo "[9/10] Stopping KPM logger..."

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
    sh -c "cat '$KPM_LOG'" \
    > "$RUN_DIR/kpm.txt"

KPM_COUNT=$(grep -c "RIC Indication Received" \
    "$RUN_DIR/kpm.txt" 2>/dev/null || true)

echo "Total KPM indications: $KPM_COUNT"

if [ "$KPM_COUNT" -eq 0 ]; then
    echo "ERROR: No KPM samples saved."
    exit 1
fi

# ---------------------------------------------------------
# 10. Parse results
# ---------------------------------------------------------

echo
echo "[10/10] Parsing results..."

python3 "$HOME/oran_experiments/parse_run.py" \
--run_dir "$RUN_DIR" \
--scenario static_prb \
--prb "$PRB"

if [ $? -ne 0 ]; then
    echo "ERROR: parse_run.py failed."
    exit 1
fi

echo
echo "=========================================="
echo "Static PRB ${PRB}% run_${RUN_ID} COMPLETE"
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
