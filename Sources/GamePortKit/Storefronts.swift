import Foundation

/// Supported non-Steam native storefronts that download Windows games natively on macOS
/// and launch them directly under CrossOver.app (0 MB) or GamePort PowerKit with zero
/// heavy Windows store client running in RAM.
public enum StorefrontKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case epic
    case gog
    case heroicEpic
    case heroicGOG
    case heroicAmazon

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .epic: return "Epic Games"
        case .gog: return "GOG"
        case .heroicEpic: return "Heroic · Epic"
        case .heroicGOG: return "Heroic · GOG"
        case .heroicAmazon: return "Heroic · Amazon"
        }
    }
}

/// A Windows game from Epic Games, GOG, or an existing Heroic Games Launcher install.
public struct StorefrontGame: Codable, Sendable, Equatable, Identifiable {
    public let store: StorefrontKind
    public let appID: String
    public let title: String
    public let installPath: URL?
    public let executableRelativePath: String?
    public let version: String?
    public let artworkURL: URL?
    public let sizeBytes: Int64?

    public var id: String { "\(store.rawValue):\(appID)" }
    public var isInstalled: Bool { installPath != nil }

    public init(
        store: StorefrontKind,
        appID: String,
        title: String,
        installPath: URL? = nil,
        executableRelativePath: String? = nil,
        version: String? = nil,
        artworkURL: URL? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.store = store
        self.appID = appID
        self.title = title
        self.installPath = installPath
        self.executableRelativePath = executableRelativePath
        self.version = version
        self.artworkURL = artworkURL
        self.sizeBytes = sizeBytes
    }

    /// Resolves the Windows `.exe` inside `installPath` (using explicit metadata or `SteamDepotManager.discoverMainExecutable`).
    public func resolvedExecutable() -> URL? {
        guard let root = installPath else { return nil }
        if let rel = executableRelativePath, !rel.isEmpty {
            let clean = rel.replacingOccurrences(of: "\\", with: "/")
            let candidate = root.appendingPathComponent(clean)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if let gogExe = GOGStorefront.discoverPlayTaskExecutable(in: root) { return gogExe }
        return SteamDepotManager.discoverMainExecutable(in: root, preferredName: title)
    }
}

// MARK: - Epic Games (legendary — separate CLI process, GPL-3, SHA-256 verified)

/// Native macOS Epic Games client backed by upstream `legendary` (executed as a separate process,
/// never linked or bundled). Downloads Windows games natively on macOS and launches them directly
/// on CrossOver.app or GamePort PowerKit with zero Epic Games Launcher running in RAM.
public struct EpicStorefront: Sendable {
    public static let version = "0.20.43"
    public static let downloadURL = URL(string: "https://github.com/Heroic-Games-Launcher/legendary/releases/download/0.20.43/legendary_macOS_arm64")!
    public static let sha256 = "fce325ca0c6c7edd7aaed559ed3f09772689f7f259965ca9ba5fb90f4b5108eb"
    public static let loginURL = URL(string: "https://legendary.gl/epiclogin")!

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var toolDir: URL { paths.tools.appendingPathComponent("epic", isDirectory: true) }
    public var binaryURL: URL { toolDir.appendingPathComponent("legendary") }
    public var configDir: URL { toolDir.appendingPathComponent("config", isDirectory: true) }
    public var gamesDir: URL { paths.root.appendingPathComponent("games/epic", isDirectory: true) }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    public var isSignedIn: Bool {
        FileManager.default.fileExists(atPath: configDir.appendingPathComponent("user.json").path)
    }

    private func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LEGENDARY_CONFIG_PATH"] = configDir.path
        return env
    }

    /// Downloads, SHA-256-verifies, and installs the native Apple Silicon `legendary` binary.
    @discardableResult
    public func install(progress: ProgressHandler? = nil) async throws -> URL {
        try paths.ensure(paths.downloads, toolDir, configDir)
        let downloader = Downloader(cache: paths.downloads)
        let file = try await downloader.fetch(Self.downloadURL, sha256: Self.sha256, progress: progress)
        let staging = toolDir.appendingPathComponent("legendary.staging-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: file, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        try? fm.removeItem(at: binaryURL)
        try fm.moveItem(at: staging, to: binaryURL)
        progress?("Installed legendary \(Self.version) (arm64, SHA-256 verified)")
        return binaryURL
    }

    public func remove() throws {
        try? FileManager.default.removeItem(at: binaryURL)
    }

    /// Signs in using the Epic OAuth authorization code pasted from `EpicStorefront.loginURL`.
    public func authenticate(authorizationCode: String) throws {
        guard isInstalled else { throw GamePortError.missing("legendary is not installed") }
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw GamePortError.invalid("Epic authorization code is empty") }
        try paths.ensure(configDir)
        try Shell.run(binaryURL.path, ["auth", "--code", code], environment: toolEnvironment())
    }

