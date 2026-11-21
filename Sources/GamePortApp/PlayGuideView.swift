#if os(macOS)
import SwiftUI
import GamePortKit

struct PlayGuideView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let recipe: Recipe
    let profile: Profile?
    let newEngineID: String?
    let openSetup: () -> Void

    @State private var steamInstalled: Bool?
    @State private var gameInstalled = false
    @State private var showLicense = false

    private var engine: InstalledEngine? { model.installedEngines.first { $0.id == profile?.engineID } }

    private var requiredLicense: String? {
        guard let engine,
              let id = (profile?.renderer ?? recipe.renderer).gatingLicense(in: engine.manifest),
              !model.acceptedLicenses.contains(id) else { return nil }
        return id
    }

    private var nextStep: PlayStep {
        PlayStep.next(engineAvailable: profile == nil ? !model.engines.isEmpty : engine != nil,
                      hasProfile: profile != nil, needsLicense: requiredLicense != nil,
                      steamInstalled: steamInstalled == true, hasSteamAppID: recipe.steamAppID != nil,
                      gameInstalled: gameInstalled, hasFallback: profile?.fallbackProfileID != nil)
    }

    private struct Observation: Equatable {
        let revision: Int
        let phase: ScenePhase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profile != nil && engine != nil && steamInstalled == nil {
                ProgressView("Checking installation…").controlSize(.small)
            } else {
                let step = nextStep
                if step == .play && engine == nil {
                    Text("GamePort will try the fallback profile for this game.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(step.instruction).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button { perform(step) } label: {
                        Label(step.buttonTitle, systemImage: step == .play ? "play.fill" : "arrow.right")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    // The core also allows an explicit launch when Steam's local manifest is missing
                    // (for example, games in another Steam library or a prepared fallback profile).
                    if (step == .downloadGame || (step == .installSteam && profile?.fallbackProfileID != nil)),
                       recipe.steamAppID != nil {
                        Button("Try Play anyway") { perform(.play) }
                    }
                    if step == .play && steamInstalled == true {
                        Button("Open Steam") { perform(.openSteam) }
                    }
                }.disabled(model.busy != nil)
            }
        }
        .task(id: Observation(revision: model.revision, phase: scenePhase)) {
            guard let profile, engine != nil, scenePhase != .background else { return }
            let gameport = model.gameport
            let client = await Task.detached { try? gameport.steam(for: profile.id) }.value
            // Steam finishes downloads in a separate process. While waiting for a download,
            // re-read just this game's manifest so the button changes to Play automatically.
            while !Task.isCancelled {
                let installed = client?.isInstalled == true
                let ready = recipe.steamAppID.map { client?.isGameInstalled(appID: $0) == true } ?? false
                steamInstalled = installed
                gameInstalled = ready
                guard installed, recipe.steamAppID != nil, !ready, scenePhase == .active else { break }
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
            }
        }
        .sheet(isPresented: $showLicense) {
            if let id = requiredLicense, let license = engine?.manifest.licenses[id] {
                LicenseSheet(id: id, license: license)
            }
        }
    }

    private func perform(_ step: PlayStep) {
        switch step {
        case .setupEngine: openSetup()
        case .reviewLicense: showLicense = true
        case .createProfile:
            let engineID = newEngineID
            model.job("Creating the environment for \(recipe.title)") { kit, progress in
                try kit.createProfile(recipeID: recipe.id, engineID: engineID, progress: progress).id
            }
        case .installSteam:
            guard let profile else { return }
            model.job("Installing Steam") { kit, progress in
                try await kit.steam(for: profile.id).install(progress: progress)
                return "Steam installed"
            }
        case .downloadGame, .openSteam:
            guard let profile else { return }
            model.job("Opening Steam") { kit, progress in
                _ = try kit.openSteam(profile.id, progress: progress)
                return "Steam opened"
            }
        case .play:
            guard let profile else { return }
            model.job("Starting \(recipe.title)") { kit, progress in
                _ = try kit.play(profile.id, progress: progress)
                return "Launch requested"
            }
        }
    }
}

private extension PlayStep {
    var buttonTitle: String {
        switch self {
        case .setupEngine: return "Open Setup"
        case .createProfile: return "Create environment"
        case .reviewLicense: return "Review licence"
        case .installSteam: return "Install Steam"
        case .downloadGame, .openSteam: return "Open Steam"
        case .play: return "Play"
        }
    }

    var instruction: String {
        switch self {
        case .setupEngine: return "Install the game engine in Setup, then return to this game."
        case .createProfile: return "First, create an isolated environment for this game."
        case .reviewLicense: return "Review the renderer licence to continue."
        case .installSteam: return "Install Windows Steam in this game’s environment."
        case .downloadGame: return "Sign in to Steam and download the game. Play appears when the download finishes."
        case .openSteam: return "This recipe has no Steam app ID. Open Steam to find and launch the game manually."
        case .play: return "Installed in Steam."
        }
    }
}
#endif
