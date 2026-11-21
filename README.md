# GamePort

A macOS app that runs Windows games on Apple Silicon Macs.

Every game runs in its own isolated Windows environment: its own Wine prefix, its own Steam install and
its own HOME folder. The engine is read-only and shared, so a fix for one game can never break another.
Wine's Z: drive, which shows the whole Mac, is removed. Known gap: while a game runs, Wine shows mounted
removable volumes (USB disks, open DMGs) again as D:, E:, …; closing that needs a Wine patch.

## Quick start (Xcode)

1. Open `Package.swift` in Xcode.
2. Pick **GamePortApp** in the scheme menu and press ▶ Run.
3. In the app: **Setup → Install engine**. For games that use D3DMetal, read and accept Apple's licence.
4. Pick a game in the list: **Create the Windows environment → Install Windows Steam → Open Steam**
   (sign in, download the game) **→ Play**.

## Command line

```sh
swift build -c release
.build/release/gameport doctor
.build/release/gameport engine install
.build/release/gameport recipes
.build/release/gameport base build              # optional, once: the Steam base
.build/release/gameport profile create elden-ring
.build/release/gameport steam install elden-ring  # not needed with a Steam base
.build/release/gameport steam open elden-ring
.build/release/gameport play elden-ring
```

**Steam base.** Every profile installs Windows Steam and downloads its first update (~240 MB).
`gameport base build` does that once; every later profile is created as an APFS copy of the base in seconds,
using almost no disk. Profiles stay isolated: the copies split on first write. Nobody ever signs in to the
base; you sign in separately in each profile.

**Find a recipe.** Search by game name, recipe ID or Steam app ID in the sidebar or with
`gameport recipes`. Both support status and renderer filters. For example,
`gameport recipes fortress --status verified --renderer dxmt` lists matching verified DXMT recipes.

**Optional game settings.** After the game has created its settings folder, close the game and Steam.
Choose **Apply missing recipe settings** or run `gameport config <profile>`. Hogwarts Legacy includes
the optional AMD driver warning setting. GamePort adds missing keys to the game's UTF-8 INI file and
keeps a byte-for-byte backup beside each file it changes. The log names the backup. Recipe authors
can also supply named REG_SZ and REG_DWORD defaults under the game's Wine AppDefaults registry key.
Existing values take precedence on every run.

With the game and Steam closed, `gameport config <profile> controller` adds missing WineBus settings
for SDL controllers (SDL on, hidraw off). `gameport config <profile> opengl` disables Wine's fullscreen
display capture for OpenGL titles that blank the Mac display. Both presets act on the selected
profile only and preserve existing registry values, including those set by earlier GamePort releases.

**Snapshots.** Before a Steam, game or engine update, `gameport snapshot <profile>` saves the profile's state;
if something breaks, `gameport snapshot restore <profile> <name>` rolls it back. An automatic snapshot is taken
before Steam's first start each day (the newest two are kept; turn it off with
`gameport snapshot auto <profile> off`). Snapshots are APFS copies: a 34 GB profile is copied in 0.6 seconds
using a few MB.

**Lab.** `gameport lab <profile> [dxmt,dxvk,…] [seconds]` starts the game through Steam, measures FPS from
the Metal HUD log, decides whether it works and writes the result, with the Mac, macOS version and engine,
to `profiles/<profile>/lab/`. The profile is put back as it was afterwards. A run with the game window covered
counts as "not measured", unless the game process never started or the log shows a crash.
`gameport lab <profile> auto` ("Find the best renderer" in the app) tries DXMT, D3DMetal (once Apple's licence
is accepted) and DXVK in turn, and sets the profile to the one with the highest average FPS after warm-up
among those that worked to the end.

With macOS Screen Recording access enabled for GamePort (or your terminal for the CLI), the Lab
also samples the foreground game window every five seconds after warm-up. It discards each image
after computing its brightness and perceptual hash. A window that stays black for the final 20 seconds
is recorded as a black screen. An unchanged image with advancing HUD frames can be an idle menu or
a freeze. This result is inconclusive and cannot win automatic renderer selection. If capture is
unavailable, the Lab continues with its HUD and process checks.

The Lab reports 1% low FPS as 1000 divided by the 99th-percentile present interval in milliseconds.
It needs at least 100 unredacted frame intervals from the measured game in that phase of the run.
With redacted timings the frame counter still supplies average FPS and the slowest second.
The result also records the highest macOS thermal state sampled at launch, at 30-second intervals
and at the end. Crash findings distinguish Wine exceptions, Vulkan failures and Steam GPU restart loops.

**Compatibility sharing.** Enabled by default (switch off anytime in **Setup**, with `gameport telemetry off`, or `DO_NOT_TRACK=1`). During normal Play sessions and Lab runs, GamePort shares anonymous launch/crash verdicts, FPS (from Lab), chip, macOS version, renderer, and crash category codes — never your Steam account, username, paths, or IP — so GamePort learns which settings run games smoothly on Apple Silicon. Run `gameport telemetry preview` to inspect the exact JSON.

**Anti-cheat.** `gameport anticheat <game name|Steam id>` tells you before downloading whether a game's
anti-cheat blocks it on a Mac (1,166 games, highball-db / Are We Anti-Cheat Yet?, MIT). The app shows the same
information on the game's badge: kernel anti-cheat is "Will not run", anti-cheat that rejects Wine is
"Online play will most likely fail".

