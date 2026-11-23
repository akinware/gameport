import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Whether native Mac Steam is signed in, read from its `connection_log.txt`.
public enum MacSteamSignIn: Equatable, Sendable {
    case signedIn
    /// Connecting or logging on right now.
    case connecting
    /// Signed out. `sessionReplaced` means another Steam client (usually a profile's Windows Steam)
    /// signed in with the same account, and Mac Steam will not reconnect by itself.
    case signedOut(sessionReplaced: Bool)
    /// Steam quit, or nothing was logged yet.
    case unknown
}

/// Native macOS Steam, which GamePort's Steam Bridge talks to instead of Windows Steam.
public enum MacSteam {
    public static let bundleID = "com.valvesoftware.steam"

    public static func connectionLog(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Steam/logs/connection_log.txt")
    }

    /// Reads the sign-in state from the last lines of `connection_log.txt`, where each line carries
    /// the connection state as its second bracket, e.g. `[2026-11-22 17:12:59] [Logged On, 4, 7] …`.
    public static func parseSignIn(connectionLog text: String) -> MacSteamSignIn {
        var state: MacSteamSignIn = .unknown
        var replaced = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.contains("Session Replaced") { replaced = true }
            if line.contains("Log session ended") { state = .unknown; continue }
            guard let s = stateField(line) else { continue }
            switch s {
            case "Logged On":
                state = .signedIn
                replaced = false
            case "Logged Off":
                state = .signedOut(sessionReplaced: replaced)
            case "Connecting", "Connected", "Logging On", "Logging Off":
                state = .connecting
            default:
                break
            }
        }
        if case .signedOut = state { return .signedOut(sessionReplaced: replaced) }
        return state
    }

    /// The `Logged On` in `[time] [Logged On, 4, 7] …`.
    static func stateField(_ line: String) -> String? {
        guard let first = line.range(of: "] ["), let comma = line[first.upperBound...].firstIndex(of: ",") else { return nil }
        return String(line[first.upperBound..<comma])
    }

    public static func signInState(home: URL = FileManager.default.homeDirectoryForCurrentUser, from offset: UInt64 = 0) -> MacSteamSignIn {
        let log = connectionLog(home: home)
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
        // The last ~64 KB is plenty to find the latest state line.
        let start = max(offset, size > 65_536 ? size - 65_536 : 0)
        return parseSignIn(connectionLog: GamePort.tail(of: log, from: start))
    }

    static func connectionLogSize(home: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: connectionLog(home: home).path)[.size] as? UInt64) ?? 0
    }

    /// Opens Mac Steam (in the background unless `foreground`).
    public static func open(foreground: Bool = false) {
        var args = ["-b", bundleID]
        if !foreground { args.insert("-g", at: 0) }
        _ = try? Shell.run("/usr/bin/open", args, check: false)
    }

    /// Asks Mac Steam to quit and waits up to `timeout` seconds. Returns true once it is gone.
    @discardableResult
    public static func quit(timeout: TimeInterval = 30) -> Bool {
        #if canImport(AppKit)
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        #endif
        let deadline = Date().addingTimeInterval(timeout)
        while SteamBridge.isMacSteamRunning() && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        return !SteamBridge.isMacSteamRunning()
    }
}

extension GamePort {
    /// Gets native Mac Steam ready for a Steam Bridge launch: the game's Steam API needs a running,
    /// signed-in Mac Steam, otherwise it fails to initialize and the game quits right away.
    ///
    /// - Stops the profile's Windows Steam if it is running (it signs in with the same account and
    ///   would sign Mac Steam out).
    /// - Starts Mac Steam in the background when it is not running and waits until it has signed in.
    /// - Restarts Mac Steam once when another client replaced its session.
    ///
    /// Returns without error when Mac Steam is running but stays offline (Steam's offline mode still
    /// serves the Steam API); throws only when Mac Steam could not be started.
    public func prepareMacSteamForBridge(
        _ profileID: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeout: TimeInterval = 90,
        progress: ProgressHandler? = nil
    ) throws {
        if let steam = try? steam(for: profileID), steam.isRunning {
            progress?("Closing this game's Windows Steam (it would sign Mac Steam out)…")
            try? steam.shutdown(within: 30)
        }

        var mark = MacSteam.connectionLogSize(home: home)
        var limit = timeout
        if SteamBridge.isMacSteamRunning() {
            switch MacSteam.signInState(home: home) {
            case .signedIn:
                return
            case .signedOut(sessionReplaced: true):
                progress?("Mac Steam was signed out by another Steam client — restarting Mac Steam…")
                MacSteam.quit(timeout: 30)
                mark = MacSteam.connectionLogSize(home: home)
                MacSteam.open()
            case .signedOut(sessionReplaced: false):
                // Signed out or in offline mode: give a pending sign-in a moment, then go on.
                progress?("Waiting for Mac Steam to sign in…")
                mark = 0
                limit = min(timeout, 10)
            default:
                progress?("Waiting for Mac Steam to sign in…")
                mark = 0
            }
        } else {
            progress?("Starting Mac Steam (the Bridge needs it running)…")
            MacSteam.open()
        }

        let deadline = Date().addingTimeInterval(limit)
        var lastNote = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            let running = SteamBridge.isMacSteamRunning()
            let state = MacSteam.signInState(home: home, from: mark)
            if running, state == .signedIn {
                progress?("Mac Steam is signed in")
                return
            }
            if running, case .signedOut(sessionReplaced: false) = state, Date().timeIntervalSince(lastNote) > 15 {
                lastNote = Date()
                progress?("Mac Steam is open but not signed in yet…")
            }
        }
        guard SteamBridge.isMacSteamRunning() else {
            throw GamePortError.missing("Mac Steam did not start. Open Steam.app, sign in, then press Play again.")
        }
        // Running but offline (offline mode or a sign-in prompt): bring it forward and try anyway.
        progress?("Mac Steam is running but not signed in — continuing (offline mode)")
    }
}

