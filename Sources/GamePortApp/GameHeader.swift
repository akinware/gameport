#if os(macOS)
import SwiftUI
import GamePortKit

struct GameHeader: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12))
                Image(systemName: "gamecontroller.fill")
                    .font(.largeTitle).foregroundStyle(.secondary)
                if let url = recipe.steamHeaderURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                    .id(url)
                }
            }
            .frame(width: 184, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let appID = recipe.steamAppID {
                    Text("Steam · \(appID, format: .number.grouping(.never))").foregroundStyle(.secondary)
                }
                if let version = recipe.minMacOS {
                    Text("Requires macOS \(version) or later").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct CompatibilityCard: View {
    let evidence: Evidence
    let antiCheat: AntiCheatEntry?

    var body: some View {
        GroupBox("Compatibility") {
            HStack(alignment: .top, spacing: 12) {
                EvidenceIcon(level: evidence.level).font(.title2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(evidence.title).font(.headline)
                    if let detail = evidence.detail, !detail.isEmpty {
                        Text(detail).foregroundStyle(.secondary)
                    }
                    if let antiCheat {
                        // Evidence normally includes the anti-cheat verdict. A blocked recipe
                        // can give a different reason; keep the anti-cheat warning visible too.
                        if evidence.detail?.contains(antiCheat.summary) != true {
                            Text(antiCheat.summary).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No anti-cheat report in the catalog.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

struct EvidenceIcon: View {
    let level: Evidence.Level
    var body: some View {
        switch level {
        case .labWorks: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .verified: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .community: Image(systemName: "person.2.fill").foregroundStyle(.blue)
        case .untested: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        case .labFailed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .antiCheatRisk: Image(systemName: "shield.slash.fill").foregroundStyle(.orange)
        case .blocked: Image(systemName: "nosign").foregroundStyle(.red)
        }
    }
}
#endif
