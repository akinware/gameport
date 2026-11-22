import Foundation
#if canImport(CoreImage)
import CoreImage
#endif

// MARK: - DepotDownloader tool (GPL-2.0, downloaded on demand, run as a separate process)

/// SteamRE `DepotDownloader`, the self-contained Apple Silicon / Intel build (no .NET runtime needed).
/// GamePort downloads it on demand over HTTPS, verifies its SHA-256 before installing it,
/// and runs it only as a separate child process. Its code is never linked, copied, or bundled.
public struct DepotDownloaderTool: Sendable {
    public static let version = "3.4.0"
    public static let releaseTag = "DepotDownloader_3.4.0"

    public struct Asset: Sendable, Equatable {
        public let url: URL
        public let sha256: String
    }

    public static let arm64 = Asset(
        url: URL(string: "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-macos-arm64.zip")!,
        sha256: "60e80c7c496f3f9a079cd3c62036b35d088c27bc0149baf38f009eb57a52f6a5"
    )
    public static let x64 = Asset(
        url: URL(string: "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-macos-x64.zip")!,
        sha256: "3214b689564d73e9342a8a4aef693de6ad3d293801b0f300a4466f60ec75befb"
    )

    /// The release asset that matches this Mac's CPU.
    public static var hostAsset: Asset { Shell.isAppleSilicon ? arm64 : x64 }

    public let paths: Paths
    /// Folders searched for DepotDownloader's remembered-login store (`account.config`).
    public let tokenStoreRoots: [URL]

    public init(paths: Paths, tokenStoreRoots: [URL]? = nil) {
        self.paths = paths
        self.tokenStoreRoots = tokenStoreRoots ?? Self.defaultTokenStoreRoots(toolHome: paths.tools
            .appendingPathComponent("depotdownloader/home", isDirectory: true))
    }

    /// .NET isolated storage ignores `$HOME` on macOS and writes under the account's real home
    /// (`~/Library/Application Support/IsolatedStorage`), so look there as well as the private home.
    public static func defaultTokenStoreRoots(toolHome: URL) -> [URL] {
        var home = FileManager.default.homeDirectoryForCurrentUser
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return [
            home.appendingPathComponent("Library/Application Support/IsolatedStorage", isDirectory: true),
            home.appendingPathComponent(".local/share/IsolatedStorage", isDirectory: true),
            toolHome,
        ]
    }

    public var toolDir: URL { paths.tools.appendingPathComponent("depotdownloader", isDirectory: true) }
    public var logsDir: URL { toolDir.appendingPathComponent("logs", isDirectory: true) }
    public var binaryURL: URL { toolDir.appendingPathComponent("DepotDownloader") }
    /// Private working `HOME` for DepotDownloader (its remembered login still goes to .NET
    /// isolated storage in the real home; see `tokenStoreRoots`).
    public var homeDir: URL { toolDir.appendingPathComponent("home", isDirectory: true) }
    /// Account names that finished a QR sign-in with `-remember-password`. Holds no secrets.
    public var sessionFile: URL { toolDir.appendingPathComponent("session.json") }
    public var versionFile: URL { toolDir.appendingPathComponent("VERSION") }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
            && (try? String(contentsOf: versionFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.version
    }

    /// Downloads, SHA-256-verifies, unpacks and installs DepotDownloader into `<root>/tools/depotdownloader/`.
    @discardableResult
    public func install(progress: ProgressHandler? = nil) async throws -> URL {
        try paths.ensure(paths.downloads, paths.temp, toolDir)
        let asset = Self.hostAsset
        let archive = try await Downloader(cache: paths.downloads).fetch(asset.url, sha256: asset.sha256, progress: progress)

        let fm = FileManager.default
        let staging = paths.temp.appendingPathComponent("depotdownloader-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])

        let staged = staging.appendingPathComponent("DepotDownloader")
        guard fm.fileExists(atPath: staged.path) else {
            throw GamePortError.invalid("DepotDownloader archive did not contain the DepotDownloader binary")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        try? fm.removeItem(at: binaryURL)
        try fm.moveItem(at: staged, to: binaryURL)
        let license = staging.appendingPathComponent("LICENSE")
        if fm.fileExists(atPath: license.path) {
            let dest = toolDir.appendingPathComponent("LICENSE")
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: license, to: dest)
        }
        try Self.version.write(to: versionFile, atomically: true, encoding: .utf8)
        progress?("Installed DepotDownloader \(Self.version) (\(Shell.isAppleSilicon ? "arm64" : "x64"), SHA-256 verified, GPL-2.0)")
        return binaryURL
    }

    public func remove() throws {
        try? FileManager.default.removeItem(at: binaryURL)
        try? FileManager.default.removeItem(at: versionFile)
    }

    // MARK: Remembered sessions

    struct SessionRecord: Codable, Equatable {
        var accounts: [String]
    }

    /// Accounts with a remembered DepotDownloader login, most recent first.
    public func rememberedAccounts() -> [String] {
        guard let data = try? Data(contentsOf: sessionFile),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return [] }
        let stores = tokenStores().map(\.contents)
        return record.accounts.filter { account in stores.contains { Self.store($0, holds: account) } }
    }

    /// True when DepotDownloader holds a remembered login token for any account.
    public var hasStoredLoginTokens: Bool { !tokenStores().isEmpty }

    /// DepotDownloader `account.config` files (raw-deflate protobuf) with their inflated contents.
    func tokenStores() -> [(url: URL, contents: Data)] {
        var found: [(URL, Data)] = []
        for root in tokenStoreRoots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.lastPathComponent == "account.config" {
                guard let raw = try? Data(contentsOf: url), let inflated = Self.inflate(raw) else { continue }
                found.append((url, inflated))
            }
        }
        return found
    }