extension LaunchDiagnosis {
    /// A Bridge launch that could not start (Mac Steam missing, executable missing, VAC block, …).
    public static func bridgeLaunchFailed(_ error: Error) -> LaunchDiagnosis {
        let text: String
        switch error as? GamePortError {
        case .missing(let s)?, .unsupported(let s)?, .invalid(let s)?: text = s
        default: text = "\(error)"
        }
        return LaunchDiagnosis(headline: "Could not start the game via the Bridge", explanation: text, actions: [], viaBridge: true)
    }
}

extension GamePort {
    /// A game that fails (non-zero exit) within this many seconds of a Bridge launch is treated as a failed start.
    public static let bridgeQuickExitSeconds: TimeInterval = 90

    /// A Bridge game that closed within `bridgeQuickExitSeconds` failed to start only when something says so:
    /// a non-zero exit, a crash in its log, or Mac Steam gone. Quitting quickly yourself exits with status 0.
    public static func bridgeExitNeedsAttention(seconds: TimeInterval, exitStatus: Int32,
                                                crashSigns: [String], macSteamRunning: Bool) -> Bool {
        seconds < bridgeQuickExitSeconds && (exitStatus != 0 || !crashSigns.isEmpty || !macSteamRunning)
    }

    /// Explains a Bridge launch whose game closed right after starting.
    public static func bridgeExitDiagnosis(
        seconds: Int,
        exitStatus: Int32,
        macSteamRunning: Bool,
        macSteamSignIn: MacSteamSignIn,
        crashSigns: [String],
        logPath: String
    ) -> LaunchDiagnosis {
        let headline = "The game closed right after starting"
        let explanation: String
        if !macSteamRunning {
            explanation = "Mac Steam is not running. Bridged games talk to native Mac Steam instead of Windows Steam; without it the game's Steam API cannot start and the game quits. Open Steam.app, sign in, then press Play again."
        } else if case .signedOut(sessionReplaced: true) = macSteamSignIn {
            explanation = "Mac Steam was signed out because another Steam client signed in with the same account (usually this game's Windows Steam). Sign in to Mac Steam again, then press Play."
        } else if let first = crashSigns.first {
            explanation = "It stopped after \(seconds) seconds: \(first). Log: \(logPath)"
        } else {
            explanation = "It stopped after \(seconds) seconds (exit status \(exitStatus)) without logging a reason. Try Play through Windows Steam instead. Log: \(logPath)"
        }
        return LaunchDiagnosis(headline: headline, explanation: explanation, actions: [], viaBridge: true)
    }

