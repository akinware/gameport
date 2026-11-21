#if os(macOS)
import AppKit
import SwiftUI
import GamePortKit

struct AdvancedView: View {
    @EnvironmentObject var model: AppModel
    let recipe: Recipe
    let profile: Profile?
    let choices: [Profile]
    @Binding var newEngineID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Renderer", value: (profile?.renderer ?? recipe.renderer).displayName)
            LabeledContent("Sync", value: (profile?.sync ?? recipe.sync).rawValue)
            if let profile {
                LabeledContent("Engine", value: profile.engineID)
                let unused = model.engines.filter { engine in !choices.contains { $0.engineID == engine } }
                if !unused.isEmpty {
                    Menu("Create profile on another engine") {
                        ForEach(unused, id: \.self) { engine in
                            Button(engine) {
                                let id = String(recipe.id.prefix(60)) + "-" + UUID().uuidString.prefix(8).lowercased()
                                model.job("Creating \(id)") { k, p in
                                    try k.createProfile(recipeID: recipe.id, profileID: id, engineID: engine, progress: p).id
                                }
                            }
                        }
                    }.disabled(model.busy != nil)
                }
                HStack {
                    Button("Stop game and Steam") {
                        model.job("Stopping") { k, _ in try k.stop(profile.id); return "Stopped" }
                    }.disabled(model.busy != nil)
                    Button("Show logs") { NSWorkspace.shared.open(model.gameport.profiles.logs(profile.id)) }
                }
                if recipe.configDefaults != nil {
                    Button("Apply missing recipe settings") {
                        model.job("Recipe settings") { k, p in
                            try k.applyConfigDefaults(profile.id, progress: p)
                            return "Recipe settings checked"
                        }
                    }
                    .disabled(model.busy != nil)
                    .help("Close the game and Steam first. Existing settings are kept.")
                }
                Menu("Apply Wine defaults") {
                    ForEach(ConfigPatcher.WineDefault.allCases, id: \.self) { setting in
                        Button(setting.title) {
                            model.job(setting.title) { kit, _ in
                                try kit.applyWineDefault(setting, to: profile.id)
                                return "Missing defaults applied. Existing settings kept."
                            }
                        }
                    }
                }
                .disabled(model.busy != nil)
                .help("Close the game and Steam before changing settings.")
                if recipe.steamAppID != nil { LabView(profile: profile) }
                SnapshotsView(profile: profile)
            } else if model.engines.count > 1 {
                Picker("Engine for new profile", selection: $newEngineID) {
                    Text("Default").tag(nil as String?)
                    ForEach(model.engines, id: \.self) { Text($0).tag(Optional($0)) }
                }
            }
            if let source = recipe.source { Text("Source: \(source)").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
#endif