    static func inflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        // Apple's "zlib" algorithm is raw DEFLATE, which is what .NET's DeflateStream writes.
        return try? (data as NSData).decompressed(using: .zlib) as Data
    }

    static func store(_ contents: Data, holds account: String) -> Bool {
        let needle = Data(account.utf8)
        return !needle.isEmpty && contents.range(of: needle) != nil
    }

    /// Picks the account to sign in silently with: `preferred` (e.g. the Mac Steam account) when its
    /// login is remembered, otherwise the most recently remembered account, otherwise nil (QR needed).
    public func cachedAccount(preferred: String? = nil) -> String? {
        let accounts = rememberedAccounts()
        if let preferred = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty,
           let hit = accounts.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
            return hit
        }
        return accounts.first
    }

    public func rememberAccount(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var accounts = (try? Data(contentsOf: sessionFile)).flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }?.accounts ?? []
        accounts.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        accounts.insert(name, at: 0)
        try? FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(SessionRecord(accounts: accounts)) {
            try? data.write(to: sessionFile, options: .atomic)
        }
    }

    public func forgetAccount(_ name: String) {
        guard let data = try? Data(contentsOf: sessionFile),
              var record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return }
        record.accounts.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if let out = try? JSONEncoder().encode(record) { try? out.write(to: sessionFile, options: .atomic) }
    }

    /// Signs out of every remembered account: deletes DepotDownloader's token store(s) that hold
    /// a GamePort-remembered account, its private home, and the session record.
    public func signOutAll() {
        let accounts = (try? Data(contentsOf: sessionFile)).flatMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }?.accounts ?? []
        for store in tokenStores() where accounts.contains(where: { Self.store(store.contents, holds: $0) }) {
            try? FileManager.default.removeItem(at: store.url)
        }
        try? FileManager.default.removeItem(at: homeDir)
        try? FileManager.default.removeItem(at: sessionFile)
    }

    // MARK: Running processes

    /// PIDs of DepotDownloader processes started from this install, optionally only those
    /// downloading into `directory`.
    public func runningProcesses(directory: URL? = nil) -> [Int32] {
        guard let res = try? Shell.run("/bin/ps", ["-axww", "-o", "pid=,command="]) else { return [] }
        return Self.matchingPIDs(psOutput: res.output, binary: binaryURL.path, directory: directory?.path)
    }

    static func matchingPIDs(psOutput: String, binary: String, directory: String?) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { return nil }
            let command = line[space...].trimmingCharacters(in: .whitespaces)
            guard command.hasPrefix(binary + " ") || command == binary else { return nil }
            if let directory {
                guard command.contains(" -dir \(directory) ") || command.hasSuffix(" -dir \(directory)") else { return nil }
            }
            return pid
        }
    }

    /// Stops DepotDownloader processes (all of them, or those writing into `directory`):
    /// SIGTERM, then SIGKILL after `timeout`. Returns how many were stopped.
    @discardableResult
    public func stopRunning(directory: URL? = nil, timeout: TimeInterval = 5) -> Int {
        let pids = runningProcesses(directory: directory)
        guard !pids.isEmpty else { return 0 }
        pids.forEach { kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(100_000)
        }
        pids.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
        return pids.count
    }

    // MARK: Arguments

    public enum Login: Sendable, Equatable {
        /// First sign-in: show a QR code for the Steam Mobile App and remember the session.
        case qrCode
        /// Later sign-ins: reuse the token DepotDownloader remembered for this account.
        case remembered(account: String)
        /// Free / dedicated-server content that needs no account.
        case anonymous
    }

    /// DepotDownloader arguments for downloading the Windows build of `appID` into `directory`.
    public static func arguments(appID: Int, directory: URL, login: Login, validate: Bool = false) -> [String] {
        var args = ["-app", String(appID), "-os", "windows", "-osarch", "64", "-dir", directory.path]
        switch login {
        case .qrCode: args += ["-qr", "-remember-password"]
        case .remembered(let account): args += ["-username", account, "-remember-password"]
        case .anonymous: break
        }
        if validate { args.append("-validate") }
        // A distinct logon ID per app lets several downloads run at once without kicking each other off.
        args += ["-loginid", String(loginID(appID: appID))]
        return args
    }

    static func loginID(appID: Int) -> UInt32 {
        0x4750_0000 | UInt32(truncatingIfNeeded: appID & 0xF_FFFF)
    }
}

