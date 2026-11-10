#!/bin/sh
# Reproduce the decisive experiment: NOP out the `msr TCR_EL1, x0` that
# ArmConfigureMmu() executes (via ArmSetTCR) at firmware offset 0x18ea8 while
# the MMU is still enabled on the early ID map's tables. With that single
# instruction removed, AAVMF (edk2 2025.11) boots under -cpu max.
#
# This is a diagnostic, not a fix. See README.md.
set -eu

FW_IN="${1:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}"
WORK="$(mktemp -d)"
cp "$FW_IN" "$WORK/patched.fd"

python3 - "$WORK/patched.fd" <<'EOF'
import sys
f = open(sys.argv[1], "r+b")
f.seek(0x18EA8)
orig = f.read(4)
assert orig == bytes.fromhex("402018d5"), "unexpected bytes at 0x18ea8: %s" % orig.hex()
f.seek(0x18EA8)
f.write(bytes.fromhex("1f2003d5"))  # nop
f.close()
print("patched msr TCR_EL1,x0 @0x18ea8 -> nop")
EOF

cp /usr/share/AAVMF/AAVMF_VARS.fd "$WORK/VARS.fd"
echo "=== unpatched firmware, -cpu max ==="
timeout 20 qemu-system-aarch64 -M virt,gic-version=3 -cpu max -accel tcg,thread=multi \
  -smp 2 -m 1024 \
  -drive if=pflash,format=raw,readonly=on,file="$FW_IN" \
  -drive if=pflash,format=raw,file="$WORK/VARS.fd" \
  -serial file:"$WORK/before.serial" -monitor none -display none >/dev/null 2>&1 || true
echo "serial bytes: $(wc -c < "$WORK/before.serial") (77 = hangs after banner)"

cp /usr/share/AAVMF/AAVMF_VARS.fd "$WORK/VARS2.fd"
echo "=== patched firmware, -cpu max ==="
timeout 30 qemu-system-aarch64 -M virt,gic-version=3 -cpu max -accel tcg,thread=multi \
  -smp 2 -m 1024 \
  -drive if=pflash,format=raw,readonly=on,file="$WORK/patched.fd" \
  -drive if=pflash,format=raw,file="$WORK/VARS2.fd" \
  -serial file:"$WORK/after.serial" -monitor none -display none >/dev/null 2>&1 || true
echo "serial bytes: $(wc -c < "$WORK/after.serial") (>=174 = boots to PXE)"
tail -2 "$WORK/after.serial" || true
echo "work dir: $WORK"
