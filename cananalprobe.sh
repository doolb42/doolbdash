#!/bin/bash
# canAnalProbe.sh
# CAN bus diagnostic and capture script for tucCANeer development
# Run from the car with OBD-II cable connected
# Usage: ./canAnalProbe.sh [duration_seconds]
# Default: 60 seconds
# Both 500kbps and 250kbps are always attempted

DURATION=${1:-60}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT=~/canAnalProbe_${TIMESTAMP}.log
FRAMES_500=~/canAnalProbe_frames_500k_${TIMESTAMP}.log
FRAMES_250=~/canAnalProbe_frames_250k_${TIMESTAMP}.log
PASS=0
FAIL=0
WARN=0

set +e

log()     { echo "$1" | tee -a $OUTPUT; }
pass()    { log "    [PASS] $1"; PASS=$((PASS+1)); }
fail()    { log "    [FAIL] $1"; FAIL=$((FAIL+1)); }
warn()    { log "    [WARN] $1"; WARN=$((WARN+1)); }
section() { log ""; log "================================================================"; log "==> $1"; log "================================================================"; }

log "================================================================"
log " canAnalProbe.sh"
log " $(date)"
log " Duration per bitrate: ${DURATION}s"
log " Kernel: $(uname -r)"
log " Hostname: $(hostname)"
log " Uptime: $(uptime)"
log "================================================================"

# ----------------------------------------------------------------
# SECTION 1: System health
# ----------------------------------------------------------------
section "1. System health"

TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
if [ -n "$TEMP" ]; then
    TEMP_C=$((TEMP/1000))
    log "    CPU temperature: ${TEMP_C}°C"
    if [ "$TEMP_C" -gt 80 ]; then
        warn "CPU temperature high (${TEMP_C}°C) — may throttle"
    else
        pass "CPU temperature OK (${TEMP_C}°C)"
    fi
else
    warn "Could not read CPU temperature"
fi

THROTTLE=$(vcgencmd get_throttled 2>/dev/null)
log "    Throttle state: ${THROTTLE:-unavailable}"
if echo "$THROTTLE" | grep -q "0x0"; then
    pass "No throttling detected"
elif [ -n "$THROTTLE" ]; then
    warn "Throttling detected: $THROTTLE — check power supply"
fi

log ""
log "    Full dmesg output:"
dmesg >> $OUTPUT 2>&1

# ----------------------------------------------------------------
# SECTION 2: Kernel driver verification
# ----------------------------------------------------------------
section "2. Kernel driver verification"

log "    Relevant dmesg entries:"
dmesg | grep -i -E "mcp|spi|can|overlay" | tee -a $OUTPUT

log ""
log "    Loaded kernel modules:"
lsmod | grep -E "mcp|spi|can" | tee -a $OUTPUT

if dmesg | grep -q "MCP2515 successfully initialized"; then
    pass "MCP2515 driver initialised"
else
    fail "MCP2515 driver did not initialise — check SPI wiring and config.txt overlay"
fi

if lsmod | grep -q "mcp251x"; then
    pass "mcp251x kernel module loaded"
else
    fail "mcp251x kernel module not loaded"
fi

if lsmod | grep -q "spi_bcm2835"; then
    pass "SPI BCM2835 driver loaded"
else
    fail "SPI BCM2835 driver not loaded — SPI may not be enabled in config.txt"
fi

if lsmod | grep -q "can_dev"; then
    pass "can_dev module loaded"
else
    fail "can_dev module not loaded"
fi

# ----------------------------------------------------------------
# SECTION 3: SPI hardware verification
# ----------------------------------------------------------------
section "3. SPI hardware verification"

if [ -e /dev/spidev0.0 ]; then
    pass "SPI device node /dev/spidev0.0 exists"
else
    fail "SPI device node /dev/spidev0.0 missing — SPI overlay may not have applied"
fi

log ""
log "    SPI device tree entries:"
ls /proc/device-tree/ | grep -i spi | tee -a $OUTPUT || log "    No SPI entries in device tree"

log ""
log "    MCP2515 clock as reported by kernel:"
dmesg | grep -i "mcp\|clock\|oscillator" | tee -a $OUTPUT

log ""
log "    GPIO 25 (INT pin) state:"
cat /sys/class/gpio/gpio25/value 2>/dev/null | tee -a $OUTPUT || log "    GPIO 25 not exported — normal if driver is managing it"

log ""
log "    config.txt SPI/MCP entries:"
grep -E "spi|mcp|overlay" /boot/config.txt | tee -a $OUTPUT

# ----------------------------------------------------------------
# SECTION 4: CAN interface status
# ----------------------------------------------------------------
section "4. CAN interface status"

log "    systemd-networkd status:"
systemctl status systemd-networkd --no-pager | tee -a $OUTPUT

log ""
log "    Full interface details:"
ip -details -statistics link show can0 2>&1 | tee -a $OUTPUT

if ip link show can0 &>/dev/null; then
    pass "can0 interface exists"
else
    fail "can0 interface does not exist"
fi

