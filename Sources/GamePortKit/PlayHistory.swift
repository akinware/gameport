import Foundation

/// One time a game was played, kept on this Mac only (never sent anywhere), so GamePort can say
/// how a game ran last time and prefer the way that worked.
public struct PlayRecord: Codable, Sendable, Equatable {
    /// How the game was started.
    public enum Method: String, Codable, Sendable {
        /// Through GamePort's own Windows Steam in the profile.
        case windowsSteam
        /// Through the Steam Bridge (Mac Steam, no Windows Steam).
        case bridge

        public var label: String { self == .bridge ? "Steam Bridge" : "Windows Steam" }
    }

    public enum Outcome: String, Codable, Sendable {
        /// Ran for at least a minute without a fatal error.
        case worked
        /// Crashed, or stopped with an error.
        case crashed
        /// The game never came up.
        case didNotStart
        /// Closed within the first minute without any sign of a problem.
        case closedEarly

        public var label: String {
            switch self {
            case .worked: return "worked"
            case .crashed: return "crashed"
            case .didNotStart: return "did not start"
            case .closedEarly: return "closed early"
            }
        }

        /// The session tells something about whether this way of playing works.
        public var isConclusive: Bool { self != .closedEarly }
    }

    public var startedAt: Date
    public var seconds: Int
    public var method: Method
    public var outcome: Outcome
    public var engineID: String
    public var renderer: Renderer
    public var vulkanDriver: VulkanDriver
    public var sync: SyncMode
    public var avgFPS: Double?
    public var onePercentLowFPS: Double?
    /// Privacy-safe problem codes (`TelemetryReport.classifyCrashSigns`).
    public var problems: [String]

    public init(startedAt: Date, seconds: Int, method: Method, outcome: Outcome, engineID: String,
                renderer: Renderer, vulkanDriver: VulkanDriver, sync: SyncMode,
                avgFPS: Double? = nil, onePercentLowFPS: Double? = nil, problems: [String] = []) {
        self.startedAt = startedAt
        self.seconds = seconds
        self.method = method
        self.outcome = outcome
        self.engineID = engineID
        self.renderer = renderer
        self.vulkanDriver = vulkanDriver
        self.sync = sync
        self.avgFPS = avgFPS
        self.onePercentLowFPS = onePercentLowFPS
        self.problems = problems
    }

    /// Problem codes that mean the game itself broke (not a quick, deliberate quit).
    static let fatalCodes: Set<String> = ["wine_exception", "vulkan_error", "vulkan_query_unsupported"]

    /// What a finished session amounts to. A minute of play counts as working unless the log shows a
    /// fatal error; a quick quit counts only when something went wrong (an error code or a failing exit).
    public static func outcome(gameStarted: Bool, seconds: TimeInterval, problems: [String],
                               failedExit: Bool = false) -> Outcome {
        guard gameStarted else { return .didNotStart }
        if problems.contains(where: fatalCodes.contains) { return .crashed }
        if seconds >= 60 { return .worked }
        if failedExit || !problems.isEmpty { return .crashed }
        return .closedEarly
    }

    /// "Today · 25 min · worked · Steam Bridge · 60 FPS".
    public func summary(now: Date = Date()) -> String {
        var parts = [Self.day(startedAt, now: now), Self.duration(seconds), outcome.label, method.label]
        if let avgFPS { parts.append(String(format: "%.0f FPS", avgFPS)) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return String(format: "%d h %02d min", seconds / 3600, (seconds % 3600) / 60)
    }

    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d, yyyy"
        return format.string(from: date)
    }
}

/// A profile's recent sessions, newest first, in `profiles/<id>/plays.json`.
public struct PlayHistoryStore: Sendable {
    public let paths: Paths
    public static let limit = 30

    public init(paths: Paths) { self.paths = paths }

    public func file(_ profileID: String) -> URL {
        paths.profile(profileID).appendingPathComponent("plays.json")
    }

    public func sessions(_ profileID: String) -> [PlayRecord] {
        guard let data = try? Data(contentsOf: file(profileID)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PlayRecord].self, from: data)) ?? []
    }

    public func record(_ session: PlayRecord, profileID: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // Only a profile that still exists: a session that outlives its profile is dropped.
        guard FileManager.default.fileExists(atPath: paths.profile(profileID).path) else { return }
        let all = Array(([session] + sessions(profileID)).prefix(Self.limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(all).write(to: file(profileID), options: .atomic)
    }

    private static let lock = NSLock()
}

extension Array where Element == PlayRecord {
    /// The newest session that says something about `method` (quick deliberate quits are skipped).
    public func lastConclusive(_ method: PlayRecord.Method) -> PlayRecord? {
        first { $0.method == method && $0.outcome.isConclusive }
    }

    /// The Bridge failed the last time it was tried, while Windows Steam worked the last time it was:
    /// playing through Windows Steam is the better bet.
    public var prefersWindowsSteamOverBridge: Bool {
        guard let bridge = lastConclusive(.bridge), bridge.outcome != .worked,
              let steam = lastConclusive(.windowsSteam), steam.outcome == .worked else { return false }
        return true
    }
}

extension GamePort {
    public var playHistory: PlayHistoryStore { PlayHistoryStore(paths: paths) }
}