// MARK: - QR code

/// A Steam sign-in QR code as printed by DepotDownloader, as a module matrix (`true` = dark).
public struct SteamQRCode: Sendable, Equatable {
    public let modules: [[Bool]]
    /// The `https://s.team/q/...` challenge URL, when the matrix could be decoded.
    public let url: String?

    public var size: Int { modules.count }

    public init(modules: [[Bool]], url: String? = nil) {
        self.modules = modules
        self.url = url
    }

    /// Parses DepotDownloader's ASCII QR (two characters per module, `██` = dark) and trims the
    /// quiet zone. Returns nil unless the result is a square matrix of a valid QR size.
    public static func parse(asciiLines: [String]) -> SteamQRCode? {
        var rows: [[Bool]] = asciiLines.map { line in
            let chars = Array(line)
            return stride(from: 0, to: chars.count - 1, by: 2).map { chars[$0] == "█" || chars[$0 + 1] == "█" }
        }
        rows.removeAll { !$0.contains(true) }
        guard !rows.isEmpty else { return nil }
        let first = rows.compactMap { $0.firstIndex(of: true) }.min() ?? 0
        let last = rows.compactMap { $0.lastIndex(of: true) }.max() ?? 0
        let width = last - first + 1
        let trimmed = rows.map { row -> [Bool] in
            (first...last).map { $0 < row.count ? row[$0] : false }
        }
        guard trimmed.count == width, width >= 21, (width - 17) % 4 == 0 else { return nil }
        return SteamQRCode(modules: trimmed, url: decodeURL(modules: trimmed))
    }

    /// Compact terminal rendering (two rows per character line, with a quiet zone), for the CLI.
    public func terminalArt(quietZone: Int = 2) -> String {
        let n = size + quietZone * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let mx = x - quietZone, my = y - quietZone
            guard mx >= 0, my >= 0, mx < size, my < size else { return false }
            return modules[my][mx]
        }
        var lines: [String] = []
        for y in stride(from: 0, to: n, by: 2) {
            var line = ""
            for x in 0..<n {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Decodes the matrix back to its URL with Core Image, so the UI can render a crisp native
    /// QR code (and offer the link) instead of relying on the terminal art.
    public static func decodeURL(modules: [[Bool]]) -> String? {
        #if canImport(CoreImage) && os(macOS)
        let quiet = 4, scale = 8
        let n = modules.count
        let side = (n + quiet * 2) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for (y, row) in modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale {
                    let base = ((y + quiet) * scale + dy) * side + (x + quiet) * scale
                    for dx in 0..<scale { pixels[base + dx] = 0 }
                }
            }
        }
        let data = Data(pixels)
        let image = CIImage(
            bitmapData: data,
            bytesPerRow: side,
            size: CGSize(width: side, height: side),
            format: .L8,
            colorSpace: CGColorSpace(name: CGColorSpace.linearGray)
        )
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: image) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
        #else
        return nil
        #endif
    }
}

