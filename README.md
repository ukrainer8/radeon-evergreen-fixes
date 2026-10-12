# radeon-uvd-resume-fix

**Fix for AMD Evergreen / Northern Islands GPUs (radeon driver) losing UVD (hardware video
decode) after suspend/resume: `radeon: ring 5 test failed (0xCAFEDEAD)` → `failed initializing UVD (-22)`.**

Shipped as a **DKMS package** — the patched `radeon.ko` rebuilds itself automatically on every
kernel update. Tested on Linux Mint 22.3 (Ubuntu noble base), kernel 7.0.0-38, Radeon HD 5650M
(Madison, 1002:68c1). Should work on any distro with DKMS where the GPU is driven by `radeon`
(HD 5000/6000 series and APUs of that era: Evergreen, Redwood, Cedar, Caicos, Turks, RS880 etc.).

## Symptoms this fixes

- After suspend-to-RAM or hibernate, hardware video decode (VA-API/VDPAU, UVD) is gone until reboot.
- `dmesg` shows `radeon: ring 5 test failed (0xCAFEDEAD)` and `failed initializing UVD (-22)` on resume.
- Cold boot always works; resume is a coin flip (~50% on our test machine, 42 measured cycles).

Known upstream, never fixed (radeon is in maintenance mode):
[drm/amd#1867](https://gitlab.freedesktop.org/drm/amd/-/issues/1867),
[Launchpad #1865130](https://bugs.launchpad.net/bugs/1865130).

## Root cause

The resume path runs the same full `evergreen_startup()` as cold boot, so nothing is "forgotten"
at the function-call level. What differs is the hardware state at entry: after PCI D3 + ASIC reset,
the UVD ring buffer controller intermittently isn't ready when the single-shot ring test fires
(~100 ms window). The stock driver tries once and gives up for the whole session.

## The patch

`drivers/gpu/drm/radeon/uvd_v1_0.c::uvd_v1_0_init()` — on failure of any init step
(clock setup → VCPU start → ring test), do a full `uvd_v1_0_stop()` + 20 ms settle + retry,
up to 3 attempts, with `drm_warn` diagnostics per attempt. On healthy hardware the first attempt
succeeds and behaviour is unchanged; the retry only fires where the stock driver would have
declared UVD dead.

Measured on the test machine: **stock 5/6, 3/6, 6/6, 2/6, 1/6 OK across runs (~50% median) →
patched 6/6**, with the log showing the retry catching failures on attempt 2–3.

Raw patch for reviewers/upstream: [`patch/uvd_v1_0-retry.patch`](patch/uvd_v1_0-retry.patch).

## Install (DKMS)

```bash
sudo apt install dkms linux-headers-$(uname -r)     # Debian/Ubuntu/Mint
sudo cp -r radeon-uvd-resume-fix /usr/src/radeon-uvd-retry-1.0   # clone or unpack this repo
sudo dkms add radeon-uvd-retry/1.0
sudo dkms build radeon-uvd-retry/1.0
sudo dkms install radeon-uvd-retry/1.0
# verify: modinfo -n radeon should point into updates/dkms/
```

The patched module loads on the next reboot. Kernel updates rebuild it automatically
(`/etc/kernel/postinst.d/dkms` hook, `AUTOINSTALL="yes"`).

### Uninstall / rollback

```bash
sudo dkms remove radeon-uvd-retry/1.0 --all && sudo depmod -a
```

Stock driver takes over again; nothing else is touched. If a future kernel ever breaks the build,
the system simply boots with the stock driver (fail-safe direction).

## Verify it works on your machine

`tools/radeon-uvd-test.sh` is the automated test stand used to prove the fix: boots into a
console-only mode, loads the patched module, runs N suspend/resume cycles via `rtcwake`, and
prints a SUMMARY line with OK/FAIL counts. It double-checks module identity via `srcversion`
so a wrong module can never produce a false pass. See comments at the top of the script.
Caution: it reboots the machine by design — read it before running.

If you own a different Evergreen/NI card, run the stand and share your before/after numbers —
that's the data that gets this upstream.

## Scope and honest limits

- Only GPUs on the legacy `radeon` driver (pre-HD 7000). HD 7000+ use `amdgpu` — different driver, different story.
- The patch changes resume-time init only; it does not improve performance and does not touch 3D.
- UVD on these chips handles MPEG-2/VC-1/H.264 — no VP9/HEVC/AV1 (hardware never had it).

## License

GPL-2.0 (derived from the Linux kernel `radeon` driver). See [LICENSE](LICENSE).
AMD/ATI trademarks belong to AMD; this is an independent community fix, not affiliated with AMD.

## Credits

Diagnosis and patch developed with kernel-source analysis of the `radeon` UVD resume path,
community bug reports (#1867, fdo#67276, LP#1865130), and automated suspend-cycle testing.
