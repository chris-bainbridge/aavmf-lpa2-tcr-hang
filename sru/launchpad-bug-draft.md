# Launchpad bug draft (SRU template)

File against: `edk2` (Ubuntu) → task for **resolute** (26.04). Noble (2024.02)
and jammy (2022.02) predate the regression; plucky/questing are EOL.

---

**Title:** aarch64 guests hang silently at firmware boot with LPA2-capable CPUs (e.g. `-cpu max` under TCG, or KVM on 52-bit-PA hosts)

**Affects:** edk2 2025.11-3ubuntu7 (resolute) and all 7.x updates so far
(including 2025.11-3ubuntu7.4 in resolute-proposed)

**Summary:** AAVMF/qemu-efi-aarch64 built from edk2-stable202511 hangs
silently very early in firmware boot whenever the vCPU reports a 52-bit
physical address range with FEAT_LPA2 — which is what QEMU's `-cpu max`
reports (the common CPU model for TCG aarch64 guests), and also what aarch64
KVM guests see on 52-bit-PA hardware (NVIDIA Grace / AWS Graviton4 class).
The guest prints the "UEFI firmware (version ...)" banner and then spins
forever in an exception storm; nothing further is printed and no error is
reported.

Workarounds: pin a CPU model with a ≤48-bit PARange (e.g. `-cpu cortex-a76`,
`-cpu neoverse-n1`), or replace the firmware with a build from
edk2-stable202605 or later.

**Root cause:** ArmPlatformPeiBootAction() enables an early identity map
(static page tables in the firmware flash) with the TCR clamped to 48-bit
addressing (T0SZ=16, DS=0), because the static tables predate LPA2 support
for 4K granule. ArmConfigureMmu() subsequently reprograms TCR_EL1 for
52-bit/LPA2 (T0SZ=12, DS=1) while the MMU is still enabled on those tables.
The live TCR change makes the active translation tables uninterpretable
(lookups land one level too deep and hit an invalid descriptor), so the very
next instruction fetch — executing XIP from flash — faults, and the fault
vector faults identically: an endless prefetch-abort storm
(ESR 0x21/0x86000006, translation fault level 2). Verified at instruction
level; see [1] for the full evidence, including an experiment showing that
NOP-ing the single `msr TCR_EL1, x0` in ArmConfigureMmu() lets the unpatched
2025.11 firmware boot under `-cpu max`.

**Fix:** upstream edk2 commit b8df7d9c8e1e370b862890ebda677278c4c6155f
("ArmVirtPkg/ArmPlatformLibQemu: Support early ID map on LPA2 capable CPUs",
PR #12545), first shipped in edk2-stable202605. It provides a second, LPA2-geometry
set of early page tables and selects 52-bit/DS=1 in the early TCR if and only
if the CPU supports it, so that ArmConfigureMmu() computes exactly the TCR
value the early code programmed. The commit is cherry-picked verbatim; the
only adjustment is retaining resolute's current `.section` attribute on one
line (an unrelated CLANGPDB build change, 2eed2bf8f007, is not needed for the
GCC5 build and is not included).

**SRU Justification:**

*Impact:* a default-reachable configuration (aarch64 guest, `-cpu max`) is
completely broken with the shipped firmware; the failure mode is a silent
hang, which is costly to diagnose (see the independent write-ups in
tianocore/edk2#11962, Debian bug #1124749 and the kubevirtci workaround of
pinning cortex-a57). Also affects arm64 KVM guests on 52-bit-PA server
hardware.

*Test Case:* see "Test Plan" below; deterministic before/after (77-byte
serial hang → boots to BdsDxe/PXE).

*Regression Potential:* low. The patch only changes ArmVirtQemu's early-boot
identity map and its TCR programming. The new LPA2 page tables and the
52-bit/DS=1 TCR are selected only when the CPU reports PARange=52-bit AND
FEAT_LPA2 for 4K granule; for every other CPU the early-boot path is
unchanged. The identical change has been in edk2 master since 2026-05-05 and
in upstream stable tags 202605 and 202608 without follow-up fixes.

*Other Info:* upstream issue https://github.com/tianocore/edk2/issues/11962
(closed as completed); fix PR https://github.com/tianocore/edk2/pull/12545;
Debian bug https://bugs.debian.org/1124749 (Debian stable is not affected —
trixie ships 2025.02, predating the regression); historical QEMU-side report
with a different root cause: https://gitlab.com/qemu-project/qemu/-/issues/1177

**Test Plan:**

1. Regression-free path check (CPU with ≤48-bit PARange):
       cp /usr/share/AAVMF/AAVMF_VARS.fd VARS.fd
       timeout 30 qemu-system-aarch64 -M virt,gic-version=3 -cpu cortex-a76 \
           -accel tcg,thread=multi -smp 2 -m 1024 \
           -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
           -drive if=pflash,format=raw,file=VARS.fd \
           -serial file:serial.log -monitor none -display none
   Expected (before and after the fix): guest reaches the BdsDxe
   "Press any key to enter the Boot Manager Menu." prompt (≥254 bytes of
   serial output).

2. Fixed-path check (LPA2-capable CPU):
       … same command with `-cpu max` …
   Before the fix: serial output stops at 77 bytes (version banner) and the
   guest hangs. After the fix: the guest reaches the boot manager / PXE
   (≥174 bytes) and boots normally from disk or network.

3. Full-boot smoke test: boot an arm64 cloud/subiquity image end-to-end with
   `-cpu max`.

4. If an arm64 host is available: KVM smoke test with `-cpu host` (the same
   firmware path is exercised on 52-bit-PA hardware).