// MARK: - Events & output parsing

/// What the in-app Steam QR downloader is doing right now.
public enum SteamQRDownloadEvent: Sendable, Equatable {
    case installingTool(String)
    case status(String)
    case qrCode(SteamQRCode)
    case waitingForMobileApproval
    case signedIn(account: String)
    case downloading(percent: Double, detail: String)
    /// An update of an already finished download ended: `changed` is false when it was up to date.
    case updateChecked(changed: Bool)
    case completed(directory: URL, executable: URL?)
}

/// Turns DepotDownloader's stdout into `SteamQRDownloadEvent`s. Pure and line-based, so it is unit tested.
public struct DepotDownloaderOutputParser: Sendable {
    public enum Failure: Sendable, Equatable {
        /// The remembered login token was rejected or is missing: sign in with a QR code again.
        case needsQRLogin(String)
        case fatal(String)
    }

    public struct Output: Sendable, Equatable {
        public var events: [SteamQRDownloadEvent] = []
        public var failure: Failure?
    }

    private var qrLines: [String]? = nil
    private var qrWidth: Int? = nil
    private var qrRowsSinceFirstDark = 0
    private var depotsStarted = 0
    public private(set) var signedInAccount: String?
    public private(set) var lastError: String?

    public init() {}

    static let qrHeader = "Use the Steam Mobile App to sign in with this QR code:"

