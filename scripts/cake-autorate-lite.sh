#!/bin/sh
# cake-autorate-lite: Lightweight autorate for CAKE
# Pings reflectors per-reflector, detects bufferbloat, adjusts CAKE bandwidth
#
# Inspired by: https://github.com/sqm-autorate/sqm-autorate
# The full sqm-autorate requires bash + more packages than fit on 4MB flash.
# This is a POSIX sh reimplementation that works on ar71xx/tiny devices.
#
# Only dependency: fping (installed via opkg)

# === CONFIG ===
DL_IF="ifb4eth1"
UL_IF="eth1"
REFLECTORS="8.8.8.8 1.1.1.1 9.9.9.9"
PING_COUNT=3
PING_INTERVAL_MS=500

MIN_DL=20000
BASE_DL=36000
MAX_DL=40000
MIN_UL=20000
BASE_UL=36000
MAX_UL=40000

# Delay threshold per-reflector: if RTT exceeds THIS reflector's baseline by this much
DELAY_THR_MS=15
# How much to decrease bandwidth on bufferbloat (kbps)
STEP_DOWN=2000
# How much to increase bandwidth when clear (kbps)
STEP_UP=500

# === INIT ===
cur_dl=$BASE_DL
cur_ul=$BASE_UL

# Measure baseline RTT per-reflector (from fping summary lines only)
measure_baseline() {
    rm -f /tmp/cake_art_bl.txt
    result=$(fping -c 10 -p 200 $REFLECTORS 2>&1)
    # Only match summary lines: "8.8.8.8 : xmt/rcv/%loss = ..."
    echo "$result" | grep 'xmt/rcv' | while IFS= read -r line; do
        ref=$(echo "$line" | sed 's/ :.*//')
        avg=$(echo "$line" | sed 's/.*avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/')
        if [ -n "$ref" ] && [ -n "$avg" ]; then
            avg_int=$(echo "$avg" | awk '{printf "%d", $1 * 1000}')
            echo "${ref}:${avg_int}"
        fi
    done > /tmp/cake_art_bl.txt
}

# Change CAKE bandwidth
set_bw() {
    local iface=$1
    local bw_kbps=$2
    local bw_mbit=$((bw_kbps / 1000))
    tc qdisc change dev "$iface" root cake bandwidth "${bw_mbit}Mbit" 2>/dev/null
}

# Get current bandwidth from tc
get_bw() {
    tc -s qdisc show dev "$1" 2>/dev/null | head -1 | sed 's/.*bandwidth \([0-9]*\)Mbit.*/\1/' | awk '{print $1 * 1000}'
}

echo "cake-autorate-lite starting..."
echo "Reflectors: $REFLECTORS"

# Measure per-reflector baselines
echo "Measuring baseline RTT per reflector..."
measure_baseline
echo "Baselines:"
cat /tmp/cake_art_bl.txt

# Read initial bandwidth
cur_dl=$(get_bw "$DL_IF")
cur_ul=$(get_bw "$UL_IF")
[ -z "$cur_dl" ] && cur_dl=$BASE_DL
[ -z "$cur_ul" ] && cur_ul=$BASE_UL
echo "Initial DL: ${cur_dl}kbps, UL: ${cur_ul}kbps"

# Main loop
while true; do
    # Ping all reflectors
    result=$(fping -c "$PING_COUNT" -p "$PING_INTERVAL_MS" $REFLECTORS 2>&1)

    # Parse per-reflector averages from summary lines only
    max_excess=0
    echo "$result" | grep 'xmt/rcv' | while IFS= read -r line; do
        ref=$(echo "$line" | sed 's/ :.*//')
        avg=$(echo "$line" | sed 's/.*avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/')
        if [ -n "$ref" ] && [ -n "$avg" ]; then
            avg_int=$(echo "$avg" | awk '{printf "%d", $1 * 1000}')
            bl=$(grep "^${ref}:" /tmp/cake_art_bl.txt 2>/dev/null | head -1 | cut -d: -f2)
            if [ -n "$bl" ] && [ "$bl" -gt 0 ] 2>/dev/null; then
                excess=$((avg_int - bl))
                echo "$excess"
            fi
        fi
    done > /tmp/cake_art_exc.txt

    # Find max excess across all reflectors
    max_excess=0
    while IFS= read -r val; do
        if [ -n "$val" ] && [ "$val" -gt "$max_excess" ] 2>/dev/null; then
            max_excess=$val
        fi
    done < /tmp/cake_art_exc.txt

    threshold=$((DELAY_THR_MS * 1000))

    # Decision logic
    if [ "$max_excess" -gt "$threshold" ] 2>/dev/null; then
        # BUFFERBLOAT detected - reduce bandwidth
        cur_dl=$((cur_dl - STEP_DOWN))
        cur_ul=$((cur_ul - STEP_DOWN))
        [ "$cur_dl" -lt "$MIN_DL" ] && cur_dl=$MIN_DL
        [ "$cur_ul" -lt "$MIN_UL" ] && cur_ul=$MIN_UL
        set_bw "$DL_IF" "$cur_dl"
        set_bw "$UL_IF" "$cur_ul"
        echo "[$(date +%H:%M:%S)] BLOAT excess=${max_excess}us -> DL=${cur_dl} UL=${cur_ul}"
    elif [ "$max_excess" -lt 2000 ] 2>/dev/null; then
        # CLEAR - increase toward baseline
        cur_dl=$((cur_dl + STEP_UP))
        cur_ul=$((cur_ul + STEP_UP))
        [ "$cur_dl" -gt "$BASE_DL" ] && cur_dl=$BASE_DL
        [ "$cur_ul" -gt "$BASE_UL" ] && cur_ul=$BASE_UL
        set_bw "$DL_IF" "$cur_dl"
        set_bw "$UL_IF" "$cur_ul"
    fi

    sleep 1
done
