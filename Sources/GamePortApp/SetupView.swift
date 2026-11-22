#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GamePortKit

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLicense = false
    @State private var showTelemetryPreview = false
    @State private var authStorePrompt: StorefrontKind?
    @State private var authCodeInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Setup").font(.largeTitle.bold())
                if model.engines.isEmpty || model.steamBase == nil {
                    GroupBox {
                        HStack(alignment: .center, spacing: 16) {
                            Image(systemName: "sparkles")
                                .font(.title).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Get Ready in 1 Click").font(.headline)
                                Text("Automatically installs the recommended engine and prepares the shared Steam base — no Wine tinkering required.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.job("Guided setup") { k, p in try await k.guidedSetup(progress: p) }
                            } label: {
                                Label("Set up GamePort", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.busy != nil)
                        }.padding(6)
                    }
                }
                GroupBox("System") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.checks, id: \.name) { c in
                            Label("\(c.name): \(c.detail)", systemImage: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(c.ok ? Color.primary : Color.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Storage & External SSD") {
                    VStack(alignment: .leading, spacing: 8) {
                        let info = model.storageInfo
                        HStack(spacing: 8) {
                            Label("\(info.volumeName) · \(info.filesystem) · \(info.freeSpaceLabel)",
                                  systemImage: info.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                                .font(.headline)
                                .foregroundStyle(info.isAPFS ? Color.primary : Color.orange)
                        }
                        Text(info.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let warning = info.warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                        } else {
                            Text("Store games, engines, and APFS snapshots on an external APFS SSD to save internal Mac storage.")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Choose External SSD / Folder…") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                panel.message = "Choose a folder on an APFS drive (e.g. External SSD) for GamePort games and engines."
                                guard panel.runModal() == .OK, let chosen = panel.url else { return }
                                do {
                                    let updated = try StorageInfo.setCustomRoot(chosen)
                                    model.reloadStorage()
                                    model.say("✓ Storage set to \(updated.root.path) (\(updated.filesystem), \(updated.freeSpaceLabel))")
                                } catch {
                                    model.say("✗ \(error)")
                                }
                            }.disabled(model.busy != nil)
                            if info.isCustom {
                                Button("Reset to Internal") {
                                    _ = try? StorageInfo.resetToDefault()
                                    model.reloadStorage()
                                    model.say("✓ Storage reset to default internal folder")
                                }.disabled(model.busy != nil)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Engines") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Every engine component is verified with SHA-256. You can keep multiple Wine / CrossOver / ARM64 engines side-by-side and choose which one new games use.")
                            .foregroundStyle(.secondary)
                        ForEach(model.engineCatalog) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(entry.manifest.displayName).font(.headline)
                                    Text(entry.manifest.arch.label)
                                        .font(.caption.monospaced())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                    if entry.isDefault {
                                        Label("Default", systemImage: "star.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.blue)
                                    }
                                    if entry.isInstalled {
                                        Label("Installed", systemImage: "checkmark.seal.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.green)
                                    }
                                }
                                HStack(spacing: 12) {
                                    Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text("·").foregroundStyle(.secondary)
                                    Text("~\(entry.manifest.downloadSizeLabel)").font(.caption).foregroundStyle(.secondary)
                                    if entry.profilesUsingCount > 0 {
                                        Text("·").foregroundStyle(.secondary)
                                        Text("Used by \(entry.profilesUsingCount) \(entry.profilesUsingCount == 1 ? "game" : "games")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if entry.kosmicKrispInstalled {
                                        Text("· KosmicKrisp").font(.caption).foregroundStyle(.purple)
                                    }
                                }
                                HStack {
                                    if entry.isBundled {
                                        Button(entry.isInstalled ? "Reinstall" : "Install") {
                                            let manifest = entry.manifest
                                            model.job("Engine install (\(manifest.id))") { k, p in
                                                try await k.engines.install(manifest, progress: p).id
                                            }
                                        }.disabled(model.busy != nil)
                                    }
                                    if entry.isInstalled && !entry.isDefault {
                                        Button("Set as Default") {
                                            do {
                                                try model.gameport.engines.setDefaultEngine(entry.id)
                                                model.refresh()
                                                model.say("✓ Default engine set to \(entry.id)")
                                            } catch {
                                                model.say("✗ \(error)")
                                            }
                                        }.disabled(model.busy != nil)
                                    }
                                    if entry.isInstalled && entry.profilesUsingCount == 0 {
                                        Button("Remove", role: .destructive) {
                                            do {
                                                try model.gameport.removeEngine(entry.id)
                                                model.refresh()
                                                model.say("✓ Removed engine \(entry.id)")
                                            } catch {
                                                model.say("✗ \(error)")
                                            }
                                        }.disabled(model.busy != nil)
                                    }
                                }
                            }
                            if entry.id != model.engineCatalog.last?.id { Divider() }
                        }
                        Divider()
                        HStack {
                            Button("Install from manifest…") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.json]
                                panel.message = "Choose a trusted GamePort engine manifest (.json)."
                                guard panel.runModal() == .OK, let url = panel.url else { return }
                                model.job("Installing engine") { k, p in
                                    try await k.engines.install(EngineManifest.load(url), progress: p).id
                                }
                            }.disabled(model.busy != nil)
                            Text("Import community Wine, CrossOver, or ARM64/FEX manifests.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Steam base") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Installs and updates Windows Steam once. Every later game starts as a copy of this base, ready in seconds and using almost no disk; games still stay separate from each other. Nobody signs in to the base.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(model.steamBase == nil ? "Build Steam base" : "Rebuild") {
                                model.job("Steam base") { k, p in try await k.steamBase().build(progress: p); return "Steam base ready" }
                            }.disabled(model.engines.isEmpty || model.busy != nil)
                            if let stamp = model.steamBase {
                                Label("Ready · \(stamp.builtAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("GamePort Steam Bridge (Zero Windows Steam · Clean-Room)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Forwards Windows Steamworks calls (`steamclient64.dll` → `steamclient64.so`) directly to your untouched native Mac Steam (`steamclient.dylib`), without patching Steam.app or running Windows Steam in RAM. VAC multiplayer games automatically stay on isolated Windows Steam.")
                            .foregroundStyle(.secondary)
                        Label(
                            model.bridgeStatus.readinessSummary,
                            systemImage: model.bridgeStatus.isReadyToLaunch ? "checkmark.seal.fill" : "bolt.horizontal.circle"
                        )
                        .foregroundStyle(model.bridgeStatus.isReadyToLaunch ? .green : .secondary)
                        HStack(spacing: 10) {
                            Label(
                                model.bridgeStatus.overlayInstalled ? "Bridge DLL/SO built" : "Overlay not built",
                                systemImage: model.bridgeStatus.overlayInstalled ? "checkmark.circle.fill" : "circle"
                            ).font(.caption).foregroundStyle(model.bridgeStatus.overlayInstalled ? .green : .secondary)
                            Label(
                                model.bridgeStatus.steamClientDylib != nil
                                    ? (model.bridgeStatus.steamClientHasX86_64 ? "Mac steamclient.dylib (x86_64)" : "Mac steamclient.dylib (no x86_64)")
                                    : "Mac Steam not found",
                                systemImage: model.bridgeStatus.steamClientHasX86_64 ? "checkmark.circle.fill" : "exclamationmark.triangle"
                            ).font(.caption).foregroundStyle(model.bridgeStatus.steamClientHasX86_64 ? .green : .orange)
                            Label(
                                model.bridgeStatus.steamCmdInstalled ? "steamcmd ready" : "steamcmd not installed",
                                systemImage: model.bridgeStatus.steamCmdInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                            ).font(.caption).foregroundStyle(model.bridgeStatus.steamCmdInstalled ? .green : .secondary)
                        }
                        HStack {
                            if !model.bridgeStatus.steamCmdInstalled {
                                Button("Install Valve steamcmd") {
                                    model.job("Installing steamcmd") { k, p in
                                        try await k.steamDepot.install(progress: p)
                                        return "Valve steamcmd installed"
                                    }
                                }.disabled(model.busy != nil)
                            }
                            if model.bridgeStatus.overlayInstalled, let defaultEngine = model.installedEngines.first {
                                Button("Run Bridge Self-Test") {
                                    model.job("Probing Steam Bridge") { k, _ in
                                        let useMock = k.steamBridge.status().steamClientDylib == nil
                                        let res = try k.steamBridge.probe(engine: defaultEngine, mockMode: useMock)
                                        if res.success {
                                            return "Bridge OK on \(res.engineID) (\(useMock ? "mock" : "native Mac Steam"))"
                                        }
                                        throw GamePortError.process("Bridge probe", res.exitCode)
                                    }
                                }.disabled(model.busy != nil)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Epic Games, GOG & Heroic (Zero Store Launcher in RAM)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Downloads Windows games natively on macOS and launches them straight on CrossOver.app (0 MB) or GamePort PowerKit — no sluggish Windows Epic Launcher or GOG Galaxy running in the background.")
                            .foregroundStyle(.secondary)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Epic Games (legendary \(EpicStorefront.version))").font(.headline)
                                Text(model.epicInstalled
                                     ? (model.epicSignedIn ? "Signed in · ready to download & launch" : "Installed · click Sign In to link Epic")
                                     : "Native arm64 binary · SHA-256 verified (13.5 MB)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !model.epicInstalled {
                                Button("Install legendary") {
                                    model.job("Installing Epic legendary") { k, p in
                                        _ = try await k.epic.install(progress: p)
                                        return "Epic legendary installed"
                                    }
                                }.disabled(model.busy != nil)
                            } else if !model.epicSignedIn {
                                Button("Sign In to Epic") {
                                    NSWorkspace.shared.open(EpicStorefront.loginURL)
                                    authCodeInput = ""
                                    authStorePrompt = .epic
                                }.disabled(model.busy != nil)
                            } else {
                                Label("Connected", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                Button("Sign Out") {
                                    try? model.gameport.epic.signOut()
                                    model.refresh()
                                }.disabled(model.busy != nil)
                            }
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GOG (gogdl \(GOGStorefront.version) · DRM-Free)").font(.headline)
                                Text(model.gogInstalled
                                     ? (model.gogSignedIn ? "Signed in · ready to download DRM-free games" : "Installed · click Sign In to link GOG")
                                     : "Native arm64 binary · SHA-256 verified (11.1 MB)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !model.gogInstalled {
                                Button("Install gogdl") {
                                    model.job("Installing GOG gogdl") { k, p in
                                        _ = try await k.gog.install(progress: p)
                                        return "GOG gogdl installed"
                                    }
                                }.disabled(model.busy != nil)
                            } else if !model.gogSignedIn {
                                Button("Sign In to GOG") {
                                    NSWorkspace.shared.open(GOGStorefront.loginURL)
                                    authCodeInput = ""
                                    authStorePrompt = .gog
                                }.disabled(model.busy != nil)
                            } else {
                                Label("Connected", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                Button("Sign Out") {
                                    model.gameport.gog.signOut()
                                    model.refresh()
                                }.disabled(model.busy != nil)
                            }
                        }
                        if !model.storefrontGames.isEmpty {
                            Divider()
                            Text("Detected Epic / GOG / Heroic Games (\(model.storefrontGames.count))").font(.caption.bold())
                            ForEach(model.storefrontGames.prefix(10)) { game in
                                HStack {
                                    Text("\(game.title) · \(game.store.displayName)").font(.caption)
                                    Spacer()
                                    Button("Play") {
                                        model.job("Launching \(game.title)") { k, p in
                                            _ = try k.launchStorefrontGame(game, progress: p)
                                            return "Launched \(game.title)"
                                        }
                                    }.controlSize(.small).disabled(model.busy != nil)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                .sheet(item: $authStorePrompt) { kind in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(kind == .epic ? "Sign In to Epic Games" : "Sign In to GOG").font(.headline)
                        Text(kind == .epic
                             ? "Sign in on the Epic page that just opened in your browser, copy the `authorizationCode` value, and paste it below."
                             : "Sign in on the GOG page that just opened in your browser, copy the `code=` parameter from the final URL, and paste it below.")
                            .font(.callout).foregroundStyle(.secondary)
                        TextField("Authorization code", text: $authCodeInput).textFieldStyle(.roundedBorder)
                        HStack {
                            Spacer()
                            Button("Cancel") { authStorePrompt = nil }
                            Button("Connect") {
                                let code = authCodeInput
                                authStorePrompt = nil
                                model.job("Signing in to \(kind.displayName)") { k, _ in
                                    if kind == .epic { try k.epic.authenticate(authorizationCode: code) }
                                    else { try k.gog.authenticate(authorizationCode: code) }
                                    return "Signed in to \(kind.displayName)"
                                }
                            }.buttonStyle(.borderedProminent).disabled(authCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(20)
                    .frame(width: 440)
                }
                GroupBox("D3DMetal (Apple Game Porting Toolkit)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Most DirectX 12 games need D3DMetal. D3DMetal belongs to Apple and comes with its own licence, which you need to accept before it is used.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Read licence") { showLicense = true }
                            if model.gptkAccepted {
                                Label("Accepted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                Button("Revoke") { try? model.gameport.licenses.revoke("apple-gptk"); model.refresh() }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("External Launchers & Experimental Runners") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("x87sidecar (Rosetta x87 JIT Accelerator)").font(.headline)
                                    Text("MIT · 182 KB").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Speeds up legacy 32-bit/DX9 x87 floating-point math under Rosetta (classic Call of Duty, Half-Life 2, older PC games).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.x87Installed {
                                Label(model.x87Version ?? "Installed", systemImage: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
                                Button("Remove", role: .destructive) {
                                    try? model.gameport.x87sidecar.remove()
                                    model.refresh()
                                    model.say("✓ Removed x87sidecar")
                                }.disabled(model.busy != nil)
                            } else {
                                Button("Install x87sidecar") {
                                    model.job("Installing x87sidecar") { k, p in
                                        _ = try await k.x87sidecar.install(progress: p)
                                        return "x87sidecar installed"
                                    }
                                }.disabled(model.busy != nil)
                            }
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("AArchX (No-Rosetta Experimental Runner)").font(.headline)
                                    Text("LGPL-2.1 · 7.7 MB").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Optional x86-64 → arm64 JIT translator (ocerz / -fex) for macOS 26+ testing without Rosetta.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.aarchxInstalled {
                                Label(model.aarchxVersion ?? "Installed", systemImage: "checkmark.seal.fill")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
                                Button("Remove", role: .destructive) {
                                    try? model.gameport.aarchx.remove()
                                    model.refresh()
                                    model.say("✓ Removed AArchX")
                                }.disabled(model.busy != nil)
                            } else {
                                Button("Install AArchX") {
                                    model.job("Installing AArchX") { k, p in
                                        _ = try await k.aarchx.install(progress: p)
                                        return "AArchX installed"
                                    }
                                }.disabled(model.busy != nil)
                            }
                        }
                        Divider()
                        HStack {
                            Label(
                                model.externalEnv.hasObelisk
                                    ? "Obelisk: installed (available for Linux anti-cheat games like Rocket League)"
                                    : "Obelisk: not installed (optional for Linux-EAC games)",
                                systemImage: model.externalEnv.hasObelisk ? "checkmark.circle.fill" : "arrow.up.right.square"
                            )
                            .foregroundStyle(model.externalEnv.hasObelisk ? Color.primary : Color.secondary)
                            Spacer()
                            if let app = model.externalEnv.obeliskApp {
                                Button("Open Obelisk") { NSWorkspace.shared.open(app) }
                            } else if let url = URL(string: ExternalEnvironment.obeliskWebsite) {
                                Link("Get Obelisk…", destination: url)
                            }
                        }
                        HStack {
                            Label(
                                model.externalEnv.hasSiliconium
                                    ? "Siliconium: installed (tuned classic Call of Duty & Plutonium/IW4X/BOIII)"
                                    : "Siliconium: not installed (optional for classic CoD community servers)",
                                systemImage: model.externalEnv.hasSiliconium ? "checkmark.circle.fill" : "arrow.up.right.square"
                            )
                            .foregroundStyle(model.externalEnv.hasSiliconium ? Color.primary : Color.secondary)
                            Spacer()
                            if let app = model.externalEnv.siliconiumApp {
                                Button("Open Siliconium") { NSWorkspace.shared.open(app) }
                            } else if let url = URL(string: ExternalEnvironment.siliconiumWebsite) {
                                Link("Get Siliconium…", destination: url)
                            }
                        }
                        HStack {
                            let bottles = model.externalEnv.crossoverBottles.count
                            Label(
                                model.externalEnv.hasCrossOver
                                    ? "CrossOver: installed (\(bottles) \(bottles == 1 ? "bottle" : "bottles") detected)"
                                    : "CrossOver: not detected",
                                systemImage: model.externalEnv.hasCrossOver ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(model.externalEnv.hasCrossOver ? Color.primary : Color.secondary)
                            Spacer()
                            if let app = model.externalEnv.crossoverApp {
                                Button("Open CrossOver") { NSWorkspace.shared.open(app) }
                            }
                        }
                        HStack {
                            let games = model.externalEnv.macSteamGames.count
                            let np = model.externalEnv.notProtonInstalled ? " · NotProton detected" : ""
                            Label(
                                model.externalEnv.hasMacSteam
                                    ? "Mac Steam: installed (\(games) \(games == 1 ? "game" : "games") detected\(np))"
                                    : "Mac Steam: not detected",
                                systemImage: model.externalEnv.hasMacSteam ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(model.externalEnv.hasMacSteam ? Color.primary : Color.secondary)
                            Spacer()
                            if let app = model.externalEnv.macSteamApp {
                                Button("Open Mac Steam") { NSWorkspace.shared.open(app) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Community compatibility sharing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Share anonymous FPS & compatibility results", isOn: Binding(
                            get: { model.telemetryEnabled },
                            set: { on in
                                _ = try? model.gameport.telemetry.setEnabled(on)
                                model.refresh()
                            }
                        ))
                        Text("Crucial for smooth gaming: sharing anonymous FPS and crash verdicts lets GamePort learn which renderer runs best on M1–M4 Macs so games work without trial-and-error. Never sends your Steam account, username, file paths, or IP.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Preview data") { showTelemetryPreview = true }
                            Button("Reset anonymous ID") {
                                _ = try? model.gameport.telemetry.resetInstallID()
                                model.say("✓ Anonymous telemetry ID reset")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
            }.padding(24)
        }
        .sheet(isPresented: $showLicense) {
            if let license = model.gameport.defaultManifest?.licenses["apple-gptk"] {
                LicenseSheet(id: "apple-gptk", license: license)
            }
        }
        .sheet(isPresented: $showTelemetryPreview) {
            TelemetryPreviewSheet(json: model.gameport.telemetry.previewJSON())
        }
    }
}

struct TelemetryPreviewSheet: View {
    @Environment(\.dismiss) var dismiss
    let json: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What GamePort shares").font(.title2.bold())
            Text("Only anonymous compatibility metrics from Play and Lab sessions — no Steam ID, paths, usernames, or IP addresses.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(json).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500, height: 380)
    }
}

struct LicenseSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    let id: String
    let license: EngineManifest.License
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(license.title).font(.title2.bold())
            Text(license.summary)
            if let url = license.url.flatMap(URL.init(string:)) { Link("Read full licence", destination: url) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("I accept") {
                    do {
                        try model.gameport.licenses.accept(id)
                        model.refresh()
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520)
    }
}
#endif