    public func signOut() throws {
        guard isInstalled else { return }
        _ = try? Shell.run(binaryURL.path, ["auth", "--delete"], environment: toolEnvironment(), check: false)
        try? FileManager.default.removeItem(at: configDir.appendingPathComponent("user.json"))
    }

    public func accountDisplayName() -> String? {
        guard isInstalled, isSignedIn else { return nil }
        guard let res = try? Shell.run(binaryURL.path, ["status", "--json"], environment: toolEnvironment(), check: false),
              res.status == 0,
              let data = res.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["account"] as? String,
              account != "<not logged in>" else { return nil }
        return account
    }

    /// Lists owned & installed Windows Epic Games titles (parses `legendary list --json` + `installed.json`).
    public func listGames(includeUninstalled: Bool = true) throws -> [StorefrontGame] {
        guard isInstalled else { return [] }
        let installedMap = Self.parseInstalledJSON(at: configDir.appendingPathComponent("installed.json"), store: .epic)
        if !includeUninstalled || !isSignedIn {
            return installedMap.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        let res = try Shell.run(binaryURL.path, ["list", "--platform", "Windows", "--json"], environment: toolEnvironment())
        return Self.parseLibraryJSON(Data(res.output.utf8), installed: installedMap)
    }

    /// Downloads an Epic Games title natively on macOS (`--platform Windows`) with live progress updates.
    @discardableResult
    public func download(appName: String, baseDir: URL? = nil, progress: ProgressHandler? = nil) async throws -> URL {
        guard isInstalled else { throw GamePortError.missing("legendary is not installed") }
        guard isSignedIn else { throw GamePortError.missing("Sign in to Epic Games first") }
        let targetBase = baseDir ?? gamesDir
        try FileManager.default.createDirectory(at: targetBase, withIntermediateDirectories: true)
        let args = ["install", appName, "--platform", "Windows", "--base-path", targetBase.path, "-y"]
        let env = toolEnvironment()
        let bin = binaryURL

        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = args
            proc.environment = env
            proc.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()

            let handle = pipe.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl)
                    let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.contains("Progress:") || line.contains("Finished") || line.contains("ERROR") {
                        progress?(line)
                    }
                }
            }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw GamePortError.process("legendary install \(appName)", proc.terminationStatus)
            }
            return targetBase
        }.value
    }

    /// Resolves launch executable + Epic auth CLI arguments via `legendary launch --json`
    /// so GamePort can execute the game directly under CrossOver.app or PowerKit (zero Epic Launcher).
    public struct LaunchParameters: Sendable, Equatable {
        public let executable: URL
        public let arguments: [String]
        public let workingDirectory: URL
        public let environment: [String: String]
    }

    public func launchParameters(appName: String, offline: Bool = false) throws -> LaunchParameters {
        guard isInstalled else { throw GamePortError.missing("legendary is not installed") }
        var args = ["launch", appName, "--json"]
        if offline { args.append("--offline") }
        let res = try Shell.run(binaryURL.path, args, environment: toolEnvironment())
        return try Self.parseLaunchJSON(Data(res.output.utf8))
    }

    public static func parseLaunchJSON(_ data: Data) throws -> LaunchParameters {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gameDir = dict["game_directory"] as? String,
              let exeRel = dict["game_executable"] as? String else {
            throw GamePortError.invalid("legendary launch --json returned unexpected payload")
        }
        let dirURL = URL(fileURLWithPath: gameDir, isDirectory: true)
        let cleanRel = exeRel.replacingOccurrences(of: "\\", with: "/")
        let exeURL = cleanRel.hasPrefix("/") ? URL(fileURLWithPath: cleanRel) : dirURL.appendingPathComponent(cleanRel)
        let workDir = (dict["working_directory"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dirURL
        let gameArgs = (dict["game_parameters"] as? [String]) ?? []
        let eglArgs = (dict["egl_parameters"] as? [String]) ?? []
        let env = (dict["environment"] as? [String: String]) ?? [:]
        return LaunchParameters(
            executable: exeURL,
            arguments: eglArgs + gameArgs,
            workingDirectory: workDir,
            environment: env
        )
    }

    public static func parseInstalledJSON(at url: URL, store: StorefrontKind) -> [String: StorefrontGame] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: StorefrontGame] = [:]
        for (appName, raw) in root {
            guard let item = raw as? [String: Any] else { continue }
            guard let pathStr = item["install_path"] as? String, !pathStr.isEmpty else { continue }
            let title = (item["title"] as? String) ?? appName
            let exe = item["executable"] as? String
            let version = item["version"] as? String
            let size = (item["install_size"] as? NSNumber)?.int64Value
            result[appName] = StorefrontGame(
                store: store,
                appID: appName,
                title: title,
                installPath: URL(fileURLWithPath: pathStr, isDirectory: true),
                executableRelativePath: exe,
                version: version,
                artworkURL: nil,
                sizeBytes: size
            )
        }
        return result
    }

    public static func parseLibraryJSON(_ data: Data, installed: [String: StorefrontGame]) -> [StorefrontGame] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return installed.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        var games: [StorefrontGame] = []
        for entry in arr {
            guard let appName = entry["app_name"] as? String else { continue }
            let title = (entry["app_title"] as? String) ?? appName
            let meta = entry["metadata"] as? [String: Any]
            let images = meta?["keyImages"] as? [[String: Any]] ?? []
            let artStr = images.first(where: { ($0["type"] as? String) == "DieselGameBoxTall" })?["url"] as? String
                ?? images.first(where: { ($0["type"] as? String) == "DieselGameBox" })?["url"] as? String
                ?? images.first?["url"] as? String
            let inst = installed[appName]
            games.append(StorefrontGame(
                store: .epic,
                appID: appName,
                title: title,
                installPath: inst?.installPath,
                executableRelativePath: inst?.executableRelativePath,
                version: inst?.version,
                artworkURL: artStr.flatMap(URL.init(string:)),
                sizeBytes: inst?.sizeBytes
            ))
        }
        return games.sorted {
            if $0.isInstalled != $1.isInstalled { return $0.isInstalled }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

// MARK: - GOG (gogdl — separate CLI process, GPL-3, SHA-256 verified, 100% DRM-free)

/// Native macOS GOG client backed by upstream `heroic-gogdl` (executed as a separate process,
/// never linked or bundled). GOG games are DRM-free and launch straight onto CrossOver.app
/// or GamePort PowerKit with zero GOG Galaxy running in RAM.
public struct GOGStorefront: Sendable {
    public static let version = "v1.4.0"
    public static let downloadURL = URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/v1.4.0/gogdl_macos_arm64")!
    public static let sha256 = "af167d29ca822f495ff677d03c40bb9d6dc5535dac1f30d71775c91fe844149c"
    public static let loginURL = URL(string: "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=client2")!

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var toolDir: URL { paths.tools.appendingPathComponent("gog", isDirectory: true) }
    public var binaryURL: URL { toolDir.appendingPathComponent("gogdl") }
    public var authConfigURL: URL { toolDir.appendingPathComponent("auth.json") }
    public var gamesDir: URL { paths.root.appendingPathComponent("games/gog", isDirectory: true) }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    public var isSignedIn: Bool {
        guard let data = try? Data(contentsOf: authConfigURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return !dict.isEmpty
    }

    /// Downloads, SHA-256-verifies, and installs the native Apple Silicon `gogdl` binary.
    @discardableResult
    public func install(progress: ProgressHandler? = nil) async throws -> URL {
        try paths.ensure(paths.downloads, toolDir)
        let downloader = Downloader(cache: paths.downloads)
        let file = try await downloader.fetch(Self.downloadURL, sha256: Self.sha256, progress: progress)
        let staging = toolDir.appendingPathComponent("gogdl.staging-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: file, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        try? fm.removeItem(at: binaryURL)
        try fm.moveItem(at: staging, to: binaryURL)
        progress?("Installed gogdl \(Self.version) (arm64, SHA-256 verified)")
        return binaryURL
    }

    public func remove() throws {
        try? FileManager.default.removeItem(at: binaryURL)
    }

    /// Signs in using the GOG OAuth `code=...` token from `GOGStorefront.loginURL`.
    public func authenticate(authorizationCode: String) throws {
        guard isInstalled else { throw GamePortError.missing("gogdl is not installed") }
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw GamePortError.invalid("GOG authorization code is empty") }
        try paths.ensure(toolDir)
        try Shell.run(binaryURL.path, ["--auth-config-path", authConfigURL.path, "auth", "--code", code])
    }

    public func signOut() {
        try? FileManager.default.removeItem(at: authConfigURL)
    }

    /// Downloads a DRM-free Windows GOG game natively on macOS via `gogdl download`.
    @discardableResult
    public func download(gameID: String, installDir targetDir: URL? = nil, progress: ProgressHandler? = nil) async throws -> URL {
        guard isInstalled else { throw GamePortError.missing("gogdl is not installed") }
        guard isSignedIn else { throw GamePortError.missing("Sign in to GOG first") }
        let cleanID = gameID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, cleanID.allSatisfy(\.isNumber) else {
            throw GamePortError.invalid("GOG game ID must be numeric")
        }
        let dest = targetDir ?? gamesDir.appendingPathComponent(cleanID, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let args = [
            "--auth-config-path", authConfigURL.path,
            "download", cleanID,
            "--platform", "windows",
            "--path", dest.path,
        ]
        let bin = binaryURL

        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = args
            proc.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()

            let handle = pipe.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl)
                    let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.contains("%") || line.contains("Done") || line.contains("ERROR") {
                        progress?(line)
                    }
                }
            }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw GamePortError.process("gogdl download \(cleanID)", proc.terminationStatus)
            }
            return dest
        }.value
    }

    /// Scans `<root>/games/gog/` for installed GOG games using standard `goggame-*.info` manifests.
    public func listInstalled() -> [StorefrontGame] {
        Self.scanInstalledGames(in: gamesDir)
    }

    public static func scanInstalledGames(in root: URL) -> [StorefrontGame] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var games: [StorefrontGame] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let info = readGOGInfo(in: dir) {
                games.append(info)
            } else if let exe = SteamDepotManager.discoverMainExecutable(in: dir) {
                let rel = exe.path.replacingOccurrences(of: dir.path + "/", with: "")
                games.append(StorefrontGame(
                    store: .gog,
                    appID: dir.lastPathComponent,
                    title: dir.lastPathComponent,
                    installPath: dir,
                    executableRelativePath: rel
                ))
            }
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Reads standard `goggame-<id>.info` metadata written by GOG installers & `gogdl`.
    public static func readGOGInfo(in gameDir: URL) -> StorefrontGame? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: gameDir, includingPropertiesForKeys: nil),
              let infoFile = files.first(where: { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }),
              let data = try? Data(contentsOf: infoFile),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let gameID = (dict["gameId"] as? String) ?? (dict["rootGameId"] as? String) ?? gameDir.lastPathComponent
        let title = (dict["name"] as? String) ?? gameDir.lastPathComponent
        let tasks = dict["playTasks"] as? [[String: Any]] ?? []
        let primary = tasks.first(where: { ($0["isPrimary"] as? Bool) == true }) ?? tasks.first
        let exeRel = primary?["path"] as? String
        return StorefrontGame(
            store: .gog,
            appID: gameID,
            title: title,
            installPath: gameDir,
            executableRelativePath: exeRel
        )
    }

    public static func discoverPlayTaskExecutable(in gameDir: URL) -> URL? {
        guard let info = readGOGInfo(in: gameDir), let rel = info.executableRelativePath else { return nil }
        let clean = rel.replacingOccurrences(of: "\\", with: "/")
        let candidate = gameDir.appendingPathComponent(clean)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

// MARK: - Heroic Games Launcher Read-Only Library Auto-Discovery

/// Discovers Epic, GOG, and Amazon Windows games already installed via Heroic Games Launcher
/// so players switching to GamePort / ArcaneGamePort never have to re-download anything.
public enum HeroicDiscovery {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [StorefrontGame] {
        let heroicRoot = home.appendingPathComponent("Library/Application Support/heroic", isDirectory: true)
        var games: [StorefrontGame] = []

        // 1. Heroic Epic (legendary) installed.json
        let epicJSON = heroicRoot.appendingPathComponent("legendaryConfig/legendary/installed.json")
        games.append(contentsOf: EpicStorefront.parseInstalledJSON(at: epicJSON, store: .heroicEpic).values)

        // 2. Heroic GOG installed.json
        let gogJSON = heroicRoot.appendingPathComponent("gog_store/installed.json")
        games.append(contentsOf: parseHeroicGOGInstalled(at: gogJSON))

        // 3. Heroic Amazon (nile) installed.json
        let amazonJSON = heroicRoot.appendingPathComponent("nile_config/nile/installed.json")
        games.append(contentsOf: parseHeroicAmazonInstalled(at: amazonJSON))

        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static func parseHeroicGOGInstalled(at url: URL) -> [StorefrontGame] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = dict["installed"] as? [[String: Any]] else { return [] }
        return installed.compactMap { item in
            guard let appName = item["appName"] as? String,
                  let pathStr = item["install_path"] as? String, !pathStr.isEmpty else { return nil }
            let dir = URL(fileURLWithPath: pathStr, isDirectory: true)
            let info = GOGStorefront.readGOGInfo(in: dir)
            let title = info?.title ?? (item["title"] as? String) ?? dir.lastPathComponent
            return StorefrontGame(
                store: .heroicGOG,
                appID: appName,
                title: title,
                installPath: dir,
                executableRelativePath: info?.executableRelativePath,
                version: item["version"] as? String
            )
        }
    }

    public static func parseHeroicAmazonInstalled(at url: URL) -> [StorefrontGame] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let pathStr = item["path"] as? String, !pathStr.isEmpty else { return nil }
            let dir = URL(fileURLWithPath: pathStr, isDirectory: true)
            let title = (item["title"] as? String) ?? dir.lastPathComponent
            return StorefrontGame(
                store: .heroicAmazon,
                appID: id,
                title: title,
                installPath: dir,
                version: item["version"] as? String
            )
        }
    }
}
