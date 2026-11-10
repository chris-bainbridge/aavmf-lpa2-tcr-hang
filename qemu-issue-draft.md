# Prepared QEMU issue text (draft)

> Decision (2026-11-10): **not filed, deliberately.** The root cause is in edk2
> (tianocore/edk2#11962, fixed by PR #12545 in edk2-stable202605), not in QEMU —
> `-cpu max` behaves per spec. A QEMU issue would be closed as NOT-A-BUG /
> TRACKED-ELSEWHERE, so we chose not to create triage noise. This draft is kept
> only for reference; the canonical record is edk2#11962 plus the verification
> comment: https://github.com/tianocore/edk2/issues/11962#issuecomment-6771893806
> (The older QEMU issue #1177 covers a different root cause from 2022.)

---

## Title

qemu-system-aarch64 `-cpu max` (TCG): AAVMF firmware from edk2 ≤ stable202602 hangs silently in early boot (LPA2/TCR mismatch — fixed in edk2 stable202605)

## Host environment

- Operating system: Ubuntu 26.04 (x86_64 host)
- QEMU version: QEMU emulator version 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.3)
- Guest firmware: qemu-efi-aarch64 2025.11-3ubuntu7.3 (edk2-stable202511)

## Command line

```
qemu-system-aarch64 -M virt,gic-version=3 -cpu max -accel tcg,thread=multi \
  -smp 2 -m 1024 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
  -drive if=pflash,format=raw,file=VARS.fd \
  -serial file:serial.log -monitor none -display none
```

## Description of problem

With `-cpu max` under TCG, AAVMF prints its version banner (77 bytes of serial
output) and then hangs forever with no further output. `-cpu cortex-a76`,
`-cpu cortex-a57`, `-cpu neoverse-n1`, `-cpu neoverse-v1`, `-cpu neoverse-n2`,
`-cpu cortex-a710`, `-cpu a64fx` and `-cpu cortex-a72` all boot to the BdsDxe
boot manager. `-cpu cortex-a78ae` hangs even earlier (0 bytes).

`-d int` shows CPU 0 stuck in an infinite prefetch-abort storm
(ESR 0x21/0x86000006 — instruction abort, translation fault level 2), first on
the instruction fetch right after `msr TCR_EL1, x0` inside the firmware's
`ArmConfigureMmu()` (ArmSetTCR), then forever on the exception vector fetch
itself (FAR=ELR=0x5200), so the firmware cannot even run its exception
reporter — hence the silent hang.

## Root cause (not a QEMU bug)

QEMU's `-cpu max` correctly reports ID_AA64MMFR0_EL1.PARange=52-bit with
FEAT_LPA2, matching real LPA2-capable hardware. The hang is an edk2 ArmVirtPkg
firmware bug: ArmPlatformPeiBootAction() enables an early ID map (static page
tables in flash) with the TCR clamped to 48-bit addressing (T0SZ=16, DS=0);
ArmConfigureMmu() later reprograms TCR_EL1 to 52-bit/LPA2 (T0SZ=12, DS=1)
while the MMU is still enabled on those tables. The live TCR change makes the
active translation tables uninterpretable (lookups land one level too deep and
hit an invalid descriptor), and the very next instruction fetch — XIP from
flash — faults, forever.

Verified experimentally: NOP-ing the single `msr TCR_EL1, x0` instruction at
firmware offset 0x18ea8 makes the guest boot to the PXE prompt under
`-cpu max`.

## Upstream status / resolution

- Canonical firmware issue: https://github.com/tianocore/edk2/issues/11962
  (closed as completed)
- Fix: https://github.com/tianocore/edk2/pull/12545 — commit
  b8df7d9c8e1e370b862890ebda677278c4c6155f
  "ArmVirtPkg/ArmPlatformLibQemu: Support early ID map on LPA2 capable CPUs"
- First edk2 stable tag with the fix: **stable202605** (present in 202605 and
  202608; absent in 202511 and 202602)
- Debian tracking: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1124749
- Related (older, different root cause): qemu issue #1177

## Workarounds

- Update the guest firmware to an edk2 stable202605-or-later build, or
- pin a CPU model with PARange ≤ 48-bit, e.g. `-cpu cortex-a76` or
  `-cpu neoverse-n1` (note `-cpu max,lpa2=off` is *not* a reliable workaround —
  it trips a different bug in the same firmware generation).

Filing this so QEMU users hitting the hang with distro firmware find the
explanation; feel free to close as TRACKED-ELSEWHERE / NOT-A-BUG.
