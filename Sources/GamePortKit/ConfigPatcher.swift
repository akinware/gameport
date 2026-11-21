import Foundation

/// Player-selected defaults. Existing keys (including custom values) always win.
public enum ConfigPatcher {
    /// Fixed, prefix-wide settings, selected individually by the player.
    public enum WineDefault: String, Sendable, CaseIterable {
        case controller
        case openGL = "opengl"

        public var title: String {
            switch self {
            case .controller: return "Use SDL controller defaults"
            case .openGL: return "Disable fullscreen display capture for OpenGL"
            }
        }

        var registry: [Recipe.RegistryValue] {
            switch self {
            case .controller:
                let service = #"HKLM\System\CurrentControlSet\Services\winebus"#
                return [.init(key: service, name: "Enable SDL", type: "REG_DWORD", data: "1"),
                        .init(key: service, name: "DisableHidraw", type: "REG_DWORD", data: "1")]
            case .openGL:
                return [.init(key: #"HKCU\Software\Wine\Mac Driver"#, name: "CaptureDisplaysForFullscreen",
                              type: "REG_SZ", data: "n")]
            }
        }
    }

    public struct INI: Codable, Sendable, Equatable {
        /// Relative to the Wine user's AppData/Local. The game must have created the parent folder.
        public var file: String
        public var section: String
        public var key: String
        public var value: String

        func validate() throws {
            let parts = file.components(separatedBy: "/")
            guard parts.count >= 2, file.lowercased().hasSuffix(".ini"),
                  parts.allSatisfy({ safeField($0) && $0 != "." && $0 != ".." }),
                  safeField(section), safeField(key), safeField(value) else {
                throw GamePortError.invalid("invalid INI default for \(file)")
            }
        }
    }

    public struct Defaults: Codable, Sendable, Equatable {
        public var ini: [INI]?
        public var registry: [Recipe.RegistryValue]?

        func validate() throws {
            for entry in ini ?? [] { try entry.validate() }
            for entry in registry ?? [] { _ = try registryLine(entry) }
        }
    }

