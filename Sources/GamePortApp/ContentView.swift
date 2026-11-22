#if os(macOS)
import SwiftUI
import GamePortKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String? = "setup"
    @State private var filter = RecipeFilter()
    @State private var showAddGame = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(Brand.displayName) {
                    Label("Setup", systemImage: "wrench.and.screwdriver").tag("setup")
                }
                Section("Games") {
                    Button { showAddGame = true } label: {
                        Label("Add any Steam game…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    Menu("Filter recipes", systemImage: "line.3.horizontal.decrease.circle") {
                        Picker("Status", selection: $filter.status) {
                            Text("All statuses").tag(nil as Recipe.Status?)
                            ForEach(Recipe.Status.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                        }
                        Picker("Renderer", selection: $filter.renderer) {
                            Text("All renderers").tag(nil as Renderer?)
                            ForEach(Renderer.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                        }
                    }
                    let matches = filter.apply(to: model.recipes)
                    if matches.isEmpty {
                        Text("No matching recipes").foregroundStyle(.secondary)
                        if !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Search Steam for \"\(filter.query)\"…") { showAddGame = true }
                        }
                    }
                    ForEach(matches) { r in
                        HStack {
                            EvidenceIcon(level: model.evidence(for: r, profile: model.profile(for: r)).level)
                            Text(r.title)
                            Spacer()
                            if model.profile(for: r) != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }.tag(r.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .searchable(text: $filter.query, placement: .sidebar, prompt: "Game, recipe ID or Steam ID")
            .sheet(isPresented: $showAddGame) {
                AddSteamGameSheet(query: filter.query) { recipe in
                    filter = RecipeFilter()
                    selection = recipe.id
                }
            }
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if selection == "setup" || selection == nil {
                        SetupView()
                    } else if let id = selection, let r = model.recipes.first(where: { $0.id == id }) {
                        GameView(recipe: r, openSetup: { selection = "setup" }).id(r.id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                LogView()
            }
        }
    }
}
#endif
