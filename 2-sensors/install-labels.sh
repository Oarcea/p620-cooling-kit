#!/usr/bin/env bash
# Step 2: lm-sensors labels for the P620 fan headers.  Run: sudo bash install-labels.sh
set -e; cd "$(dirname "$0")"
install -D -m 0644 p620-nct6686.conf /etc/sensors.d/p620-nct6686.conf
sensors nct6686-isa-0a20 2>/dev/null || echo "(sensors not installed or driver not loaded yet)"
