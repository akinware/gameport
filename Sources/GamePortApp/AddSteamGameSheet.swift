#if os(macOS)
import SwiftUI
import GamePortKit

struct AddSteamGameSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    @State var query: String
    @State private var renderer: Renderer = .dxmt
    @State private var results: [SteamStore.SearchResult] = []
    @State private var searching = false
    @State private var errorMessage: String?
    let onAdded: (Recipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add any Steam game").font(.title2.bold())
            Text("Search Steam by name or paste any Steam Store URL or App ID — even games never tested on Mac before.")
                .foregroundStyle(.secondary)

            HStack {
                TextField("Game name, Steam URL, or App ID", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button(searching ? "Searching…" : "Search") { runSearch() }
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Picker("Starting renderer", selection: $renderer) {
                Text("DXMT (D3D10/11 — best default)").tag(Renderer.dxmt)
                Text("D3DMetal (DirectX 12)").tag(Renderer.d3dmetal)
                Text("DXVK (DirectX 9 / Vulkan)").tag(Renderer.dxvk)
            }
            .pickerStyle(.menu)

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            List(results) { item in
                let antiCheat = AntiCheatDB.bundled.entry(steamAppID: item.id)
                let existing = model.gameport.catalog.recipe(steamAppID: item.id)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.headline)
                        HStack(spacing: 6) {
                            Text("Steam · \(item.id, format: .number.grouping(.never))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let antiCheat {
                                Text(antiCheat.risk == .blocked ? "Anti-cheat blocks Mac" : "Online anti-cheat warning")
                                    .font(.caption.bold())
                                    .foregroundStyle(antiCheat.risk == .blocked ? Color.red : Color.orange)
                            }
                        }
                    }
                    Spacer()
                    Button(existing != nil ? "Open" : "Add") { add(item) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 220)

            HStack {
                if let directID = SteamStore.parseAppID(query), results.isEmpty {
                    Button("Add App ID \(directID) directly") {
                        add(SteamStore.SearchResult(id: directID, name: "Steam Game \(directID)"))
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 560, height: 470)
        .onAppear {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runSearch() }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        errorMessage = nil
        Task {
            do {
                let found = try await SteamStore.search(q)
                await MainActor.run {
                    results = found
                    if found.isEmpty { errorMessage = "No Steam games found for \"\(q)\". Try pasting the Steam App ID or Store URL." }
                    searching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Could not reach Steam Store (\(error.localizedDescription)). You can still enter a numeric Steam App ID."
                    searching = false
                }
            }
        }
    }

    private func add(_ item: SteamStore.SearchResult) {
        do {
            let recipe = try model.gameport.addCustomSteamGame(appID: item.id, title: item.name, renderer: renderer)
            model.refresh()
            model.say("✓ Ready: \(recipe.title) (Steam \(item.id))")
            onAdded(recipe)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
