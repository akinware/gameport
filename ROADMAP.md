# GamePort Roadmap

## Current Status

GamePort has a working macOS SwiftUI app, CLI, and core library running on the `x64-crossover26.3-hb20261014` engine (Wine 11 under Rosetta):

- **Done:**
  - Per-game isolated Wine prefixes (`Z:` drive removed), SHA-256 verified engine installer, D3DMetal license gate.
  - APFS copy-on-write Steam base (`gameport base build`) and manual + daily automatic snapshots with rollback.
  - Compatibility Lab (`gameport lab`, `lab auto`) with Metal HUD FPS parsing, per-process filtering (game only, ignoring Steam), crash detection, occluded-window checks, and pre-download evidence badges.
  - Pre-download anti-cheat warnings (1,166 games).
  - Patched DXVK (`Patches/dxvk/`, `Scripts/build-dxvk.sh`) fixing the D3D11 pipeline-statistics crash on MoltenVK.
  - Experimental KosmicKrisp Vulkan 1.4 shim (`Tools/kosmickrisp-shim/`) selectable per profile (`gameport vulkan <profile> kosmickrisp`); Team Fortress 2 (D3D9 via DXVK) renders on it (182 FPS typical on M1).
- **Current recipe status (795 bundled):** 1 `verified` (`team-fortress-2`), 791 `community`, 3 `untested` (`3dmark-demo`, `age-of-empires-2-de`, `path-of-exile-2`).

---

## Track A — More Games Working Smoothly & UX

Goal: Make GamePort feel effortless across a wide library of Windows games with trustworthy, measured recipes.

1. **Scale the recipe catalog (CC0 import + verification):**
   - The pinned CC0 import added 774 Steam recipes. `Scripts/import-recipes.py` combines curated records in `db/games` with portable settings from `recipes/games`, skips blocked titles, and preserves existing recipes by ID and Steam app ID. Imported titles stay at `community` pending GamePort Lab verification.
   - Verify and tune a priority set of popular titles end-to-end (`elden-ring`, `cyberpunk-2077`, `skyrim-se`, `risk-of-rain-2`, `the-witcher-3`, `red-dead-redemption-2`, `counter-strike-2`, `peak`, etc.), recording chip, macOS version, engine, and FPS provenance.
   - Revisit `skyrim-se` and `peak` defaults: both currently default to `dxvk`, which crashes on stock engine DXVK unless `Scripts/build-dxvk.sh` has been run. Either ship the patched DXVK as part of the engine override flow or document/default safely.
2. **Per-game config & launch polish:**
   - Optional safe config helpers for common Mac pitfalls (e.g., borderless window mode, disabling unsupported ray tracing, display-capture defaults for OpenGL titles, SDL/hidraw controller defaults) without overwriting user saves or custom settings.
   - Better Steam first-run guidance and progress feedback in `GamePortApp` (clearer states when Steam is updating, downloading, or launching).
3. **Lab v2 (stronger automated verdicts):**
   - Add ScreenCaptureKit-based black-frame / frozen-frame checks alongside Metal HUD FPS and crash-log signals.
   - Record thermal state and 1% low FPS (`MTL_HUD_REPORT_URL` / HUD log) so comparisons on fanless Macs aren't skewed by throttling.
   - Add a clean foreground warm-cache TF2 comparison between MoltenVK and KosmicKrisp.
4. **App polish & distribution:**
   - Move from `Scripts/make-app.sh` to an Xcode app target (enabling `Localizable.xcstrings` String Catalogs, app icon, and proper entitlements).
   - Developer ID signing, hardened runtime, notarized DMG, Sparkle 2 auto-updates, and Homebrew cask.
   - Close the known removable-volume isolation gap (Wine re-exposing mounted USB/DMGs as `D:`, `E:`, …) via a Wine patch when GamePort ships its own engine build.

---

## Track B — Open DirectX 12 & Post-Rosetta ARM64 Engine

Goal: Remove dependence on Apple's x86_64-only D3DMetal and keep GamePort working when macOS 28 restricts Rosetta.

1. **First open DirectX 12 baseline (`research_notes/open-dx12-path.md`):**
   - Run `3dmark-demo` (Time Spy, D3D12) in the Lab with the `dxmt` renderer (leaving `d3d12` to Wine's built-in `vkd3d` 1.18) on **MoltenVK** first, then on **KosmicKrisp** via `Tools/kosmickrisp-shim/try.sh`.
   - Log missing Vulkan features / descriptor limits and compare against D3DMetal.
2. **Evaluate `vkd3d-proton` over KosmicKrisp:**
   - Build `vkd3d-proton` with the same `llvm-mingw` toolchain used in `Scripts/build-dxvk.sh` and test against DirectX-Graphics-Samples and real D3D12 games.
   - Promote KosmicKrisp from local script (`Tools/kosmickrisp-shim/install.sh`) to an optional SHA-256-pinned engine component once stable.
3. **Post-Rosetta ARM64 engine (macOS 26.5+ / macOS 28 readiness):**
   - Prerequisite: Paid Apple Developer account and `com.apple.developer.cross-architecture-support` entitlement (prototype with `-unmanaged` meanwhile).
   - Build dual-engine support: native `aarch64`/`arm64ec` Wine 11 + FEX (`xtajit64.dll` / `xtajit.dll`) + ARM64 DXMT + ARM64X d9vk, with per-profile engine selection and Rosetta fallback on macOS 26/27.
   - Use the Lab to publish real FEX-vs-Rosetta benchmarks per game.

---

## Non-Goals

- Anti-cheat bypasses or workarounds.
- Hosting, mirroring, or modifying Apple's D3DMetal or the Windows Steam client.
- Copying code from GPL-3 or closed-source launchers.
