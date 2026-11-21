#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GamePortKit

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLicense = false
    @State private var showTelemetryPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Setup").font(.largeTitle.bold())
                GroupBox("System") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.checks, id: \.name) { c in
                            Label("\(c.name): \(c.detail)", systemImage: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(c.ok ? Color.primary : Color.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                GroupBox("Engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let m = model.gameport.defaultManifest {
                            Text(m.displayName).font(.headline)
                            Text("Wine, runtime libraries and renderers. Every part is verified with SHA-256. About 440 MB.")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(model.engines.contains(m.id) ? "Reinstall" : "Install engine") {
                                    model.job("Engine install") { k, p in try await k.installDefaultEngine(progress: p).id }
                                }.disabled(model.busy != nil)
                                if model.engines.contains(m.id) { Label("Installed", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                                Button("Install from manifest…") {
                                    let panel = NSOpenPanel()
                                    panel.allowedContentTypes = [.json]
                                    panel.message = "Choose a trusted GamePort engine manifest."
                                    guard panel.runModal() == .OK, let url = panel.url else { return }
                                    model.job("Installing engine") { k, p in
                                        try await k.engines.install(EngineManifest.load(url), progress: p).id
                                    }
                                }.disabled(model.busy != nil)
                            }
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
