#if os(macOS)
import SwiftUI
import GamePortKit

@MainActor
final class AppModel: ObservableObject {
    let gameport = GamePort()
    @Published var checks: [GamePort.Check] = []
    private(set) var installedEngines: [InstalledEngine] = []
    var engines: [String] { installedEngines.map(\.id) }
    private(set) var acceptedLicenses: Set<String> = []
    @Published private(set) var revision = 0
    @Published var recipes: [Recipe] = []
    private var profilesByRecipe: [String: Profile] = [:]
    private var labResultsByProfile: [String: [LabResult]] = [:]
    @Published var busy: String?
    @Published var log: [String] = []
    @Published var gptkAccepted = false
    @Published var telemetryEnabled = true
    @Published var steamBase: SteamBase.Stamp?
    @Published var communityVerdicts: [Int: [CommunityVerdict]] = [:]
    private(set) var engineProfiles: [String: [Profile]] = [:]

    init() {
        communityVerdicts = gameport.telemetry.loadCachedVerdicts()
        refresh()
        refreshCommunityVerdicts()
    }

    func refreshCommunityVerdicts() {
        let telemetry = gameport.telemetry
        Task.detached(priority: .utility) {
            let fresh = await telemetry.refreshCommunityVerdicts()
            await MainActor.run { self.communityVerdicts = fresh }
        }
    }

    func refresh() {
        checks = gameport.doctor()
        installedEngines = gameport.engines.installed()
        let licenseIDs = Set(installedEngines.flatMap { $0.manifest.licenses.keys })
        acceptedLicenses = licenseIDs.filter { gameport.licenses.isAccepted($0) }
        recipes = gameport.catalog.sorted
        let profiles = gameport.profiles.all()
        profilesByRecipe = Dictionary(profiles.compactMap { p in p.recipeID.map { ($0, p) } }, uniquingKeysWith: { first, _ in first })
        labResultsByProfile = profiles.reduce(into: [:]) { $0[$1.id] = gameport.profiles.labResults($1.id) }
        gptkAccepted = gameport.licenses.isAccepted("apple-gptk")
        telemetryEnabled = gameport.telemetry.load().enabled
        steamBase = (try? gameport.steamBase()).flatMap { $0.isReady ? $0.stamp : nil }
        engineProfiles = profiles.reduce(into: [:]) { groups, profile in
            if let id = profile.recipeID { groups[id, default: []].append(profile) }
        }
        revision += 1
    }

    func say(_ line: String) { log.append(line); if log.count > 400 { log.removeFirst(log.count - 400) } }

    /// Runs blocking work off the main thread, one job at a time, with its messages in the log.
    func job(_ title: String, _ work: @escaping @Sendable (GamePort, @escaping ProgressHandler) async throws -> String?) {
        guard busy == nil else { return }
        busy = title
        say("▶ \(title)")
        let gameport = self.gameport
        Task.detached {
            let progress: ProgressHandler = { msg in Task { @MainActor in self.say("  \(msg)") } }
            do {
                let done = try await work(gameport, progress)
                await MainActor.run { self.say("✓ \(done ?? title)") }
            } catch {
                await MainActor.run { self.say("✗ \(error)") }
            }
            await MainActor.run { self.busy = nil; self.refresh() }
        }
    }

    func profile(for recipe: Recipe) -> Profile? { profilesByRecipe[recipe.id] }

    func evidence(for recipe: Recipe, profile: Profile?) -> Evidence {
        Evidence.of(recipe, results: profile.flatMap { labResultsByProfile[$0.id] } ?? [],
                    antiCheat: AntiCheatDB.bundled.entry(for: recipe))
    }
}
#endif