    /// Follows a Steam Bridge launch (`process` from `launchWithSteamBridge`) until the game exits,
    /// reports it as running, explains a game that quits right away, and then stops the profile's
    /// remaining Wine processes so nothing stays behind.
    public func monitorBridgeLaunch(
        profileID: String,
        title: String,
        process: Process,
        gameLogStart: UInt64 = 0,
        onState: @escaping @Sendable (LaunchState) -> Void
    ) async {
        let startedAt = Date()
        let logs = profiles.logs(profileID)
        let gameLog = logs.appendingPathComponent("bridge-game.log")
        let fpsLog = logs.appendingPathComponent("play-fps.log")
        let report = BridgeSessionReporter(gameport: self, profileID: profileID, startedAt: startedAt)
        while process.isRunning && !Task.isCancelled {
            let secs = Int(Date().timeIntervalSince(startedAt))
            if secs >= BridgeSessionReporter.healthySeconds { await report.healthy(fpsLog: fpsLog) }
            if secs < 8 {
                onState(.preparing(profileID: profileID, progress: LaunchProgress(
                    title: title, stage: .startingGame, seconds: secs, secondsWithoutProgress: 0,
                    bridgeStep: "Starting the game")))
            } else {
                let fps = (try? String(contentsOf: fpsLog, encoding: .utf8))
                    .flatMap { TelemetryStore.parsePlayFPSLog($0, steadyAfter: 5)?.avgFPS }
                onState(.running(profileID: profileID, seconds: secs, fps: fps))
            }
            try? await Task.sleep(for: .seconds(secs < 8 ? 1 : 3))
        }
        if Task.isCancelled { return }
        let played = Date().timeIntervalSince(startedAt)
        // Stop what the game left behind in its prefix (wineserver, services).
        if let runner = try? runner(for: profileID) { try? runner.killAll() }
        let text = Self.tail(of: gameLog, from: gameLogStart)
        // Only the game's own log: a Bridge launch has no Windows Steam, so Windows Steam's logs say nothing.
        let signs = LabTriage.crashSigns(inLog: text)
        let macSteamRunning = SteamBridge.isMacSteamRunning()
        // Stopped by GamePort or macOS (a signal) is not the game failing.
        let failedExit = process.terminationReason == .exit && process.terminationStatus != 0
        await report.finished(seconds: played, signs: signs, failedExit: failedExit, fpsLog: fpsLog)
        if Self.bridgeExitNeedsAttention(seconds: played, exitStatus: process.terminationStatus,
                                         crashSigns: signs, macSteamRunning: macSteamRunning) {
            onState(.needsAttention(profileID: profileID, diagnosis: Self.bridgeExitDiagnosis(
                seconds: Int(played),
                exitStatus: process.terminationStatus,
                macSteamRunning: macSteamRunning,
                macSteamSignIn: MacSteam.signInState(),
                crashSigns: signs,
                logPath: gameLog.path)))
        } else {
            onState(.idle)
        }
    }
}

/// Records a Bridge session in the profile's play history and, with reporting on, sends the same
/// anonymous report a Windows Steam session sends (marked as a Bridge launch).
actor BridgeSessionReporter {
    static let healthySeconds = 90

    let gameport: GamePort
    let profileID: String
    let startedAt: Date
    private var sentHealthy = false

    init(gameport: GamePort, profileID: String, startedAt: Date) {
        self.gameport = gameport
        self.profileID = profileID
        self.startedAt = startedAt
    }

    /// Still running cleanly after 90 s: report it works now, in case the app is quit before the game is.
    func healthy(fpsLog: URL) async {
        guard !sentHealthy else { return }
        sentHealthy = true
        await send(seconds: Date().timeIntervalSince(startedAt), stillRunning: true, signs: [], fpsLog: fpsLog)
    }

    func finished(seconds: TimeInterval, signs: [String], failedExit: Bool, fpsLog: URL) async {
        guard let runner = try? gameport.runner(for: profileID) else { return }
        var signs = signs
        if failedExit && seconds < 60 { signs.append("The game exited before the end of its first minute.") }
        let codes = TelemetryReport.classifyCrashSigns(signs)
        let fps = Self.fps(fpsLog)
        gameport.playHistory.record(PlayRecord(
            startedAt: startedAt, seconds: Int(seconds), method: .bridge,
            outcome: PlayRecord.outcome(gameStarted: true, seconds: seconds, problems: codes, failedExit: failedExit),
            engineID: runner.engine.id, renderer: runner.effectiveRenderer, vulkanDriver: runner.effectiveVulkanDriver,
            sync: runner.effectiveSync, avgFPS: fps?.avgFPS, onePercentLowFPS: fps?.onePercentLowFPS, problems: codes),
            profileID: profileID)
        await send(seconds: seconds, stillRunning: false, signs: signs, fpsLog: fpsLog, runner: runner)
    }

    private func send(seconds: TimeInterval, stillRunning: Bool, signs: [String], fpsLog: URL,
                      runner: WineRunner? = nil) async {
        let telemetry = gameport.telemetry
        guard telemetry.isEffectivelyEnabled(), let url = telemetry.endpoint(),
              let runner = runner ?? (try? gameport.runner(for: profileID)),
              let appID = runner.recipe?.steamAppID else { return }
        let fps = Self.fps(fpsLog)
        guard let report = TelemetryReport.fromPlaySession(
            steamAppID: appID, recipeID: runner.profile.recipeID, renderer: runner.effectiveRenderer,
            vulkanDriver: runner.effectiveVulkanDriver, sync: runner.effectiveSync,
            engineID: runner.engine.id, engineArch: runner.engine.manifest.arch,
            gameStarted: true, playedSeconds: seconds, stillRunning: stillRunning,
            crashSigns: signs, peakThermalState: LabThermalState.current(),
            avgFPS: fps?.avgFPS, onePercentLowFPS: fps?.onePercentLowFPS,
            installID: telemetry.load().installID, startedAt: startedAt, launchMethod: .bridge
        ) else { return }
        await telemetry.send(report, to: url)
    }

    private static func fps(_ log: URL) -> TelemetryStore.PlayFPSStats? {
        (try? String(contentsOf: log, encoding: .utf8)).flatMap { TelemetryStore.parsePlayFPSLog($0) }
    }
}