    // Recipe fields become INI or INF text. Limit them to simple, single-line literals.
    private static func safeField(_ field: String) -> Bool {
        !field.isEmpty && field == field.trimmingCharacters(in: .whitespaces) &&
            field.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || " ._-".contains($0)) }
    }

    /// Insert only a missing key, preserving comments, line endings, unrelated sections and a UTF-8 BOM.
    static func adding(_ entry: INI, to text: String) throws -> String {
        try entry.validate()
        guard !text.contains("\0") else { throw GamePortError.unsupported("binary INI file") }
        let bom = text.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
        let body = String(text.dropFirst(bom.count))
        let newline = body.contains("\r\n") ? "\r\n" : "\n"
        var lines = body.components(separatedBy: newline)
        guard !lines.contains(where: { $0.contains(where: \.isNewline) }) else {
            throw GamePortError.unsupported("mixed or unsupported INI line endings")
        }
        var inSection = false
        var insertion: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                guard let close = trimmed.firstIndex(of: "]") else { throw GamePortError.invalid("incomplete INI section") }
                let name = trimmed.dropFirst().prefix(upTo: close).trimmingCharacters(in: .whitespaces)
                inSection = name.caseInsensitiveCompare(entry.section) == .orderedSame
                if inSection { insertion = index + 1 }
            } else if inSection, let equals = trimmed.firstIndex(of: "=") {
                let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "+-!."))
                if name.caseInsensitiveCompare(entry.key) == .orderedSame { return text }
            }
        }
        let assignment = "\(entry.key)=\(entry.value)"
        if let insertion {
            lines.insert(assignment, at: insertion)
            return bom + lines.joined(separator: newline)
        }
        let separator = body.isEmpty || body.hasSuffix(newline) ? "" : newline
        return text + separator + "[\(entry.section)]" + newline + assignment + newline
    }

    /// Reject linked path components, including dangling links, before touching anything in a prefix.
    private static func checkedFile(in prefix: URL, parts: [String]) throws -> URL {
        let fm = FileManager.default
        var current = prefix
        for component in [""] + parts {
            if !component.isEmpty { current.appendPathComponent(component) }
            if (try? fm.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw GamePortError.invalid("linked config path \(current.path)")
            }
        }
        return current
    }

    @discardableResult
    static func apply(_ entry: INI, in prefix: URL, user: String) throws -> String {
        try entry.validate()
        guard !user.isEmpty, user != ".", user != "..", !user.contains("/"), !user.contains("\\") else {
            throw GamePortError.invalid("Wine user name")
        }
        let parts = ["drive_c", "users", user, "AppData", "Local"] + entry.file.components(separatedBy: "/")
        let file = try checkedFile(in: prefix, parts: parts)
        #if os(macOS)
        var failure: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &failure) { url in
            result = Result { try write(entry, to: url) }
        }
        if let failure { throw failure }
        guard let result else { throw GamePortError.invalid("could not coordinate the write to \(file.path)") }
        return try result.get()
        #else
        return try write(entry, to: file)
        #endif
    }

    private static func write(_ entry: INI, to file: URL) throws -> String {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: file.deletingLastPathComponent().path, isDirectory: &dir), dir.boolValue else {
            throw GamePortError.missing("\(entry.file) configuration folder. Start the game once first.")
        }
        guard fm.fileExists(atPath: file.path) else {
            try Data(adding(entry, to: "").utf8).write(to: file, options: .withoutOverwriting)
            return "Created \(entry.file)"
        }
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw GamePortError.invalid("expected a regular INI file")
        }
        let original = try Data(contentsOf: file)
        // Newer macOS Foundation strips a leading UTF-8 BOM in String(data:encoding:.utf8); preserve it explicitly.
        let hasBOM = original.starts(with: [0xEF, 0xBB, 0xBF])
        guard let decoded = String(data: hasBOM ? original.dropFirst(3) : original, encoding: .utf8) else {
            throw GamePortError.unsupported("INI encoding in \(entry.file)")
        }
        let text = hasBOM ? "\u{FEFF}" + decoded : decoded
        let updated = try adding(entry, to: text)
        guard updated != text else { return "Kept existing \(entry.key) in \(entry.file)" }
        let backup = file.appendingPathExtension("gameport-\(UUID().uuidString).bak")
        try original.write(to: backup, options: .withoutOverwriting)
        guard try Data(contentsOf: file) == original else { throw GamePortError.invalid("\(entry.file) changed during patching") }
        try Data(updated.utf8).write(to: file, options: .atomic)
        return "Added \(entry.key) to \(entry.file). Backup: \(backup.lastPathComponent)"
    }

    /// SetupAPI's AddReg NOCLOBBER flag performs the existence check in Wine, including on retries.
    static func registryLine(_ entry: Recipe.RegistryValue, preset: WineDefault? = nil) throws -> String {
        let path = entry.key.components(separatedBy: "\\")
        // Recipe data stays restricted to AppDefaults. Only the exact built-in preset may use driver keys.
        if preset?.registry.contains(entry) != true {
            guard path.count >= 5, path.prefix(4).map({ $0.lowercased() }) == ["hkcu", "software", "wine", "appdefaults"],
                  path[4].lowercased().hasSuffix(".exe"), path.dropFirst().allSatisfy(safeField),
                  safeField(entry.name) else { throw GamePortError.invalid("expected a named per-game Wine AppDefaults value") }
        }
        let hive = path[0].uppercased()
        let key = path.dropFirst().joined(separator: "\\")
        switch entry.type {
        case "REG_SZ" where safeField(entry.data):
            return #"\#(hive),"\#(key)","\#(entry.name)",0x00000002,"\#(entry.data)""#
        case "REG_DWORD":
            let hex = entry.data.lowercased().hasPrefix("0x")
            let digits = hex ? String(entry.data.dropFirst(2)) : entry.data
            if let value = UInt32(digits, radix: hex ? 16 : 10) {
                return #"\#(hive),"\#(key)","\#(entry.name)",0x00010003,\#(value)"#
            }
            fallthrough
        default: throw GamePortError.invalid("unsupported registry default \(entry.name)")
        }
    }

    static func applyRegistry(_ entries: [Recipe.RegistryValue], runner: WineRunner, preset: WineDefault? = nil) throws {
        guard !entries.isEmpty else { return }
        let lines = try entries.map { try registryLine($0, preset: preset) }
        let name = "gameport-\(UUID().uuidString).inf"
        let file = try checkedFile(in: runner.prefix, parts: ["drive_c", name])
        let inf = ["[Version]", #"Signature="$CHICAGO$""#, "[DefaultInstall]", "AddReg=Defaults", "[Defaults]"] + lines
        try Data((inf.joined(separator: "\r\n") + "\r\n").utf8).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        try runner.run(["rundll32.exe", "setupapi.dll,InstallHinfSection", "DefaultInstall", "128", "C:\\" + name])
        for entry in entries { try runner.run(["reg", "query", entry.key, "/v", entry.name]) }
    }
}

extension GamePort {
    public func applyWineDefault(_ setting: ConfigPatcher.WineDefault, to profileID: String) throws {
        let runner = try runner(for: profileID)
        try requireIdleForConfig(runner)
        try ConfigPatcher.applyRegistry(setting.registry, runner: runner, preset: setting)
    }

    private func requireIdleForConfig(_ runner: WineRunner) throws {
        guard try runner.waitForServer(timeout: 2) else {
            throw GamePortError.invalid("close the game and Steam before applying settings")
        }
    }

    public func applyConfigDefaults(_ profileID: String, progress: ProgressHandler? = nil) throws {
        let runner = try runner(for: profileID)
        guard let defaults = runner.recipe?.configDefaults else {
            throw GamePortError.missing("optional config defaults for \(profileID)")
        }
        try defaults.validate()
        try requireIdleForConfig(runner)
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        for entry in defaults.ini ?? [] {
            let message = try ConfigPatcher.apply(entry, in: runner.prefix, user: user)
            progress?(message)
        }
        let registry = defaults.registry ?? []
        try ConfigPatcher.applyRegistry(registry, runner: runner)
        if !registry.isEmpty { progress?("Registry defaults applied. Existing values kept.") }
    }
}
