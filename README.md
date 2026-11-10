# AAVMF silent boot hang with `-cpu max` (LPA2 / 52-bit PARange) — verified root cause

Independent verification of the bug reported in
[tianocore/edk2#11962](https://github.com/tianocore/edk2/issues/11962)
("LPA2 support regresses emulated boot w/ `-cpu max`"), fixed upstream by
[PR #12545](https://github.com/tianocore/edk2/pull/12545) /
commit [`b8df7d9c8e1e`](https://github.com/tianocore/edk2/commit/b8df7d9c8e1e370b862890ebda677278c4c6155f)
("ArmVirtPkg/ArmPlatformLibQemu: Support early ID map on LPA2 capable CPUs").

Also tracked as [Debian bug #1124749](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1124749).
QEMU itself is **not** at fault — `-cpu max` correctly exposes
`ID_AA64MMFR0_EL1.PARange = 52-bit` + FEAT_LPA2, which is what real LPA2
hardware reports; the hang is a firmware (edk2 ArmVirtPkg) bug triggered by
any CPU with a 52-bit PARange.

## TL;DR

- Affected firmware: AAVMF/QEMU_EFI built from edk2 `stable202508` … `stable202602`
  (e.g. Ubuntu 26.04 `qemu-efi-aarch64 2025.11-3ubuntu7.3`, Fedora 43 `edk2-aarch64 20260213`).
- Fixed in: edk2 `stable202605`+ (commit `b8df7d9c8e1e`).
- Symptom: with `-cpu max` (TCG), the guest prints the `UEFI firmware (version …)`
  banner and then hangs **silently forever** — no serial output, no exceptions
  reported, guest CPU spinning in an infinite prefetch-abort storm.
- Workaround: use a CPU model whose `PARange` ≤ 48-bit (e.g. `-cpu cortex-a76`,
  `-cpu cortex-a57`, `-cpu neoverse-n1`), or update the firmware to edk2 ≥ stable202605.

## Verified reproduction

Host: x86_64, QEMU 10.2.1 (Ubuntu 26.04), guest firmware
`/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd` (edk2 2025.11-3ubuntu7.3).

```sh
cp /usr/share/AAVMF/AAVMF_VARS.fd VARS.fd
timeout 30 qemu-system-aarch64 \
    -M virt,gic-version=3 -cpu max -accel tcg,thread=multi -smp 2 -m 1024 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
    -drive if=pflash,format=raw,file=VARS.fd \
    -serial file:serial.log -monitor none -display none
# serial.log stops at 77 bytes (banner only) => hang
```

CPU-model matrix (serial bytes after 25 s, same command otherwise):

| `-cpu`           | PARange | result                          |
|------------------|---------|---------------------------------|
| `max`            | 52-bit  | **77 bytes, hangs**             |
| `cortex-a78ae`   | 52-bit? | **0 bytes, hangs (earlier)**    |
| `cortex-a57`     | 44-bit  | boots to BdsDxe/PXE             |
| `cortex-a72`     | 44-bit  | boots                           |
| `cortex-a76`     | 40-bit  | boots                           |
| `cortex-a710`    | 48-bit  | boots                           |
| `neoverse-v1`    | 48-bit  | boots                           |
| `neoverse-n1`    | 40-bit  | boots                           |
| `neoverse-n2`    | 48-bit  | boots                           |
| `a64fx`          | 48-bit  | boots                           |

Every model with PARange ≤ 48-bit boots; only 52-bit-PARange models hang.

## Where it gets stuck (instruction level)

With `-d int` (QEMU log), CPU 0 takes an endless storm of identical exceptions
(3.2 million in ~20 s):

```
Taking exception 3 [Prefetch Abort] on CPU 0
...from EL1 to EL1
...with ESR 0x21/0x86000006        ; Instruction Abort, current EL, IFSC=0b00110
...with FAR 0x5200                 ; = translation fault, level 2
...with ELR 0x5200
...to EL1 PC 0x5200 PSTATE 0x23c5
```

The first exception of the storm faults on the fetch of `0x18eac`; every
subsequent one faults on the fetch of the exception vector `0x5200` itself
(VBAR_EL1 = 0x5000), so the firmware can never even run its "Synchronous
Exception at ELx" reporter — hence the *silent* hang.

Tracing executed instructions (`-d in_asm,int`), the **last instruction that
executes before the storm** is at firmware offset `0x18ea8`:

```
0x18e90:  mrs    x1, CurrentEL          ; ArmSetTCR()
0x18e9c:  cbz/bnz …                     ; per-EL switch
0x18ea8:  msr   TCR_EL1, x0             ; 0xd5182040  ← last instruction executed
0x18eac:  <prefetch abort: translation fault L2>   ; the very next fetch faults
```

`0x18e90` is `ArmSetTCR()`, whose only caller in the firmware image is
`ArmConfigureMmu()` (UefiCpuPkg/Library/ArmMmuLib/AArch64/ArmMmuLibCore.c).

## Root cause (matches the upstream fix exactly)

1. `ArmPlatformPeiBootAction()` (ArmVirtPkg/Library/ArmPlatformLibQemu/
   ArmPlatformHelper.S) enables the MMU very early with the static "early ID
   map" (`IdMap.S`) baked into the FV. The startup code computes the early TCR
   from `ID_AA64MMFR0_EL1.PARange` **clamped to 48-bit**
   (`cmp x6, #6 / sub/cinc` → `IPS = min(PARange, 0b101)`), so the early map
   runs with `T0SZ = 16`, `TCR.DS = 0`, 4 KB granule, level-0 root.

2. Later, `ArmConfigureMmu()` recomputes the TCR from the **unclamped**
   PARange. On a 52-bit PARange CPU with FEAT_LPA2 it selects
   `T0SZ = 12`, `TCR.DS = 1`, `IPS = 0b110`, and calls `ArmSetTCR()` —
   **while the MMU is still enabled and walking the early ID map's tables**.

3. The TCR write changes the walk geometry live: the old root table is now
   interpreted as a level −1 table, so every lookup lands one level too deep.
   For the flash fetch at VA `0x18eac` the chain becomes
   `old-L0[0] → old-L1[0] → old-L2[0] → old-L3[0]`, and `old-L3[0]` is the
   deliberately-invalid first entry of the L3 table (`IdMap.S`: "omit first
   4k page") → **translation fault, level 2**. The fault vector (XIP flash)
   faults identically → infinite prefetch-abort storm.

4. On PARange ≤ 48-bit CPUs, `ArmConfigureMmu()` computes exactly the same
   TCR that the early code already programmed, so the live write is harmless
   and boot proceeds — which is why only 52-bit-PARange models hang.

## Decisive experiment

Patching a copy of the firmware image, replacing the single `msr TCR_EL1, x0`
at offset `0x18ea8` with a `nop`:

```
$ aarch64-linux-gnu-objdump -D -b binary -m aarch64 --start-address=0x18ea8 \
    --stop-address=0x18eb0 patched.fd
 18ea8: d503201f  nop

$ timeout 30 qemu-system-aarch64 … -cpu max … -drive if=pflash,…,file=patched.fd …
exit=124 serial bytes=174
UEFI firmware (version 2025.11-3ubuntu7.3 built at 15:40:26 on Sep 23 2026)
>>Start PXE over IPv4.
```

The guest now boots all the way to the network boot prompt under `-cpu max`.
This proves the live `TCR_EL1` write in `ArmConfigureMmu()` is the sole
trigger, and matches the fix Ard Biesheuvel shipped in
`b8df7d9c8e1e` (provide an LPA2-geometry early ID map so that the TCR value
`ArmConfigureMmu()` computes is identical to the one the early code chose).

(The `nop` only works because the remaining `ArmConfigureMmu()` flow then
populates its new tables and switches `TTBR0` while `TCR` still matches the
early map's geometry — it is a diagnostic, not a fix.)

## Upstream status

| item | value |
|------|-------|
| Canonical issue | https://github.com/tianocore/edk2/issues/11962 (closed as completed) |
| Fix PR | https://github.com/tianocore/edk2/pull/12545 |
| Fix commit | `b8df7d9c8e1e370b862890ebda677278c4c6155f` (2026-05-05) |
| First fixed stable tag | `edk2-stable202605` (verified: `IdMap.S` contains `idmap_lpa2` in 202605/202608, absent in 202511/202602) |
| Debian tracking | https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1124749 |
| Historical QEMU-side report (older, different root cause) | https://gitlab.com/qemu-project/qemu/-/issues/1177 |
