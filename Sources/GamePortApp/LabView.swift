#if os(macOS)
import SwiftUI
import GamePortKit

/// Runs `gameport lab` for the game and shows what earlier runs measured, with the Mac and engine.
struct LabView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    var body: some View {
        let results = model.gameport.profiles.labResults(profile.id)
        GroupBox("Lab") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Runs the game for 3 minutes, measures FPS from the Metal HUD and records whether it works. Keep the game window in front while it measures.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Test") {
                        model.job("\(profile.title): lab") { k, p in try await k.lab(profile.id, progress: p).summary }
                    }.disabled(model.busy != nil)
                    Button("Find the best renderer") {
                        model.job("\(profile.title): renderer comparison") { k, p in
                            let (best, _) = try await k.findBestRenderer(profile.id, progress: p)
                            return best.map { "Best: \($0.renderer.displayName); the profile now uses it" } ?? "None was measured working; the profile is unchanged"
                        }
                    }.disabled(model.busy != nil)
                    .help("Tries each renderer for 3 minutes (6-9 minutes in all) and picks the fastest one that works.")
                }
                let peers = (model.engineProfiles[profile.recipeID ?? ""] ?? []).filter { $0.engineID != profile.engineID }
                if !peers.isEmpty || profile.fallbackProfileID != nil {
                    Picker("Fallback if engine is unavailable", selection: Binding(get: { profile.fallbackProfileID }, set: { other in
                        model.job("Changing fallback") { k, _ in try k.setFallback(profile.id, to: other); return nil }
                    })) {
                        Text("Off").tag(nil as String?)
                        ForEach(peers) { other in Text("\(other.id) · \(other.engineID)").tag(Optional(other.id)) }
                    }.disabled(model.busy != nil)
                    if !peers.isEmpty {
                        Menu("Compare engines") {
                            ForEach(peers) { other in
                                Button("\(other.id) · \(other.engineID)") {
                                    model.job("Engine comparison") { k, p in
                                        _ = try await k.compareEngines(profile.id, with: other.id, progress: p)
                                        return "Both measurements saved"
                                    }
                                }
                            }
                        }.disabled(model.busy != nil)
                    }
                }
                let engine = try? model.gameport.engines.engine(profile.engineID)
                if engine?.kosmicKrispShim != nil {
                    Picker("Vulkan driver", selection: Binding(
                        get: { profile.vulkanDriver ?? .moltenvk },
                        set: { driver in
                            var p = profile
                            p.vulkanDriver = driver == .moltenvk ? nil : driver
                            try? model.gameport.profiles.save(p)
                            model.refresh()
                        })) {
                        ForEach(VulkanDriver.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .fixedSize()
                    .help("Used by DXVK (Direct3D 9/10/11) and vkd3d (Direct3D 12). KosmicKrisp is Mesa's open Vulkan driver on Metal; only the game uses it.")
                } else if engine?.supportsKosmicKrisp == true {
                    Button("Install KosmicKrisp for this engine") {
                        model.job("Installing KosmicKrisp") { k, p in
                            try await k.engines.installKosmicKrisp(profile.engineID, progress: p)
                            return nil
                        }
                    }
                    .disabled(model.busy != nil || Shell.macOSVersion.majorVersion < 26)
                    .help("Requires macOS 26 and Apple's Command Line Tools.")
                }
                ForEach(results.prefix(5), id: \.startedAt) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(r.summary, systemImage: r.verdict == .works ? "checkmark.circle.fill" : r.verdict == .notVisible ? "eye.slash" : "exclamationmark.triangle.fill")
                            .foregroundStyle(r.verdict == .works ? Color.green : r.verdict == .notVisible ? Color.secondary : Color.orange)
                        Text("\(r.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(r.machine) · macOS \(r.macOS) · \(r.engineID)\(r.engineArchitecture.map { " · " + $0.label } ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}
#endif
