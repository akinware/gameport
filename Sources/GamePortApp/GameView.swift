#if os(macOS)
import SwiftUI
import GamePortKit

struct GameView: View {
    @EnvironmentObject var model: AppModel
    let recipe: Recipe
    let openSetup: () -> Void
    @State private var selectedProfileID: String?
    @State private var newEngineID: String?
    @State private var advanced = false

    var body: some View {
        let choices = model.engineProfiles[recipe.id] ?? []
        let profile = choices.first { $0.id == selectedProfileID } ?? choices.first
        let evidence = model.evidence(for: recipe, profile: profile)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GameHeader(recipe: recipe)
                CompatibilityCard(evidence: evidence, antiCheat: AntiCheatDB.bundled.entry(for: recipe))
                if choices.count > 1, let profile {
                    Picker("Play profile", selection: Binding(get: { profile.id }, set: { selectedProfileID = $0 })) {
                        ForEach(choices) { Text("\($0.id) · \($0.engineID)").tag($0.id) }
                    }
                }
                PlayGuideView(recipe: recipe, profile: profile,
                              newEngineID: newEngineID, openSetup: openSetup)
                    .id(profile?.id)
                if !recipe.knownIssues.isEmpty {
                    GroupBox("Known issues") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(recipe.knownIssues, id: \.symptom) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.symptom).bold()
                                    if let cause = issue.cause { Text(cause).foregroundStyle(.secondary) }
                                    if let fix = issue.fix { Text(fix) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                if !recipe.notes.isEmpty {
                    GroupBox("Game notes") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(recipe.notes, id: \.self) { Text($0) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    if advanced {
                        AdvancedView(recipe: recipe, profile: profile, choices: choices, newEngineID: $newEngineID)
                            .padding(.top, 8)
                    }
                }
            }.padding(24)
        }
    }
}
#endif
