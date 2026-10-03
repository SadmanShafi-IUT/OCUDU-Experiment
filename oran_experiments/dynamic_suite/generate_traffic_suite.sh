#!/bin/bash

OUTPUT_DIR=$1

if [ -z "$OUTPUT_DIR" ]; then
    echo "Usage:"
    echo "./generate_traffic_suite.sh OUTPUT_DIRECTORY"
    exit 1
fi

SERVER_IP="10.45.0.1"

mkdir -p "$OUTPUT_DIR/raw_iperf"

EVENT_LOG="$OUTPUT_DIR/offered_load.csv"

echo "pattern,segment,start_epoch,end_epoch,duration_s,offered_load_mbps" \
> "$EVENT_LOG"

SESSION_GAP=2


run_segment () {

    PATTERN=$1
    SEGMENT=$2
    RATE=$3
    DURATION=$4

    FILE="$OUTPUT_DIR/raw_iperf/${PATTERN}_${SEGMENT}.txt"

    echo
    echo "------------------------------------------"
    echo "Pattern      : $PATTERN"
    echo "Segment      : $SEGMENT"
    echo "Offered load : ${RATE} Mbps"
    echo "Duration     : ${DURATION} s"
    echo "------------------------------------------"

    ATTEMPT=1
    MAX_ATTEMPTS=3

    while [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]
    do

        echo "iperf attempt $ATTEMPT/$MAX_ATTEMPTS"

        START=$(date +%s)

        sudo ip netns exec ue1 iperf3 \
            -c "$SERVER_IP" \
            -b "${RATE}M" \
            -t "$DURATION" \
            -i 1 \
            > "$FILE" 2>&1

        STATUS=$?

        END=$(date +%s)

        if [ "$STATUS" -eq 0 ]; then

            echo \
"$PATTERN,$SEGMENT,$START,$END,$DURATION,$RATE" \
>> "$EVENT_LOG"

            echo "Segment completed."

            sleep "$SESSION_GAP"

            return 0
        fi

        echo
        echo "WARNING:"
        echo "iperf failed for $PATTERN / $SEGMENT"
        cat "$FILE"

        ATTEMPT=$((ATTEMPT + 1))

        if [ "$ATTEMPT" -le "$MAX_ATTEMPTS" ]; then
            echo
            echo "Waiting 5 seconds before retry..."
            sleep 5
        fi

    done

    echo
    echo "ERROR:"
    echo "Segment failed after $MAX_ATTEMPTS attempts."

    return 1
}


idle_gap () {

    NAME=$1
    DURATION=$2

    echo
    echo "=========================================="
    echo "IDLE GAP: $DURATION seconds"
    echo "=========================================="

    START=$(date +%s)

    sleep "$DURATION"

    END=$(date +%s)

    echo \
"idle,$NAME,$START,$END,$DURATION,0" \
>> "$EVENT_LOG"
}


SUITE_START=$(date +%s)

echo "$SUITE_START" \
> "$OUTPUT_DIR/suite_start_epoch.txt"

echo
echo "=========================================="
echo "DYNAMIC TRAFFIC SUITE STARTED"
echo "=========================================="


# =========================================================
# 1. CONSTANT
# =========================================================

echo
echo "=========================================="
echo "PATTERN 1 — CONSTANT"
echo "=========================================="

run_segment \
    "constant" \
    "constant_6M" \
    6 \
    90 \
|| exit 1


idle_gap \
    "after_constant" \
    10


# =========================================================
# 2. STEP
# =========================================================

echo
echo "=========================================="
echo "PATTERN 2 — STEP"
echo "=========================================="

run_segment \
    "step" \
    "step_01_2M" \
    2 \
    30 \
|| exit 1

run_segment \
    "step" \
    "step_02_5M" \
    5 \
    30 \
|| exit 1

run_segment \
    "step" \
    "step_03_10M" \
    10 \
    30 \
|| exit 1

run_segment \
    "step" \
    "step_04_3M" \
    3 \
    30 \
|| exit 1


idle_gap \
    "after_step" \
    10


# =========================================================
# 3. BURSTY
# =========================================================

echo
echo "=========================================="
echo "PATTERN 3 — BURSTY"
echo "=========================================="

for CYCLE in 1 2 3 4 5 6
do

    run_segment \
        "bursty" \
        "burst_${CYCLE}_high" \
        10 \
        10 \
    || exit 1

    run_segment \
        "bursty" \
        "burst_${CYCLE}_low" \
        1 \
        10 \
    || exit 1

done


idle_gap \
    "after_bursty" \
    10


# =========================================================
# 4. RANDOM
# =========================================================

echo
echo "=========================================="
echo "PATTERN 4 — RANDOM"
echo "=========================================="

RANDOM_RATES=$(python3 - <<'PY'
import random

random.seed(20260927)

levels = [
    1,
    2,
    3,
    5,
    7,
    10
]

sequence = [
    random.choice(levels)
    for _ in range(12)
]

print(
    " ".join(
        str(x)
        for x in sequence
    )
)
PY
)

echo "Random sequence:"
echo "$RANDOM_RATES"

SEGMENT_NUMBER=1

for RATE in $RANDOM_RATES
do

    SEGMENT_NAME=$(printf \
        "random_%02d_%sM" \
        "$SEGMENT_NUMBER" \
        "$RATE"
    )

    run_segment \
        "random" \
        "$SEGMENT_NAME" \
        "$RATE" \
        10 \
    || exit 1

    SEGMENT_NUMBER=$((SEGMENT_NUMBER + 1))

done


SUITE_END=$(date +%s)

echo "$SUITE_END" \
> "$OUTPUT_DIR/suite_end_epoch.txt"

TOTAL_DURATION=$((SUITE_END - SUITE_START))


echo
echo "=========================================="
echo "DYNAMIC TRAFFIC SUITE COMPLETE"
echo "=========================================="

echo
echo "Total duration:"
echo "$TOTAL_DURATION seconds"

echo
echo "Offered-load schedule:"
cat "$EVENT_LOG"

echo
echo "=========================================="
