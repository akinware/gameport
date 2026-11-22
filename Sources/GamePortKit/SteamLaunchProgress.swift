import Foundation

/// The steps Windows Steam goes through between "Play" and the game's window, in order.
/// Steam runs hidden (`-silent`), so these come from its own logs.
public enum SteamLaunchStage: Int, Sendable, Comparable, CaseIterable, Codable {
    case startingSteam
    case signingIn
    case checkingForUpdates
    case updatingGame
    case syncingCloud
    case preparingGame
    case startingGame

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .startingSteam: return "Starting Windows Steam"
        case .signingIn: return "Signing in to Steam"
        case .checkingForUpdates: return "Checking for updates"
        case .updatingGame: return "Updating the game"
        case .syncingCloud: return "Syncing Steam Cloud saves"
        case .preparingGame: return "Running first-time setup"
        case .startingGame: return "Starting the game"
        }
    }

    /// Short label for a step indicator.
    public var shortTitle: String {
        switch self {
        case .startingSteam: return "Steam"
        case .signingIn: return "Sign in"
        case .checkingForUpdates: return "Updates"
        case .updatingGame: return "Update"
        case .syncingCloud: return "Cloud"
        case .preparingGame: return "Setup"
        case .startingGame: return "Game"
        }
    }

    /// What is usually going on, for the hint under the progress.
    public var hint: String {
        switch self {
        case .startingSteam: return "Windows Steam starts in the background. This usually takes 30–60 seconds."
        case .signingIn: return "Signing in with your saved Steam login."
        case .checkingForUpdates: return "Steam checks the game is up to date before starting it."
        case .updatingGame: return "Steam is downloading a game update. This can take a while."
        case .syncingCloud: return "Steam is syncing your cloud saves."
        case .preparingGame: return "Steam runs the game's install script (redistributables) before the first start."
        case .startingGame: return "The game is starting. Its window appears in a moment."
        }
    }

    /// The step indicator shown to users (the update step only appears when an update runs).
    public static let indicatorSteps: [SteamLaunchStage] = [.startingSteam, .signingIn, .checkingForUpdates, .preparingGame, .startingGame]
}

/// What Steam's logs say about a launch so far.
public struct SteamLaunchSnapshot: Sendable, Equatable {
    public var stage: SteamLaunchStage = .startingSteam
    /// The raw Steam launch task (e.g. `RunningInstallScript`), when one was logged.
    public var steamTask: String?
    /// Steam is waiting for an answer to a prompt it shows in its (hidden) window.
    public var waitingForUser: String?
    /// Steam reported that the launch failed.
    public var failed: Bool = false

    public init(stage: SteamLaunchStage = .startingSteam, steamTask: String? = nil, waitingForUser: String? = nil, failed: Bool = false) {
        self.stage = stage
        self.steamTask = steamTask
        self.waitingForUser = waitingForUser
        self.failed = failed
    }
}

/// Byte offsets of Steam's logs taken just before a launch, so only that launch's lines are read.
public struct SteamLaunchLogMarks: Sendable, Equatable {
    public var console: UInt64
    public var connection: UInt64
    public var content: UInt64
    public var cef: UInt64
    public var bootstrap: UInt64

    public init(console: UInt64 = 0, connection: UInt64 = 0, content: UInt64 = 0, cef: UInt64 = 0, bootstrap: UInt64 = 0) {
        self.console = console
        self.connection = connection
        self.content = content
        self.cef = cef
        self.bootstrap = bootstrap
    }
}

public enum SteamLaunchProgress {
    /// Launch tasks Steam answers itself; any other "waiting for user response" needs the user.
    static let automaticResponses: Set<String> = ["CreatingProcess", "ShowInterstitials"]

    /// Reads the launch of `appID` from the new parts of Steam's `console_log.txt`,
    /// `connection_log.txt` and `content_log.txt`.
    public static func parse(appID: Int, console: String, connection: String, content: String = "") -> SteamLaunchSnapshot {
        var snap = SteamLaunchSnapshot()
        func raise(_ stage: SteamLaunchStage) { if stage > snap.stage { snap.stage = stage } }

        for line in connection.split(separator: "\n") {
            if line.contains("Logging on") || line.contains("[Connecting") || line.contains("Connect()") { raise(.signingIn) }
            if line.contains("[Logged On") || line.contains("processing complete") { raise(.checkingForUpdates) }
        }
        for line in content.split(separator: "\n") where line.contains("AppID \(appID) ") {
            if line.contains("Update Running") || line.contains("Downloading") { raise(.updatingGame) }
        }

        let marker = "[AppID \(appID),"
        for raw in console.split(separator: "\n") {
            let line = String(raw)
            if line.contains("Console Log Start") { snap.waitingForUser = nil }
            guard line.contains("GameAction"), line.contains(marker) else { continue }
            if let task = capture(line, after: "LaunchApp changed task to ", until: " with") {
                snap.steamTask = task
                // A new task means any earlier prompt was answered.
                snap.waitingForUser = nil
                switch task {
                case "ConnectingToSteam": raise(.signingIn)
                case "UpdatingAppInfo", "UpdatingAppTicket", "CheckShaderDepotManifest", "SiteLicenseSeatCheckout":
                    raise(.checkingForUpdates)
                case "DownloadingDepots", "WaitingForUpdate", "UpdatingApp":
                    raise(.updatingGame)
                case "SynchronizingCloud", "SynchronizingStats":
                    raise(.syncingCloud)
                case "RunningInstallScript", "ShowInterstitials", "DelayLaunch":
                    raise(.preparingGame)
                case "CreatingProcess", "WaitingGameWindow", "Completed":
                    raise(.startingGame)
                case "Failed":
                    snap.failed = true
                default:
                    break
                }
            } else if let prompt = capture(line, after: "LaunchApp waiting for user response to ", until: " ") {
                if !automaticResponses.contains(prompt) { snap.waitingForUser = prompt }
            } else if line.contains("LaunchApp continues with user response") {
                snap.waitingForUser = nil
            }
        }
        return snap
    }

    /// A readable explanation for a prompt Steam is waiting on.
    public static func describePrompt(_ prompt: String) -> String {
        switch prompt {
        case "IgnorePendingCloudSessions", "PendingCloudSessions":
            return "Steam is asking about a Steam Cloud save conflict."
        case "ShowEula", "AcceptEula":
            return "Steam is asking you to accept the game's license agreement."
        case "ShowLaunchOption", "LaunchOptions":
            return "Steam is asking which way to start the game."
        default:
            return "Steam is waiting for you to answer a prompt (\(prompt))."
        }
    }

    static func capture(_ line: String, after prefix: String, until terminator: String) -> String? {
        guard let start = line.range(of: prefix) else { return nil }
        let rest = line[start.upperBound...]
        let value = rest.range(of: terminator).map { rest[..<$0.lowerBound] } ?? rest
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension GamePort {
    /// Current sizes of the profile's Steam logs; pass to `monitorLaunch` so it reads only new lines.
    public func steamLaunchLogMarks(_ profileID: String) -> SteamLaunchLogMarks {
        guard let logs = try? steam(for: profileID).logs else { return SteamLaunchLogMarks() }
        func size(_ name: String) -> UInt64 {
            (try? FileManager.default.attributesOfItem(atPath: logs.appendingPathComponent(name).path)[.size] as? UInt64) ?? 0
        }
        return SteamLaunchLogMarks(
            console: size("console_log.txt"),
            connection: size("connection_log.txt"),
            content: size("content_log.txt"),
            cef: size("cef_log.txt"),
            bootstrap: size("bootstrap_log.txt")
        )
    }
}