if ip link show can0 2>/dev/null | grep -q "UP"; then
    pass "can0 is UP"
else
    fail "can0 is not UP — attempting manual bring-up at 500kbps"
    sudo ip link set can0 up type can bitrate 500000 2>&1 | tee -a $OUTPUT
    if ip link show can0 2>/dev/null | grep -q "UP"; then
        pass "can0 brought up manually at 500kbps"
    else
        fail "can0 manual bring-up failed"
    fi
fi

CAN_STATE=$(ip -details link show can0 2>/dev/null | grep -o "can state [A-Z_-]*" | awk '{print $3}')
log "    CAN bus state: ${CAN_STATE:-unknown}"
case $CAN_STATE in
    ERROR-ACTIVE)  pass "Bus state ERROR-ACTIVE — interface healthy" ;;
    ERROR-PASSIVE) fail "Bus state ERROR-PASSIVE — high error rate, check CANH/CANL wiring or bitrate" ;;
    BUS-OFF)       fail "Bus state BUS-OFF — too many errors, interface shut down, check wiring" ;;
    STOPPED)       fail "Bus state STOPPED — interface not started" ;;
    *)             warn "Bus state unknown: ${CAN_STATE}" ;;
esac

# ----------------------------------------------------------------
# SECTION 5: Baseline error counters
# ----------------------------------------------------------------
section "5. Error counters (baseline)"

TX_BEFORE=$(ip -details -statistics link show can0 2>/dev/null | grep -o "tx_errors [0-9]*" | awk '{print $2}')
RX_BEFORE=$(ip -details -statistics link show can0 2>/dev/null | grep -o "rx_errors [0-9]*" | awk '{print $2}')
log "    TX errors: ${TX_BEFORE:-0}"
log "    RX errors: ${RX_BEFORE:-0}"

if [ "${TX_BEFORE:-0}" -gt 100 ] || [ "${RX_BEFORE:-0}" -gt 100 ]; then
    warn "High error count before capture — interface may have been struggling since boot"
fi

# ----------------------------------------------------------------
# SECTION 6: Active OBD-II query
# ----------------------------------------------------------------
section "6. Active OBD-II query"
log "    Sending standard OBD-II Mode 01 PID 00 request (supported PIDs query)"
log "    Any ECU responding confirms two-way communication"

cansend can0 7DF#0201000000000000 2>&1 | tee -a $OUTPUT && pass "OBD-II query sent" || fail "OBD-II query send failed"

log "    Listening 5s for OBD-II response..."
timeout 5 candump -t a can0 2>&1 | tee -a $OUTPUT | head -20
OBD_RESPONSE=$(timeout 5 candump can0 2>/dev/null | wc -l)
if [ "${OBD_RESPONSE:-0}" -gt 0 ]; then
    pass "Received response to OBD-II query — ECU communication confirmed"
else
    warn "No response to OBD-II query — ECU may not be active, ignition may be off, or gateway blocking"
fi

# ----------------------------------------------------------------
# SECTION 7: Capture at 500kbps
# ----------------------------------------------------------------
section "7. CAN frame capture at 500kbps (${DURATION}s)"
log "    Ensure ignition is ON"
log ""

sudo ip link set can0 down 2>/dev/null
sudo ip link set can0 up type can bitrate 500000 2>&1 | tee -a $OUTPUT

timeout $DURATION candump -t a can0 2>&1 | tee $FRAMES_500
COUNT_500=$(wc -l < $FRAMES_500 2>/dev/null || echo 0)
log ""
log "    Frames captured at 500kbps: ${COUNT_500}"
cat $FRAMES_500 >> $OUTPUT

if [ "${COUNT_500:-0}" -gt 0 ]; then
    pass "Frames received at 500kbps"

    log ""
    log "    Unique message IDs (500kbps):"
    awk '{print $3}' $FRAMES_500 | sort -u | tee -a $OUTPUT

    log ""
    log "    Message frequency table (top 30):"
    awk '{print $3}' $FRAMES_500 | sort | uniq -c | sort -rn | head -30 | tee -a $OUTPUT

    log ""
    log "    Checking for target regen level message ID 0x202:"
    if grep -qi " 202 \| 202#" $FRAMES_500; then
        pass "ID 0x202 FOUND — potential regen level message"
        grep -i " 202 \| 202#" $FRAMES_500 | head -20 | tee -a $OUTPUT
    else
        warn "ID 0x202 not seen at 500kbps"
    fi

    log ""
    log "    Checking for known HKMC CAN IDs:"
    for ID in 018 020 030 200 201 202 204 251 316 500 541 545 593 596 608 641 686 7A0 7DF; do
        if grep -qi " ${ID} \| ${ID}#" $FRAMES_500; then
            log "    [FOUND] ID 0x${ID}"
        fi
    done | tee -a $OUTPUT

    log ""
    log "    29-bit extended frame check:"
    if grep -q "##" $FRAMES_500; then
        pass "29-bit extended frames present"
        grep "##" $FRAMES_500 | head -10 | tee -a $OUTPUT
    else
        log "    No 29-bit extended frames seen"
    fi

    log ""
    log "    First 20 frames:"
    head -20 $FRAMES_500 | tee -a $OUTPUT

    log ""
    log "    Last 20 frames:"
    tail -20 $FRAMES_500 | tee -a $OUTPUT