**Patched DXVK.** The engine's DXVK crashes in D3D11 games that use pipeline-statistics queries, which MoltenVK
does not support. `Scripts/build-dxvk.sh` builds DXVK with the patches in `Patches/dxvk/` on this Mac and installs
it for the DXVK renderer only (`--revert` undoes it). The build tools are downloaded to `~/Downloads/gameport-build`.

**KosmicKrisp (experimental).** On macOS 26 or later, select **Install KosmicKrisp for this engine** in the game's Lab
or run `gameport engine kosmickrisp <engine-id>`. GamePort verifies the architecture-specific Mesa download against its
SHA-256 pin, compiles the shim with Apple's Command Line Tools and installs it alongside the engine's MoltenVK.
Select it with the Lab's driver picker or `gameport vulkan <profile> kosmickrisp`. Steam keeps using MoltenVK.
Use `gameport vulkan <profile> moltenvk` to switch the game back.

### Compare a Rosetta and a FEX engine

The bundled engine uses x86_64 Wine under Rosetta. An engine packager can supply a native ARM64 Wine + FEX
build with its own signed binaries, required entitlements, guest modules and matching renderer libraries.
Choose **Install from manifest** in Setup or run `gameport engine install /path/to/manifest.json`. Each downloadable
component needs an HTTPS URL and SHA-256 digest. Set `arch` to `arm64`, declare the required `minMacOS`,
and point `fexModules.x64` and `fexModules.x86` at the packaged `xtajit64.dll` and `xtajit.dll`, relative to
the engine root. Set `supportsKosmicKrisp` only for loaders supporting `CX_LIBVULKAN` / `CX_ACTIVE_GRAPHICS_BACKEND`
with a matching `frameworks/libMoltenVK.dylib`. Use the DXMT or DXVK renderer for open D3D12 experiments.

```sh
gameport engine list
gameport profile create 3dmark-demo bench-rosetta --engine x64-crossover26.3-hb20261014
gameport profile create 3dmark-demo bench-fex --engine <installed-arm64-engine-id>
# Install Steam and the game in each profile before running the comparison.
gameport lab bench-fex compare bench-rosetta 180
gameport profile fallback bench-fex bench-rosetta
gameport play bench-fex
```

Each engine gets its own prefix, saves, Steam install and HOME. The Lab runs both copies in sequence using
the first profile's renderer, sync mode and Vulkan driver, and saves the engine ID and architecture with each
measurement. Play tries the configured alternate when engine preflight fails, before starting Steam. The
launch log identifies the chosen profile. Remove the fallback with `gameport profile fallback bench-fex off`.

### Build vkd3d-proton for a D3D12 experiment

Run `Scripts/build-vkd3d-proton.sh` on a Mac with Git, Python 3 and the Command Line Tools. It cross-compiles
the pinned upstream v3.1 revision with llvm-mingw and prints the directory containing the 64-bit Wine overlay.
For a dedicated DXMT/DXVK lab profile, add that directory as `WINEDLLPATH_PREPEND+` in the profile's
`environment` object and append `d3d12,d3d12core=n,b` to `WINEDLLOVERRIDES`. Remove those entries to return
to Wine's vkd3d. Upstream vkd3d-proton expects a compatible DXGI implementation and Vulkan features.
GamePort's shipping DXVK 1.10 predates upstream's DXVK 2.1+ integration. Record the result for the specific
game, engine and driver before treating this path as playable. [Upstream requirements](https://github.com/HansKristian-Work/vkd3d-proton/tree/v3.1#using-vkd3d-proton)

`Scripts/make-app.sh` builds a double-clickable `GamePort.app`.

## Languages

English is the source language. UI strings are SwiftUI string literals, ready to be extracted into a String
Catalog (`Localizable.xcstrings`) when other languages are added. The catalog is not in the package yet:
SwiftPM would put it in a resource bundle that SwiftUI does not read by default and that `make-app.sh` does not
copy, so it comes with the move to an Xcode app target.

## Roadmap & Contributing

Contributions, verified game recipes, and bug fixes are welcome! See [ROADMAP.md](ROADMAP.md) for current status and next milestones, [AGENTS.md](AGENTS.md) for codebase orientation, and [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Layout

| Folder | Contents |
| --- | --- |
| `Sources/GamePortKit` | Core: engine manager, profiles, renderer choice, recipes, Steam, lab |
| `Sources/gameport` | Command-line tool |
| `Sources/GamePortApp` | SwiftUI app |
| `Data/engines` | Engine manifests (every component: URL + SHA-256) |
| `Data/recipes` | Game recipes. After editing: `python3 Scripts/embed-data.py` |
| `Data/anticheat` | Anti-cheat map (MIT), imported by `Scripts/import-anticheat.py` |
| `Patches/dxvk` | GamePort's DXVK patches |
| `Tests` | Unit tests (`swift test`) |

Data: `~/Library/Application Support/GamePort` (override with `GAMEPORT_HOME`). Deleting this folder is a full uninstall.

## Licences

GamePort is free for personal and non-commercial use under the **PolyForm Noncommercial License 1.0.0** (`LICENSE`); contribution guidelines are in `CONTRIBUTING.md`.
The app downloads third-party components and runs them as separate programs; their own licences apply
(LGPL for Wine and DXMT, Apple's licence for D3DMetal): details in `THIRD_PARTY_NOTICES.md`.
