import Foundation

/// A Steam game discovered from an installed Valve `appmanifest_<id>.acf` file.
public struct DiscoveredSteamGame: Sendable, Equatable, Identifiable {
    public let appID: Int
    public let name: String
    public let installDir: String
    public let sizeOnDisk: Int64?

    public var id: Int { appID }
}

/// An existing CrossOver bottle discovered under `~/Library/Application Support/CrossOver/Bottles`.
public struct CrossOverBottle: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: URL
    public let steamGames: [DiscoveredSteamGame]

    public var id: String { name }
}

/// Snapshot of external macOS gaming tools installed on this Mac (read-only discovery).
/// GamePort never bundles or copies third-party apps; it only detects user-installed apps
/// so players can launch them from one place when appropriate (e.g. Obelisk for Linux-EAC games).
public struct ExternalEnvironment: Sendable, Equatable {
    public static let obeliskWebsite = "https://getobelisk.app"

    public let obeliskApp: URL?
    public let crossoverApp: URL?
    public let crossoverBottles: [CrossOverBottle]
    public let macSteamApp: URL?
    public let macSteamGames: [DiscoveredSteamGame]
    public let notProtonInstalled: Bool

    public var hasObelisk: Bool { obeliskApp != nil }
    public var hasCrossOver: Bool { crossoverApp != nil }
    public var hasMacSteam: Bool { macSteamApp != nil }

    public func macSteamGame(appID: Int) -> DiscoveredSteamGame? {
        macSteamGames.first { $0.appID == appID }
    }

    public func crossoverBottle(containingAppID appID: Int) -> CrossOverBottle? {
        crossoverBottles.first { $0.steamGames.contains { $0.appID == appID } }
    }

    /// True ONLY when a game uses Easy Anti-Cheat or BattlEye with Linux/Steam Deck support
    /// (e.g. Elden Ring online, Armored Core VI, Rocket League), where Obelisk's Linux runtime
    /// helps — never on VAC games that already work natively in GamePort's Windows Steam.
    public static func suggestsObelisk(for antiCheat: AntiCheatEntry?) -> Bool {
        guard let ac = antiCheat else { return false }
        let linuxOK = ac.linuxStatus == "Supported" || ac.linuxStatus == "Running"
        guard linuxOK else { return false }
        return ac.antiCheats.contains { name in
            let lower = name.lowercased()
            return lower.contains("easy anti-cheat") || lower.contains("battleye")
        }
    }

    public static let empty = ExternalEnvironment(
        obeliskApp: nil, crossoverApp: nil, crossoverBottles: [],
        macSteamApp: nil, macSteamGames: [], notProtonInstalled: false
    )
}

/// Read-only discovery of installed external launchers (Obelisk, CrossOver, native Mac Steam / NotProton).
public enum ExternalDiscovery {
    public static func scan(
        applicationsDirs: [URL]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ExternalEnvironment {
        let appDirs = applicationsDirs ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        let fm = FileManager.default

        func findApp(_ name: String) -> URL? {
            for dir in appDirs {
                let candidate = dir.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }

        let obelisk = findApp("Obelisk.app")
        let crossover = findApp("CrossOver.app")
        let macSteam = findApp("Steam.app")

        let bottlesRoot = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        let bottles = scanCrossOverBottles(in: bottlesRoot)

        let steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        let macSteamGames = scanSteamApps(in: steamRoot.appendingPathComponent("steamapps", isDirectory: true))
        let compatTools = steamRoot.appendingPathComponent("compatibilitytools.d", isDirectory: true)
        let notProton = ((try? fm.contentsOfDirectory(atPath: compatTools.path)) ?? [])
            .contains { $0.localizedCaseInsensitiveContains("notproton") || $0.localizedCaseInsensitiveContains("proton") }

        return ExternalEnvironment(
            obeliskApp: obelisk,
            crossoverApp: crossover,
            crossoverBottles: bottles,
            macSteamApp: macSteam,
            macSteamGames: macSteamGames,
            notProtonInstalled: notProton
        )
    }

    public static func scanCrossOverBottles(in bottlesRoot: URL) -> [CrossOverBottle] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bottlesRoot.path) else { return [] }
        return names.sorted().compactMap { name in
            let dir = bottlesRoot.appendingPathComponent(name, isDirectory: true)
            let conf = dir.appendingPathComponent("cxbottle.conf")
            guard fm.fileExists(atPath: conf.path) else { return nil }
            let steamApps = dir.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
            return CrossOverBottle(name: name, path: dir, steamGames: scanSteamApps(in: steamApps))
        }
    }

    public static func scanSteamApps(in steamappsDir: URL) -> [DiscoveredSteamGame] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: steamappsDir.path) else { return [] }
        return files.sorted().compactMap { file -> DiscoveredSteamGame? in
            guard file.hasPrefix("appmanifest_"), file.hasSuffix(".acf") else { return nil }
            guard let text = try? String(contentsOf: steamappsDir.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return parseAppManifest(text)
        }
    }

    /// Lightweight Valve ACF/VDF key-value parser for `appmanifest_<id>.acf`.
    public static func parseAppManifest(_ text: String) -> DiscoveredSteamGame? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = extractQuotedTokens(String(line))
            if parts.count >= 2 {
                let key = parts[0].lowercased()
                if values[key] == nil { values[key] = parts[1] }
            }
        }
        guard let idStr = values["appid"], let appID = Int(idStr), appID > 0,
              let name = values["name"], !name.isEmpty else { return nil }
        let installDir = values["installdir"] ?? ""
        let size = values["sizeondisk"].flatMap(Int64.init)
        return DiscoveredSteamGame(appID: appID, name: name, installDir: installDir, sizeOnDisk: size)
    }

    private static func extractQuotedTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" && inQuotes {
                escaped = true
            } else if ch == "\"" {
                if inQuotes {
                    tokens.append(current)
                    current = ""
                }
                inQuotes.toggle()
            } else if inQuotes {
                current.append(ch)
            }
        }
        return tokens
    }
}
