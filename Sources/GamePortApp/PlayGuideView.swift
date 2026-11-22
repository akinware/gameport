#if os(macOS)
import AppKit
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
    @State private var battleNetInstalled: Bool?
    @State private var gameInstalled = false
    @State private var showLicense = false

    private var isBattleNet: Bool { recipe.launch == .battlenet }

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
                      gameInstalled: gameInstalled, hasFallback: profile?.fallbackProfileID != nil,
                      isBattleNet: isBattleNet, battleNetInstalled: battleNetInstalled == true)
    }

    private struct Observation: Equatable {
        let revision: Int
        let phase: ScenePhase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profile != nil && engine != nil && (isBattleNet ? battleNetInstalled == nil : steamInstalled == nil) {
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
                        Label(step.buttonTitle, systemImage: (step == .play || step == .openBattleNet) ? "play.fill" : "arrow.right")
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
                if let profile {
                    LaunchStatusView(profile: profile, recipe: recipe)
                }
                ExternalLauncherBar(recipe: recipe)
            }
        }
        .task(id: Observation(revision: model.revision, phase: scenePhase)) {
            guard let profile, engine != nil, scenePhase != .background else { return }
            let gameport = model.gameport
            if isBattleNet {
                let bn = await Task.detached { try? gameport.battleNet(for: profile.id) }.value
                while !Task.isCancelled {
                    let installed = bn?.isInstalled == true
                    battleNetInstalled = installed
                    guard !installed, scenePhase == .active else { break }
                    do { try await Task.sleep(for: .seconds(4)) } catch { break }
                }
                return
            }
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
        case .installBattleNet:
            guard let profile else { return }
            model.job("Installing Battle.net") { kit, progress in
                _ = try await kit.battleNet(for: profile.id).install(progress: progress)
                return "Battle.net installer launched — complete setup in its window"
            }
        case .openBattleNet:
            guard let profile else { return }
            model.job("Opening Battle.net") { kit, progress in
                _ = try kit.openBattleNet(profile.id, progress: progress)
                return "Battle.net opened"
            }
        case .play:
            guard let profile else { return }
            model.launchGame(profile: profile, recipe: recipe)
        }
    }
}

struct LaunchStatusView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile
    let recipe: Recipe

    var body: some View {
        switch model.launchState {
        case .startingSteam(let id) where id == profile.id:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting Windows Steam…").font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 4)
        case .waitingForGame(let id, let title) where id == profile.id:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Launching \(title) (first launch may compile shaders)…").font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 4)
        case .running(let id, let seconds, let fps) where id == profile.id:
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
                let fpsText = fps.map { " · \(String(format: "%.0f", $0)) FPS" } ?? ""
                Text("Running (\(seconds)s)\(fpsText)").font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 4)
        case .needsAttention(let id, let diagnosis) where id == profile.id:
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(diagnosis.headline, systemImage: "wrench.and.screwdriver.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text(diagnosis.explanation).font(.callout).foregroundStyle(.secondary)
                    ForEach(diagnosis.actions) { action in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title).font(.callout.bold())
                                Text(action.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Fix & Retry") {
                                model.applyRecovery(action, to: profile, recipe: recipe, retry: true)
                            }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    HStack {
                        Button("Copy Diagnostic Report") {
                            let report = model.gameport.diagnosticReport(profileID: profile.id, diagnosis: diagnosis)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                            model.say("✓ Copied privacy-redacted diagnostic report to clipboard")
                        }.controlSize(.small)
                        Spacer()
                        Button("Dismiss") { model.launchState = .idle }.controlSize(.small)
                    }
                }.padding(6)
            }.padding(.top, 6)
        default:
            EmptyView()
        }
    }
}

struct ExternalLauncherBar: View {
    @EnvironmentObject var model: AppModel
    let recipe: Recipe

    var body: some View {
        let ac = AntiCheatDB.bundled.entry(for: recipe)
        let suggestObelisk = ExternalEnvironment.suggestsObelisk(for: ac)
        let suggestSiliconium = ExternalEnvironment.suggestsSiliconium(steamAppID: recipe.steamAppID)
        let macGame = recipe.steamAppID.flatMap { model.externalEnv.macSteamGame(appID: $0) }
        let cxBottle = recipe.steamAppID.flatMap { model.externalEnv.crossoverBottle(containingAppID: $0) }

        if suggestObelisk || suggestSiliconium || macGame != nil || cxBottle != nil {
            VStack(alignment: .leading, spacing: 6) {
                if suggestObelisk {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(.blue)
                        Text("Linux-supported anti-cheat (\(ac?.antiCheats.joined(separator: ", ") ?? "EAC/BattlEye")): can also run via Obelisk's Linux runtime.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let obelisk = model.externalEnv.obeliskApp {
                            Button("Run with Obelisk") { NSWorkspace.shared.open(obelisk) }
                                .controlSize(.small)
                        } else if let url = URL(string: ExternalEnvironment.obeliskWebsite) {
                            Link("Get Obelisk…", destination: url)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                if suggestSiliconium {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(.purple)
                        Text("Also supported by Siliconium (dedicated Call of Duty tuning, Plutonium / IW4X / CoD4X / BOIII).")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let app = model.externalEnv.siliconiumApp {
                            Button("Run with Siliconium") { NSWorkspace.shared.open(app) }
                                .controlSize(.small)
                        } else if let url = URL(string: ExternalEnvironment.siliconiumWebsite) {
                            Link("Get Siliconium…", destination: url)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                if let macGame, let steamURL = URL(string: "steam://rungameid/\(macGame.appID)") {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.green)
                        Text("Also installed in Mac Steam\(model.externalEnv.notProtonInstalled ? " (NotProton available)" : "").")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Play in Mac Steam") { NSWorkspace.shared.open(steamURL) }
                            .controlSize(.small)
                    }
                }
                if let cxBottle, let cxApp = model.externalEnv.crossoverApp {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox").foregroundStyle(.orange)
                        Text("Also installed in CrossOver bottle \"\(cxBottle.name)\".")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open CrossOver") { NSWorkspace.shared.open(cxApp) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 4)
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
        case .installBattleNet: return "Install Battle.net"
        case .openBattleNet: return "Open Battle.net"
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
        case .installBattleNet: return "Download and run Blizzard’s official Battle.net installer inside this private environment."
        case .openBattleNet: return "Open Battle.net to sign in, install, or play this game."
        case .play: return "Installed in Steam."
        }
    }
}
#endif
