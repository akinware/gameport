#if os(macOS)
import SwiftUI
import GamePortKit

@MainActor
final class AppModel: ObservableObject {
    var gameport = GamePort()
    @Published var checks: [GamePort.Check] = []
    @Published var engineCatalog: [EngineCatalogEntry] = []
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
    @Published var storageInfo: StorageInfo = StorageInfo.inspect(Paths.default().root, isCustom: StoragePreference.load().customRoot != nil)
    @Published var launchState: LaunchState = .idle
    @Published var communityVerdicts: [Int: [CommunityVerdict]] = [:]
    @Published var externalEnv: ExternalEnvironment = .empty
    @Published var aarchxInstalled = false
    @Published var aarchxVersion: String?
    @Published var x87Installed = false
    @Published var x87Version: String?
    private(set) var engineProfiles: [String: [Profile]] = [:]
    private var launchMonitorTask: Task<Void, Never>?

    init() {
        communityVerdicts = gameport.telemetry.loadCachedVerdicts()
        refresh()
        refreshCommunityVerdicts()
    }

    func reloadStorage() {
        gameport = GamePort()
        storageInfo = StorageInfo.inspect(gameport.paths.root, isCustom: StoragePreference.load().customRoot != nil)
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
        storageInfo = StorageInfo.inspect(gameport.paths.root, isCustom: StoragePreference.load().customRoot != nil)
        checks = gameport.doctor()
        installedEngines = gameport.engines.installed()
        engineCatalog = gameport.engineCatalog()
        let licenseIDs = Set(installedEngines.flatMap { $0.manifest.licenses.keys })
        acceptedLicenses = licenseIDs.filter { gameport.licenses.isAccepted($0) }
        recipes = gameport.catalog.sorted
        let profiles = gameport.profiles.all()
        profilesByRecipe = Dictionary(profiles.compactMap { p in p.recipeID.map { ($0, p) } }, uniquingKeysWith: { first, _ in first })
        labResultsByProfile = profiles.reduce(into: [:]) { $0[$1.id] = gameport.profiles.labResults($1.id) }
        gptkAccepted = gameport.licenses.isAccepted("apple-gptk")
        telemetryEnabled = gameport.telemetry.load().enabled
        steamBase = (try? gameport.steamBase()).flatMap { $0.isReady ? $0.stamp : nil }
        aarchxInstalled = gameport.aarchx.isInstalled
        aarchxVersion = gameport.aarchx.versionString()
        x87Installed = gameport.x87sidecar.isInstalled
        x87Version = gameport.x87sidecar.versionString()
        externalEnv = ExternalDiscovery.scan()
        engineProfiles = profiles.reduce(into: [:]) { groups, profile in
            if let id = profile.recipeID { groups[id, default: []].append(profile) }
        }
        revision += 1
    }

    func launchGame(profile: Profile, recipe: Recipe) {
        launchMonitorTask?.cancel()
        launchState = .startingSteam(profileID: profile.id)
        let kit = self.gameport
        let steamLogs = (try? kit.steam(for: profile.id).logs)
        let cefLog = steamLogs?.appendingPathComponent("cef_log.txt")
        let bootstrapLog = steamLogs?.appendingPathComponent("bootstrap_log.txt")
        func fileSize(_ url: URL?) -> UInt64 {
            guard let url else { return 0 }
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        }
        let cefStart = fileSize(cefLog)
        let bootstrapStart = fileSize(bootstrapLog)

        job("Starting \(recipe.title)") { kit, progress in
            _ = try kit.play(profile.id, progress: progress)
            await MainActor.run {
                self.startLaunchWatcher(profile: profile, recipe: recipe, cefStart: cefStart, bootstrapStart: bootstrapStart)
            }
            return "Launch requested"
        }
    }

    private func startLaunchWatcher(profile: Profile, recipe: Recipe, cefStart: UInt64, bootstrapStart: UInt64) {
        launchMonitorTask?.cancel()
        let kit = self.gameport
        launchMonitorTask = Task.detached(priority: .utility) {
            await kit.monitorLaunch(profile: profile, recipe: recipe, cefStart: cefStart, bootstrapStart: bootstrapStart) { state in
                Task { @MainActor in self.launchState = state }
            }
        }
    }

    func applyRecovery(_ action: RecoveryAction, to profile: Profile, recipe: Recipe, retry: Bool) {
        launchState = .idle
        job(action.title) { kit, progress in
            let msg = try kit.applyRecovery(action.kind, to: profile.id, progress: progress)
            if retry {
                let updated = try kit.profiles.load(profile.id)
                await MainActor.run { self.launchGame(profile: updated, recipe: recipe) }
            }
            return msg
        }
    }

    func updateProfile(_ profileID: String, mutate: (inout Profile) -> Void) {
        do {
            var p = try gameport.profiles.load(profileID)
            mutate(&p)
            try gameport.profiles.save(p)
            refresh()
        } catch {
            say("✗ \(error)")
        }
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
