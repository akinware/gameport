#if os(macOS)
import SwiftUI
import GamePortKit

/// Saved states of a profile to roll back to after an update breaks the game.
struct SnapshotsView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    @State private var confirmRestore: Snapshot?

    var body: some View {
        let snapshots = model.gameport.profiles.listSnapshots(profile.id)
        GroupBox("Snapshots") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saves the game's state before Steam and game updates, so you can go back if something breaks. One is taken automatically the first time Steam starts each day.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save now") {
                        model.job("Snapshot") { k, _ in "Saved \(try k.snapshot(profile.id).name)" }
                    }.disabled(model.busy != nil)
                    Toggle("Daily automatic", isOn: Binding(
                        get: { profile.autoSnapshots ?? true },
                        set: { on in
                            var p = profile
                            p.autoSnapshots = on
                            try? model.gameport.profiles.save(p)
                            model.refresh()
                        }))
                }
                ForEach(snapshots, id: \.name) { s in
                    HStack {
                        Image(systemName: s.name.hasPrefix(ProfileStore.autoPrefix) ? "clock.arrow.circlepath" : "bookmark")
                        Text(s.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text(s.name).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button("Restore") { confirmRestore = s }.disabled(model.busy != nil)
                        Button(role: .destructive) {
                            model.job("Deleting snapshot") { k, _ in try k.profiles.deleteSnapshot(profile.id, name: s.name); return "Deleted \(s.name)" }
                        } label: { Image(systemName: "trash") }.disabled(model.busy != nil)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
        .confirmationDialog("Restore this snapshot?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            presenting: confirmRestore) { s in
            Button("Restore", role: .destructive) {
                model.job("Restoring") { k, _ in try k.restore(profile.id, snapshot: s.name); return "Restored \(s.name)" }
            }
        } message: { s in
            Text("Everything since \(s.createdAt.formatted()) (downloads, saves, settings) will be lost.")
        }
    }
}
#endif
