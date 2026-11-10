# SRU checklist — edk2 LPA2 early-ID-map fix for resolute (26.04)

All paths are relative to this repository (`aavmf-lpa2-tcr-hang`).
Patch verification status: **applies cleanly to pristine edk2-stable202511**
(the Ubuntu package base); the patched result is byte-identical to
edk2-stable202605 for `ArmPlatformHelper.S` and differs from it in exactly
one line for `IdMap.S` (the unrelated `.section` attribute change from
interim upstream commit 2eed2bf8f007, intentionally not included).

## 0. Pre-flight

- [ ] Check with dannf / Hector Cao that no one else is preparing this SRU
      (Debian bug #1124749, edk2#11962 are the tracking items; no LP bug
      exists yet as of 2026-11-10).
- [ ] 7.4 is currently in resolute-proposed (LP: #2169887, unrelated).
      Prefer preparing **7.5 based on 7.4 after it migrates to -updates**
      (avoids touching someone's in-flight SRU). If urgency demands, ask
      Hector whether to fold it into 7.4 before migration instead.

## 1. File the Launchpad bug

- File against source package `edk2`, resolute task, using
  `launchpad-bug-draft.md` (fill in the LP bug number where the changelog
  says `LP: #XXXXXXX`).
- Tag: `arm64`, `aa-done`/`block-proposal` as appropriate; link
  https://github.com/tianocore/edk2/issues/11962 and
  https://bugs.debian.org/1124749.

## 2. Prepare the upload

```
pull-lp-source edk2 resolute          # or resolute-proposed once 7.4 migrates
cd edk2-2025.11
cp <repo>/sru/ArmVirtPkg-ArmPlatformLibQemu-Support-early-ID-map-on-LPA2.patch \
   debian/patches/
echo ArmVirtPkg-ArmPlatformLibQemu-Support-early-ID-map-on-LPA2.patch \
     >> debian/patches/series
# merge the entry from <repo>/sru/changelog-entry.txt into debian/changelog
# (dch will normalise the timestamp), replacing LP: #XXXXXXX with the real
# bug number
```

Sanity checks before building:
- [ ] `patch --dry-run` clean (already verified against pristine 2025.11 for
      these two files; Ubuntu's patch queue touches no ArmVirtPkg files).
- [ ] `debian/rules override_dh_auto_build` unaffected; no new build-deps.

## 3. Build

```
sbuild -d resolute --arch-all --no-run-lintian   # or a PPA build
```

The firmware binaries (qemu-efi-aarch64 etc.) are Architecture: all; the
source builds on any builder (cross toolchain is used internally).

## 4. Verify the built firmware (deterministic)

Use the scripts in the repo root:

```
./reproduce.sh <built>/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
```

Expected with the fixed build:
- `-cpu max`       → ≥174 bytes of serial output, reaches `>>Start PXE over
  IPv4.` / BdsDxe (was: 77 bytes, silent hang)
- `-cpu cortex-a76` and friends → unchanged (≥254 bytes, BdsDxe prompt)
- `./verify-tcr-write-experiment.sh` is not needed for the SRU (it only
  demonstrates the mechanism on the *unpatched* firmware).

Also run the full-boot smoke test from the Launchpad bug Test Plan (arm64
cloud image with `-cpu max`), and a KVM smoke test on an arm64 host if
available (52-bit-PA hardware is where KVM guests are affected too).

## 5. Upload

- PPA first for the SRU reviewers if preferred; then upload to
  resolute-proposed with the BugLink in the changelog.
- Subscribe ubuntu-archive (or your SRU sponsor).
- Once in -proposed: re-run step 4 against the -proposed binaries, mark the
  bug `verification-done`/`verification-failed` accordingly.

## Notes

- The patch is upstream commit b8df7d9c8e1e verbatim except one context line
  (`.section  ".rodata.idmap", "a", %progbits` retained; upstream interim
  commit 2eed2bf8f007 dropped `%progbits` for CLANGPDB, which Ubuntu does not
  use). Do NOT include 2eed2bf8f007 — it is unrelated to the bug.
- The firmware only reaches VMs whose pflash points at /usr/share/AAVMF/;
  VMs with firmware copied into their own storage keep the old image (same
  as any edk2 SRU).
- Do not bump to edk2 stable202605/202608 wholesale in this SRU: the source
  package also builds OVMF/x86 and the secure-boot flavors, so a version
  bump is a much wider firmware regression surface than this one-commit fix.