    public mutating func consume(_ rawLine: String) -> Output {
        var out = Output()
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))

        if var collecting = qrLines {
            if line.allSatisfy({ $0 == " " || $0 == "█" }) {
                collecting.append(line)
                if line.contains("█") {
                    if qrWidth == nil, let f = line.firstIndex(of: "█"), let l = line.lastIndex(of: "█") {
                        // The top row spans both finder patterns: it sets the module width.
                        qrWidth = (line.distance(from: f, to: l) + 1) / 2
                    }
                }
                if qrWidth != nil { qrRowsSinceFirstDark += 1 }
                qrLines = collecting
                if let w = qrWidth, qrRowsSinceFirstDark >= w {
                    flushQR(into: &out)
                }
                return out
            }
            flushQR(into: &out)
        }

        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return out }

        if text == Self.qrHeader {
            qrLines = []
            qrWidth = nil
            qrRowsSinceFirstDark = 0
            return out
        }
        if text == "The QR code has changed:" {
            out.events.append(.status("Steam refreshed the QR code"))
            return out
        }
        if text.hasPrefix("Connecting to Steam3") {
            out.events.append(.status("Connecting to Steam…"))
        } else if text.hasPrefix("Logging in with QR code") {
            out.events.append(.status("Requesting a sign-in QR code…"))
        } else if text.hasPrefix("Logging anonymously") {
            out.events.append(.status("Signing in anonymously…"))
        } else if let account = Self.capture(text, prefix: "Logging '", suffix: "' into Steam3...") {
            signedInAccount = account
            out.events.append(.signedIn(account: account))
        } else if let account = Self.capture(text, prefix: "Success! Next time you can login with -username ", suffix: " -remember-password instead of -qr.") {
            signedInAccount = account
        } else if text.hasPrefix("Got AppInfo for") {
            out.events.append(.status("Reading game info…"))
        } else if text.hasPrefix("Got ") && text.contains("licenses for account") {
            out.events.append(.status("Signed in — checking your licenses…"))
        } else if let depot = Self.capture(text, prefix: "Processing depot ", suffix: "") {
            depotsStarted += 1
            out.events.append(.status("Preparing depot \(depot)…"))
        } else if text.hasPrefix("Pre-allocating ") {
            out.events.append(.downloading(percent: 0, detail: "Preparing \(Self.fileName(String(text.dropFirst("Pre-allocating ".count))))"))
        } else if text.hasPrefix("Validating ") {
            out.events.append(.status("Validating \(Self.fileName(String(text.dropFirst("Validating ".count))))"))
        } else if let (pct, path) = Self.progress(text) {
            let depotNote = depotsStarted > 1 ? "Depot \(depotsStarted) · " : ""
            out.events.append(.downloading(percent: pct, detail: depotNote + Self.fileName(path)))
        } else if text.hasPrefix("Access token was rejected") {
            out.failure = .needsQRLogin(text)
        } else if text.hasPrefix("Enter account password for") || text.contains("has stored credentials. Did you forget") {
            out.failure = .needsQRLogin("Steam asked for a password; the remembered sign-in is missing")
        } else if text.hasPrefix("Please enter your 2 factor auth code") || text.hasPrefix("Please enter the authentication code") {
            out.failure = .needsQRLogin("Steam asked for a Steam Guard code; sign in with the QR code instead")
        } else if text.contains("is not available from this account") {
            lastError = "This game is not owned by the signed-in Steam account (\(text))"
            out.failure = .fatal(lastError!)
        } else if text.hasPrefix("Error:") || text.hasPrefix("Unable to login") || text.hasPrefix("Failed to authenticate")
                    || text.hasPrefix("Couldn't find any depots") || text.hasPrefix("Download failed")
                    || text.hasPrefix("Could not connect to Steam") || text.contains("was not completely downloaded")
                    || text.hasPrefix("No valid depot key") || text.hasPrefix("Encountered ")
                    || text.hasPrefix("Failed to find any server") || text.hasPrefix("Lost connection to Steam")
                    || text.hasPrefix("Unable to ") || text.hasPrefix("Failed to ") {
            if lastError == nil || !text.hasPrefix("Error: InitializeSteam failed") { lastError = text }
        }
        return out
    }

    private mutating func flushQR(into out: inout Output) {
        if let lines = qrLines, let code = SteamQRCode.parse(asciiLines: lines) {
            out.events.append(.qrCode(code))
            out.events.append(.waitingForMobileApproval)
        }
        qrLines = nil
        qrWidth = nil
        qrRowsSinceFirstDark = 0
    }

    static func capture(_ text: String, prefix: String, suffix: String) -> String? {
        guard text.hasPrefix(prefix), suffix.isEmpty || text.hasSuffix(suffix) else { return nil }
        let value = text.dropFirst(prefix.count).dropLast(suffix.count)
        return value.isEmpty ? nil : String(value)
    }

    /// Parses `" 36.60% /path/to/file"` progress lines.
    static func progress(_ text: String) -> (Double, String)? {
        guard let pctEnd = text.firstIndex(of: "%") else { return nil }
        guard let value = Double(text[..<pctEnd]), value.isFinite else { return nil }
        let rest = text[text.index(after: pctEnd)...].trimmingCharacters(in: .whitespaces)
        return (min(max(value, 0), 100), rest)
    }

    static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

// MARK: - Downloader

public enum SteamQRDownloadError: Error, CustomStringConvertible, Equatable {
    case signInFailed(String)
    case failed(status: Int32, detail: String?)

    public var description: String {
        switch self {
        case .signInFailed(let why): return "Steam sign-in failed: \(why)"
        case .failed(let status, let detail):
            return "Download stopped (DepotDownloader exit \(status))" + (detail.map { ": \($0)" } ?? "")
        }
    }
}

