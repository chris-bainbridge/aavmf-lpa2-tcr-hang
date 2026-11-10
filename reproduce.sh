#!/bin/sh
# Reproduce the AAVMF LPA2 early-ID-map hang with -cpu max (TCG), and run the
# CPU-model matrix. Works with any edk2 2025.08..2026.02 era AAVMF/QEMU_EFI.
#
# Usage: ./reproduce.sh [path-to-AAVMF_CODE.fd]
set -eu

FW="${1:-/usr/share/AAVMF/AAVMF_CODE.fd}"
WORK="$(mktemp -d)"
QEMU="${QEMU:-qemu-system-aarch64}"

run() {
    cpu="$1"
    cp /usr/share/AAVMF/AAVMF_VARS.fd "$WORK/VARS.$cpu.fd"
    timeout 25 "$QEMU" \
        -M virt,gic-version=3 -cpu "$cpu" -accel tcg,thread=multi \
        -smp 2 -m 1024 \
        -drive if=pflash,format=raw,readonly=on,file="$FW" \
        -drive if=pflash,format=raw,file="$WORK/VARS.$cpu.fd" \
        -serial file:"$WORK/$cpu.serial" -monitor none -display none \
        >/dev/null 2>&1 || true
    bytes=$(wc -c < "$WORK/$cpu.serial")
    case "$bytes" in
        0)      echo "$cpu => $bytes bytes  (HANGS, before banner)" ;;
        77)     echo "$cpu => $bytes bytes  (HANGS after banner)" ;;
        *)      echo "$cpu => $bytes bytes  (boots)" ;;
    esac
}

echo "firmware: $FW"
for cpu in max cortex-a78ae cortex-a57 cortex-a72 cortex-a76 cortex-a710 \
           neoverse-v1 neoverse-n1 neoverse-n2 a64fx; do
    run "$cpu"
done

echo
echo "exception trace for -cpu max (-d int, first lines):"
cp /usr/share/AAVMF/AAVMF_VARS.fd "$WORK/VARS.trace.fd"
timeout 5 "$QEMU" \
    -M virt,gic-version=3 -cpu max -accel tcg,thread=multi -smp 2 -m 1024 \
    -drive if=pflash,format=raw,readonly=on,file="$FW" \
    -drive if=pflash,format=raw,file="$WORK/VARS.trace.fd" \
    -serial file:"$WORK/trace.serial" -monitor none -display none \
    -d int -D "$WORK/int.log" >/dev/null 2>&1 || true
head -7 "$WORK/int.log"

echo
echo "work dir: $WORK"