else
    fail "No frames at 500kbps"
    log "    Possible causes:"
    log "      - OBD-II cable not connected or not seated"
    log "      - Ignition not on"
    log "      - CANH/CANL wires swapped on DB9 breakout (try swapping pins 2 and 7)"
    log "      - CAN gateway blocking OBD-II port"
    log "      - Wrong bitrate (250kbps will be tried next)"
    log "      - MCP2515 CANH/CANL not connected to DB9 breakout"
fi

# ----------------------------------------------------------------
# SECTION 8: Capture at 250kbps
# ----------------------------------------------------------------
section "8. CAN frame capture at 250kbps (${DURATION}s)"
log "    Trying 250kbps — some HKMC buses use this rate"
log ""

sudo ip link set can0 down 2>/dev/null
sudo ip link set can0 up type can bitrate 250000 2>&1 | tee -a $OUTPUT

timeout $DURATION candump -t a can0 2>&1 | tee $FRAMES_250
COUNT_250=$(wc -l < $FRAMES_250 2>/dev/null || echo 0)
log ""
log "    Frames captured at 250kbps: ${COUNT_250}"
cat $FRAMES_250 >> $OUTPUT

if [ "${COUNT_250:-0}" -gt 0 ]; then
    pass "Frames received at 250kbps"

    log ""
    log "    Unique message IDs (250kbps):"
    awk '{print $3}' $FRAMES_250 | sort -u | tee -a $OUTPUT

    log ""
    log "    Message frequency table (top 30):"
    awk '{print $3}' $FRAMES_250 | sort | uniq -c | sort -rn | head -30 | tee -a $OUTPUT

    log ""
    log "    Checking for target regen level message ID 0x202:"
    if grep -qi " 202 \| 202#" $FRAMES_250; then
        pass "ID 0x202 FOUND at 250kbps"
        grep -i " 202 \| 202#" $FRAMES_250 | head -20 | tee -a $OUTPUT
    else
        warn "ID 0x202 not seen at 250kbps"
    fi

    log ""
    log "    Checking for known HKMC CAN IDs:"
    for ID in 018 020 030 200 201 202 204 251 316 500 541 545 593 596 608 641 686 7A0 7DF; do
        if grep -qi " ${ID} \| ${ID}#" $FRAMES_250; then
            log "    [FOUND] ID 0x${ID}"
        fi
    done | tee -a $OUTPUT

else
    fail "No frames at 250kbps either"
    log "    Both bitrates failed. Check physical wiring before next attempt."
fi

# ----------------------------------------------------------------
# SECTION 9: Restore to 500kbps
# ----------------------------------------------------------------
section "9. Restoring interface to 500kbps"
sudo ip link set can0 down 2>/dev/null
sudo ip link set can0 up type can bitrate 500000 2>&1 | tee -a $OUTPUT
ip -details link show can0 | tee -a $OUTPUT
pass "Interface restored to 500kbps"

# ----------------------------------------------------------------
# SECTION 10: Post-capture error counters
# ----------------------------------------------------------------
section "10. Error counters (post-capture)"

TX_AFTER=$(ip -details -statistics link show can0 2>/dev/null | grep -o "tx_errors [0-9]*" | awk '{print $2}')
RX_AFTER=$(ip -details -statistics link show can0 2>/dev/null | grep -o "rx_errors [0-9]*" | awk '{print $2}')
log "    TX errors: ${TX_AFTER:-0}"
log "    RX errors: ${RX_AFTER:-0}"

TX_DELTA=$(( ${TX_AFTER:-0} - ${TX_BEFORE:-0} ))
RX_DELTA=$(( ${RX_AFTER:-0} - ${RX_BEFORE:-0} ))
log "    TX error delta: ${TX_DELTA}"
log "    RX error delta: ${RX_DELTA}"

if [ "$TX_DELTA" -gt 0 ] || [ "$RX_DELTA" -gt 0 ]; then
    fail "Errors accumulated during capture — TX: +${TX_DELTA} RX: +${RX_DELTA}"
    log "    Suggests wiring fault or bitrate mismatch"
else
    pass "No new errors during capture"
fi

# ----------------------------------------------------------------
# SECTION 11: Summary
# ----------------------------------------------------------------
section "11. Summary"
log "    PASSED:   ${PASS}"
log "    WARNINGS: ${WARN}"
log "    FAILED:   ${FAIL}"
log ""
log "    500kbps frames: ${COUNT_500:-0}"
log "    250kbps frames: ${COUNT_250:-0}"
log ""
log "    Log file:         $OUTPUT"
log "    500kbps frames:   $FRAMES_500"
log "    250kbps frames:   $FRAMES_250"
log ""
log "    To copy all logs to your desktop:"
log "    scp doolb@doolbdash.home:~/canAnalProbe_${TIMESTAMP}* ."
log ""
log "    Completed: $(date)"