/// Native in-app Steam game downloader: signs in with a Steam Mobile App QR code once (no password
/// ever typed or seen by GamePort), then downloads the Windows depots of a game straight into
/// `SteamDepotManager.depotDirectory(appID:)` with live progress.
public struct SteamQRDownloader: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var tool: DepotDownloaderTool { DepotDownloaderTool(paths: paths) }
    public var depots: SteamDepotManager { SteamDepotManager(paths: paths) }

    /// True when a download can start without showing the QR code (a remembered session exists).
    public func canSignInSilently(preferredAccount: String? = nil) -> Bool {
        tool.cachedAccount(preferred: preferredAccount) != nil
    }

    /// Downloads the Windows build of `appID`. The stream ends after `.completed`, or throws.
    /// Cancelling the consuming task (or dropping the stream) terminates DepotDownloader.
    ///
    /// - Parameters:
    ///   - preferredAccount: usually `ExternalDiscovery.macSteamAccountName()`; used to pick a
    ///     remembered session. When none is remembered a QR code is shown.
    ///   - anonymous: download free/dedicated-server content without signing in.
    public func download(
        appID: Int,
        title: String? = nil,
        installDir: URL? = nil,
        preferredAccount: String? = nil,
        anonymous: Bool = false,
        validate: Bool = false
    ) -> AsyncThrowingStream<SteamQRDownloadEvent, Error> {
        let destination = installDir ?? depots.depotDirectory(appID: appID)
        let tool = self.tool
        return AsyncThrowingStream { continuation in
            let runner = ProcessBox()
            let task = Task.detached(priority: .userInitiated) {
                do {
                    if !tool.isInstalled {
                        continuation.yield(.installingTool("Installing DepotDownloader \(DepotDownloaderTool.version)…"))
                        try await tool.install { msg in continuation.yield(.installingTool(msg)) }
                    }
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: tool.homeDir, withIntermediateDirectories: true)
                    // A (re-)download is not playable until DepotDownloader exits cleanly. Create
                    // its work folder first so a new download reads as "in progress" from the start.
                    // An update keeps its finished manifest (so the game stays playable) until files
                    // actually start changing: a failed sign-in or an up-to-date check breaks nothing.
                    let manifest = SteamDepotManager.appManifestURL(appID: appID, in: destination)
                    let updating = FileManager.default.fileExists(atPath: manifest.path)
                    let before = SteamDepotManager.downloadedManifests(in: destination)
                    try FileManager.default.createDirectory(at: destination.appendingPathComponent(".DepotDownloader"), withIntermediateDirectories: true)
                    var manifestRemoved = false
                    let onEvent: (SteamQRDownloadEvent) -> Void = { event in
                        // DepotDownloader walks every file with a running percentage even when nothing
                        // changes. A new version shows up as a new depot manifest, saved before any
                        // game file is touched: only then is the game "being updated".
                        if case .downloading = event, !manifestRemoved,
                           SteamDepotManager.downloadedManifests(in: destination) != before {
                            manifestRemoved = true
                            try? FileManager.default.removeItem(at: manifest)
                        }
                        continuation.yield(event)
                    }

                    // A download of this game left running by an earlier session (e.g. the app quit
                    // mid-download) would fight this one for the same files and Steam logon ID.
                    // Stop it; DepotDownloader validates what is already on disk and resumes.
                    if tool.stopRunning(directory: destination) > 0 {
                        continuation.yield(.status("Resuming a download started earlier…"))
                    }

                    var login: DepotDownloaderTool.Login
                    if anonymous { login = .anonymous }
                    else if let acct = tool.cachedAccount(preferred: preferredAccount) { login = .remembered(account: acct) }
                    else { login = .qrCode }

                    var attempt = 0
                    while true {
                        attempt += 1
                        try Task.checkCancellation()
                        if case .remembered(let acct) = login {
                            continuation.yield(.status("Signing in as \(acct) (remembered)…"))
                        }
                        let result = try runner.run(
                            tool: tool,
                            arguments: DepotDownloaderTool.arguments(appID: appID, directory: destination, login: login, validate: validate),
                            onEvent: onEvent
                        )
                        if let account = result.signedInAccount, login != .anonymous {
                            tool.rememberAccount(account)
                        }
                        switch result.outcome {
                        case .success:
                            if updating {
                                let changed = SteamDepotManager.downloadedManifests(in: destination) != before
                                continuation.yield(.updateChecked(changed: changed))
                            }
                            let exe = SteamDepotManager.mainExecutable(appID: appID, in: destination, preferredName: title, paths: paths)
                            try SteamDepotManager.markDownloadComplete(
                                appID: appID,
                                name: title ?? "App \(appID)",
                                in: destination
                            )
                            continuation.yield(.completed(directory: destination, executable: exe))
                            continuation.finish()
                            return
                        case .needsQRLogin(let why):
                            if case .remembered(let acct) = login, attempt == 1 {
                                tool.forgetAccount(acct)
                                continuation.yield(.status("Remembered sign-in expired (\(why)). Showing a QR code…"))
                                login = .qrCode
                                continue
                            }
                            throw SteamQRDownloadError.signInFailed(why)
                        case .failed(let code, let message):
                            throw SteamQRDownloadError.failed(status: code, detail: message)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                runner.terminate()
            }
        }
    }
}

/// Owns the running DepotDownloader child process so cancellation can terminate it.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    enum Outcome: Equatable {
        case success
        case needsQRLogin(String)
        case failed(Int32, String?)
    }

    struct Result {
        var outcome: Outcome
        var signedInAccount: String?
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func run(tool: DepotDownloaderTool, arguments: [String], onEvent: (SteamQRDownloadEvent) -> Void) throws -> Result {
        let proc = Process()
        proc.executableURL = tool.binaryURL
        proc.arguments = arguments
        proc.currentDirectoryURL = tool.toolDir
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tool.homeDir.path
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        env["DOTNET_NOLOGO"] = "1"
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = proc
        lock.unlock()
        try proc.run()

        try? FileManager.default.createDirectory(at: tool.logsDir, withIntermediateDirectories: true)
        let logURL = tool.logsDir.appendingPathComponent("\(Self.appID(in: arguments) ?? "download").log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data("$ DepotDownloader \(Self.redacted(arguments).joined(separator: " "))\n".utf8))
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()
        defer { try? log?.close() }
        var recent: [String] = []

        var parser = DepotDownloaderOutputParser()
        var needsQR: String? = nil
        var fatal: String? = nil
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        func handleLine(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isQRArt = !trimmed.isEmpty && trimmed.allSatisfy { $0 == "█" || $0 == " " }
            if !isQRArt {
                log?.write(data + Data([0x0A]))
                if !trimmed.isEmpty, DepotDownloaderOutputParser.progress(trimmed) == nil, !trimmed.hasPrefix("Pre-allocating ") {
                    recent.append(trimmed)
                    if recent.count > 12 { recent.removeFirst(recent.count - 12) }
                }
            }
            let out = parser.consume(text)
            out.events.forEach(onEvent)
            switch out.failure {
            case .needsQRLogin(let why)?:
                needsQR = why
                // DepotDownloader would block on a prompt we can never answer: stop it now.
                if proc.isRunning { proc.terminate() }
            case .fatal(let why)?:
                fatal = why
            case nil: break
            }
        }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                handleLine(buffer.prefix(upTo: nl))
                buffer.removeSubrange(...nl)
            }
        }
        if !buffer.isEmpty { handleLine(buffer) }
        proc.waitUntilExit()

        lock.lock()
        let wasCancelled = cancelled
        process = nil
        lock.unlock()
        if wasCancelled { throw CancellationError() }

        if let needsQR { return Result(outcome: .needsQRLogin(needsQR), signedInAccount: nil) }
        if proc.terminationStatus == 0 && fatal == nil {
            return Result(outcome: .success, signedInAccount: parser.signedInAccount)
        }
        if parser.lastError?.hasPrefix("Unable to login to Steam3") == true, arguments.contains("-username") {
            return Result(outcome: .needsQRLogin(parser.lastError!), signedInAccount: nil)
        }
        let detail = fatal ?? parser.lastError ?? recent.last(where: { !$0.hasPrefix("Disconnected from Steam") }) ?? recent.last
        let message = [detail, "log: \(logURL.path)"].compactMap { $0 }.joined(separator: " — ")
        return Result(outcome: .failed(proc.terminationStatus, message), signedInAccount: parser.signedInAccount)
    }

    static func appID(in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "-app"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Arguments as written to the log (no secrets are ever passed, but keep account names out).
    static func redacted(_ arguments: [String]) -> [String] {
        var out = arguments
        if let i = out.firstIndex(of: "-username"), i + 1 < out.count { out[i + 1] = "<account>" }
        return out
    }
}
