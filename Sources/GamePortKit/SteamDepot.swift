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

    /// Default depot destination folder for a Steam AppID inside GamePort's tools directory.
    public func depotDirectory(appID: Int) -> URL {
        paths.tools.appendingPathComponent("depots/\(appID)", isDirectory: true)
    }

    /// The main Windows game `.exe` of a *finished* depot download for `appID`, if any.
    /// Partially downloaded depots (DepotDownloader pre-allocates every file up front) are ignored.
    public func downloadedExecutable(appID: Int, preferredName: String? = nil) -> URL? {
        let dir = depotDirectory(appID: appID)
        guard FileManager.default.fileExists(atPath: dir.path),
              Self.isDownloadComplete(appID: appID, in: dir) else { return nil }
        return Self.discoverMainExecutable(in: dir, preferredName: preferredName)
    }

    /// `<dir>/steamapps/appmanifest_<appID>.acf`, written by steamcmd and by GamePort's QR downloader.
    public static func appManifestURL(appID: Int, in dir: URL) -> URL {
        dir.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
    }

    /// Whether a depot folder holds a finished download:
    /// - an app manifest exists: finished only when it reports `StateFlags` 4 (fully installed);
    /// - a DepotDownloader work folder exists without a manifest: still downloading (or interrupted);
    /// - neither: a legacy folder, treated as finished.
    public static func isDownloadComplete(appID: Int, in dir: URL) -> Bool {
        let fm = FileManager.default
        let manifest = appManifestURL(appID: appID, in: dir)
        if let text = try? String(contentsOf: manifest, encoding: .utf8) {
            return text.range(of: #""StateFlags"\s+"4""#, options: .regularExpression) != nil
        }
        return !fm.fileExists(atPath: dir.appendingPathComponent(".DepotDownloader").path)
    }

    /// Marks a DepotDownloader download as finished by writing a standard `appmanifest_<appID>.acf`
    /// (`StateFlags` 4) into `<dir>/steamapps/`.
    public static func markDownloadComplete(appID: Int, name: String, in dir: URL) throws {
        try writeAppManifest(
            appID: appID,
            name: name,
            installDirName: dir.lastPathComponent,
            into: dir.appendingPathComponent("steamapps", isDirectory: true)
        )
    }

    /// Runs `steamcmd` asynchronously with streamed line-by-line progress (suitable for SwiftUI apps).
    /// For Steam accounts that need interactive Steam Guard / password entry, use `openInteractiveTerminalDownload`.
    @discardableResult
    public func download(
        appID: Int,
        installDir targetDir: URL? = nil,
        username: String = "anonymous",
        validate: Bool = true,
        progress: ProgressHandler? = nil
    ) async throws -> URL {
        guard isInstalled else {
            throw GamePortError.missing("steamcmd is not installed")
        }
        let destination = targetDir ?? depotDirectory(appID: appID)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let args = Self.downloadArguments(appID: appID, installDir: destination, username: username, validate: validate)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = installDir.path

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = args
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()

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
                    if !line.isEmpty {
                        if let pct = Self.parseProgressPercent(from: line) {
                            progress?(String(format: "Downloading AppID %d: %.1f%%", appID, pct))
                        } else if line.contains("Success!") || line.contains("ERROR") || line.contains("FAILED") {
                            progress?(line)
                        }
                    }
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GamePortError.process("steamcmd app_update \(appID)", process.terminationStatus)
            }
            return destination
        }.value
    }

    /// Opens macOS Terminal.app running `steamcmd` interactively so the user can enter their
    /// Steam password & Steam Guard code safely without GamePort ever seeing credentials.
    public func launchInteractiveTerminalDownload(
        appID: Int,
        username: String,
        installDir targetDir: URL? = nil
    ) throws {
        guard isInstalled else {
            throw GamePortError.missing("steamcmd is not installed")
        }
        let destination = targetDir ?? depotDirectory(appID: appID)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "anonymous" : username.trimmingCharacters(in: .whitespacesAndNewlines)
        func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = [
            "HOME=\(shQuote(installDir.path))",
            shQuote(executableURL.path),
            "+@sSteamCmdForcePlatformType windows",
            "+force_install_dir \(shQuote(destination.path))",
            "+login \(shQuote(cleanUser))",
            "+app_update \(appID) validate",
            "+quit",
        ].joined(separator: " ")

        let script = paths.temp.appendingPathComponent("steamcmd-download-\(appID).command")
        try paths.ensure(paths.temp)
        let body = "#!/bin/bash\nset -e\necho \"GamePort Native Windows Steam Depot Download (AppID \(appID))\"\n\(cmd)\necho \"Done! You can close this window and click Play via Bridge in GamePort.\"\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Shell.run("/usr/bin/open", [script.path])
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
