import Foundation

/// Native macOS Windows Steam depot downloader powered by Valve's official `steamcmd`.
/// Downloads Windows game files natively on macOS (`+@sSteamCmdForcePlatformType windows`)
/// without needing to install or run Windows Steam under Wine/Rosetta.
///
/// GamePort never bundles, mirrors, or modifies `steamcmd`, and never stores Steam passwords;
/// Steam Guard authentication and cached login tokens are managed directly by Valve's `steamcmd`.
public struct SteamDepotManager: Sendable {
    public static let steamCmdURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var installDir: URL { paths.tools.appendingPathComponent("steamcmd", isDirectory: true) }
    public var executableURL: URL { installDir.appendingPathComponent("steamcmd.sh") }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    /// Downloads and extracts Valve's official macOS `steamcmd` tarball into `<root>/tools/steamcmd/`.
    public func install(progress: ProgressHandler? = nil) async throws {
        try paths.ensure(paths.downloads, paths.tools)
        let downloader = Downloader(cache: paths.downloads)
        let archive = try await downloader.fetch(Self.steamCmdURL, sha256: nil, progress: progress)
        progress?("steamcmd_osx.tar.gz SHA-256: \(try Checksum.sha256(file: archive))")

        let fm = FileManager.default
        let staging = paths.temp.appendingPathComponent("steamcmd-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        let stagedScript = staging.appendingPathComponent("steamcmd.sh")
        guard fm.fileExists(atPath: stagedScript.path) else {
            throw GamePortError.invalid("steamcmd archive did not contain steamcmd.sh")
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedScript.path)

        try? fm.removeItem(at: installDir)
        try fm.moveItem(at: staging, to: installDir)
        progress?("Installed Valve steamcmd at \(installDir.path)")
    }

    /// Builds the official `steamcmd` argument list for downloading a Windows Steam app natively on macOS.
    public static func downloadArguments(
        appID: Int,
        installDir: URL,
        username: String = "anonymous",
        validate: Bool = true
    ) -> [String] {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = trimmedUser.isEmpty ? "anonymous" : trimmedUser
        var args = [
            "+@sSteamCmdForcePlatformType", "windows",
            "+force_install_dir", installDir.path,
            "+login", user,
            "+app_update", String(appID),
        ]
        if validate { args.append("validate") }
        args.append("+quit")
        return args
    }

    /// Parses progress percentage (`0.0 ... 100.0`) from a `steamcmd` stdout line, if present.
    public static func parseProgressPercent(from line: String) -> Double? {
        guard let range = line.range(of: "progress:") else { return nil }
        let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let token = tail.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(token), value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    /// Runs `steamcmd` interactively (attached to the terminal so Steam Guard prompts work cleanly)
    /// to download a Windows Steam app directly into `installDir`.
    @discardableResult
    public func downloadAttached(
        appID: Int,
        installDir targetDir: URL,
        username: String = "anonymous",
        validate: Bool = true
    ) throws -> Int32 {
        guard isInstalled else {
            throw GamePortError.missing("steamcmd is not installed (run `\(Brand.cliName) bridge install-steamcmd`)")
        }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let args = Self.downloadArguments(appID: appID, installDir: targetDir, username: username, validate: validate)
        var env = ProcessInfo.processInfo.environment
        // Keep steamcmd's own cached Steam Guard credentials inside GamePort's tools dir.
        env["HOME"] = installDir.path
        return try Shell.runAttached(executableURL.path, args, environment: env)
    }

    /// Writes a standard Valve `appmanifest_<appID>.acf` file so GamePort and Arcane scanners
    /// recognize the natively downloaded Windows game folder.
    public static func writeAppManifest(
        appID: Int,
        name: String,
        installDirName: String,
        into steamappsDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: steamappsDir, withIntermediateDirectories: true)
        let escapedName = name.replacingOccurrences(of: "\"", with: "")
        let escapedDir = installDirName.replacingOccurrences(of: "\"", with: "")
        let content = """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"Universe"\t\t"1"
        \t"name"\t\t"\(escapedName)"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"\(escapedDir)"
        }
        """
        let manifestURL = steamappsDir.appendingPathComponent("appmanifest_\(appID).acf")
        try content.write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    /// Ranks candidate Windows `.exe` files inside a downloaded depot folder to locate the main game executable,
    /// skipping redistributables, uninstallers, crash handlers, and anti-cheat installers.
    public static func discoverMainExecutable(in installDir: URL, preferredName: String? = nil) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: installDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let skipTokens = [
            "unins", "vcredist", "dxsetup", "dotnet", "ndp", "redist",
            "crashreport", "crashhandler", "crashpad", "bugsplat", "ue4prereq", "ueprereq",
            "easyanticheat_eos_setup", "easyanticheat_setup", "battleye", "installscript",
            "directx", "physx", "openal", "oalinst", "vc_redist", "unitycrashhandler",
            "cefprocess", "webhelper", "steamerrorreporter", "activationui",
        ]

        let normPreferred = preferredName?
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        var candidates: [(url: URL, score: Int, size: Int64)] = []
        let baseDepth = installDir.standardizedFileURL.pathComponents.count

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "exe" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }

            let lowerPath = fileURL.path.lowercased()
            let lowerName = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            if skipTokens.contains(where: { lowerName.contains($0) || lowerPath.contains("/_commonredist/") || lowerPath.contains("/redist/") }) {
                continue
            }

            let depth = max(0, fileURL.standardizedFileURL.pathComponents.count - baseDepth - 1)
            let size = Int64(values.fileSize ?? 0)
            var score = 0

            // Prefer shallower paths (top-level or Binaries/Win64) and 64-bit shipping binaries.
            score -= depth * 12
            if lowerName.contains("win64-shipping") || lowerName.contains("-shipping") { score += 50 }
            if lowerName.contains("x64") || lowerName.contains("64") { score += 15 }
            if lowerName.contains("launcher") { score -= 5 }
            if let normPreferred, !normPreferred.isEmpty {
                let normExe = lowerName.filter { $0.isLetter || $0.isNumber }
                if normExe == normPreferred { score += 80 }
                else if normExe.contains(normPreferred) || normPreferred.contains(normExe) { score += 40 }
            }
            // Larger binaries are far more likely to be the game itself than tiny helper stubs.
            if size >= 5 * 1024 * 1024 { score += 25 }
            else if size >= 1 * 1024 * 1024 { score += 10 }

            candidates.append((fileURL, score, size))
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.size > rhs.size
            }
            .first?.url
    }
}
