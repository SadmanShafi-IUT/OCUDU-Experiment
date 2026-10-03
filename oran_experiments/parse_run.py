#!/usr/bin/env python3

import argparse
import csv
import re
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--run_dir", required=True)
parser.add_argument("--scenario", required=True)
parser.add_argument("--prb", default="baseline")
args = parser.parse_args()

run_dir = Path(args.run_dir)

kpm_file = run_dir / "kpm.txt"
iperf_file = run_dir / "iperf_ul.txt"
ping_file = run_dir / "ping.txt"


# ---------------------------------------------------------
# 1. Parse KPM time-series
# ---------------------------------------------------------

kpm_rows = []

current_timestamp = None
current_row = None

timestamp_re = re.compile(r"ColletStartTime:\s+(.*)")
metric_re = re.compile(
    r"--Metric:\s+([^,]+),\s+Value:\s+\[([^\]]+)\]"
)

if kpm_file.exists():

    with open(kpm_file, "r", errors="ignore") as f:

        for line in f:

            ts_match = timestamp_re.search(line)

            if ts_match:

                if current_row is not None:
                    kpm_rows.append(current_row)

                current_timestamp = ts_match.group(1).strip()

                current_row = {
                    "timestamp": current_timestamp,
                    "scenario": args.scenario,
                    "prb_policy": args.prb
                }

                continue

            metric_match = metric_re.search(line)

            if metric_match and current_row is not None:

                metric_name = metric_match.group(1).strip()
                value = metric_match.group(2).strip()

                try:
                    value = float(value)
                except ValueError:
                    pass

                current_row[metric_name] = value

        if current_row is not None:
            kpm_rows.append(current_row)


metric_names = [
    "DRB.UEThpUl",
    "DRB.UEThpDl",
    "RRU.PrbUsedUl",
    "RRU.PrbUsedDl",
    "RRU.PrbAvailUl",
    "RRU.PrbAvailDl",
    "CQI",
    "RSRP"
]

kpm_csv = run_dir / "kpm_timeseries.csv"

with open(kpm_csv, "w", newline="") as f:

    fieldnames = [
        "timestamp",
        "scenario",
        "prb_policy"
    ] + metric_names

    writer = csv.DictWriter(f, fieldnames=fieldnames)

    writer.writeheader()

    for row in kpm_rows:

        output_row = {
            key: row.get(key, "")
            for key in fieldnames
        }

        writer.writerow(output_row)


# ---------------------------------------------------------
# 2. Parse iperf summary
# ---------------------------------------------------------

iperf_sender = None
iperf_receiver = None
retransmissions = None

if iperf_file.exists():

    text = iperf_file.read_text(errors="ignore")

    sender_match = re.search(
        r"([\d.]+)\s+Mbits/sec\s+(\d+)\s+sender",
        text
    )

    receiver_match = re.search(
        r"([\d.]+)\s+Mbits/sec\s+receiver",
        text
    )

    if sender_match:
        iperf_sender = float(sender_match.group(1))
        retransmissions = int(sender_match.group(2))

    if receiver_match:
        iperf_receiver = float(receiver_match.group(1))


# ---------------------------------------------------------
# 3. Parse ping summary
# ---------------------------------------------------------

packet_loss = None

rtt_min = None
rtt_avg = None
rtt_max = None
rtt_mdev = None

if ping_file.exists():

    text = ping_file.read_text(errors="ignore")

    loss_match = re.search(
        r"([\d.]+)% packet loss",
        text
    )

    rtt_match = re.search(
        r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)\s+ms",
        text
    )

    if loss_match:
        packet_loss = float(loss_match.group(1))

    if rtt_match:
        rtt_min = float(rtt_match.group(1))
        rtt_avg = float(rtt_match.group(2))
        rtt_max = float(rtt_match.group(3))
        rtt_mdev = float(rtt_match.group(4))


# ---------------------------------------------------------
# 4. Run-level summary
# ---------------------------------------------------------

summary_file = run_dir / "run_summary.csv"

with open(summary_file, "w", newline="") as f:

    writer = csv.writer(f)

    writer.writerow([
        "scenario",
        "prb_policy",
        "iperf_sender_mbps",
        "iperf_receiver_mbps",
        "tcp_retransmissions",
        "packet_loss_percent",
        "rtt_min_ms",
        "rtt_avg_ms",
        "rtt_max_ms",
        "rtt_mdev_ms"
    ])

    writer.writerow([
        args.scenario,
        args.prb,
        iperf_sender,
        iperf_receiver,
        retransmissions,
        packet_loss,
        rtt_min,
        rtt_avg,
        rtt_max,
        rtt_mdev
    ])


print("Created:")
print(kpm_csv)
print(summary_file)
print()
print("KPM samples:", len(kpm_rows))
